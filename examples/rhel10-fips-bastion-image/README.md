# RHEL 10 FIPS image-mode install host (AWS AMI)

An example RHEL 10.2 **image mode (bootc)** image to use as a FIPS install and mirror host for
disconnected OpenShift on AWS, and the commands to build it and import it as a private AMI.

| Feature | How |
|---|---|
| FIPS from first boot | `fips=1` kernel argument (`files/01-fips.toml`) and the `FIPS` crypto policy |
| Writable `/usr/local` and `/opt` | Symlinks to `/var/usrlocal` and `/var/opt`; sudo `secure_path` includes `/usr/local/bin` |
| Tools | wget, unzip, nmstate, xorriso, tmux, vim-enhanced, git, python3-pip, awscli2, bash-completion, acl, podman, skopeo, jq, rhc |
| EC2 integration | cloud-init (EC2 datasource, default user `cloud-user`), serial console, NVMe timeout, ENA, IMDSv2, UEFI-preferred boot |
| Root disk | Grows to the EBS volume size at first boot (`bootc-generic-growpart` in the base image) |
| Not included | fapolicyd (the build fails if it's present), SSH keys, pull secrets, any credentials |

No bootc-image-builder `config.toml` is used. Users and SSH keys come from cloud-init and the
EC2 key pair at launch.

## Files

```
Containerfile                     Image definition
files/01-fips.toml                fips=1 kernel argument            -> /usr/lib/bootc/kargs.d/
files/10-aws.toml                 EC2 serial console + NVMe timeout -> /usr/lib/bootc/kargs.d/
files/90-aws-datasource.cfg       cloud-init: EC2 datasource only   -> /etc/cloud/cloud.cfg.d/
files/91-bootc-no-resize.cfg      cloud-init: don't resize the disk -> /etc/cloud/cloud.cfg.d/
files/cloud-init-tmpfiles.conf    /var/lib/cloud                    -> /usr/lib/tmpfiles.d/
files/usrlocal-tmpfiles.conf      /var/usrlocal/{bin,sbin}          -> /usr/lib/tmpfiles.d/
files/10-secure-path-usrlocal     sudo secure_path (mode 0440)      -> /etc/sudoers.d/
aws/vmimport-trust-policy.json    vmimport IAM role trust policy
aws/vmimport-role-policy.json     vmimport IAM role permissions (replace <BUCKET>)
```

## Prerequisites

- A **registered RHEL 10 host** to build on (podman passes its subscription into the build), with
  `podman`, root access, and about 30 GB free in `/var/lib/containers`. To build on a non-RHEL host,
  register inside the build instead (Red Hat KB 5558771).
- Logged in to `registry.redhat.io` as root: `sudo podman login registry.redhat.io`.
- AWS CLI v2 and credentials for the target account, an S3 bucket in the target region, and the
  `vmimport` service role (below).

## 1. Build the image

```bash
sudo podman build -t localhost/rhel10-fips-bastion:unchunked .
```

Expected: the build ends with `bootc container lint` passing. Its only warning is
`var/roothome/buildinfo/content-sets.json`, which comes from the Red Hat base image.

## 2. Flatten the layers (recommended)

Regenerates the layers from the final filesystem, so files removed or replaced by later build steps
aren't left in lower layers for vulnerability scanners to flag
(RHEL 10 "Using image mode for RHEL", section 9.5):

```bash
sudo podman run --rm --privileged -v /var/lib/containers:/var/lib/containers \
  registry.redhat.io/rhel10/rhel-bootc:10.2 \
  /usr/libexec/bootc-base-imagectl rechunk \
  localhost/rhel10-fips-bastion:unchunked localhost/rhel10-fips-bastion:latest
```

## 3. Create the AMI disk image

```bash
mkdir -p output
sudo podman run --rm --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel10/bootc-image-builder:latest \
  --type ami \
  localhost/rhel10-fips-bastion:latest
sudo chown -R "$(id -u):$(id -g)" output
```

Output: `output/image/disk.raw` (10 GiB, sparse). Optional check that FIPS is in the boot entry
(partition 3 is `/boot`):

```bash
B=$(sfdisk -d output/image/disk.raw | grep 'disk.raw3 ' | sed -E 's/.*start= *([0-9]+), size= *([0-9]+).*/\1 \2/')
dd if=output/image/disk.raw bs=512 skip=${B% *} count=${B#* } status=none | grep -a -o 'options root=[^[:cntrl:]]*'
# expect: ... fips=1 console=tty0 console=ttyS0,115200n8 nvme_core.io_timeout=4294967295 ...
```

## 4. One-time AWS setup: bucket and vmimport role

Placeholders: `<REGION>`, `<BUCKET>`, `<TAG_VALUE>` (a tag for finding these resources later).

```bash
export AWS_REGION=<REGION>

aws s3api create-bucket --bucket <BUCKET> --region <REGION> \
  --create-bucket-configuration LocationConstraint=<REGION>   # omit this line for us-east-1
aws s3api put-public-access-block --bucket <BUCKET> --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-tagging --bucket <BUCKET> --tagging 'TagSet=[{Key=Purpose,Value=<TAG_VALUE>}]'

BUCKET=<BUCKET>   # your bucket name
sed "s/<BUCKET>/${BUCKET}/g" aws/vmimport-role-policy.json > /tmp/vmimport-role-policy.json
aws iam create-role --role-name vmimport \
  --assume-role-policy-document file://aws/vmimport-trust-policy.json \
  --tags Key=Purpose,Value=<TAG_VALUE>
aws iam put-role-policy --role-name vmimport --policy-name vmimport \
  --policy-document file:///tmp/vmimport-role-policy.json
```

## 5. Import the snapshot and register the AMI

Placeholders: `<REGION>`, `<BUCKET>`, `<AMI_NAME>` (e.g. `rhel10-fips-bastion-<date>`), `<TAG_VALUE>`.

```bash
export AWS_REGION=<REGION>
aws sts get-caller-identity          # confirm you're in the intended account

# Upload the raw disk
aws s3 cp output/image/disk.raw s3://<BUCKET>/bootc-imports/<AMI_NAME>.raw

# Import it as an EBS snapshot and wait for the task to finish (often 10-30 minutes)
TASK_ID=$(aws ec2 import-snapshot --description "<AMI_NAME>" \
  --disk-container "Format=raw,UserBucket={S3Bucket=<BUCKET>,S3Key=bootc-imports/<AMI_NAME>.raw}" \
  --query ImportTaskId --output text)
while true; do
  STATUS=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "$TASK_ID" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.Status' --output text)
  echo "$STATUS"; [ "$STATUS" = completed ] && break
  [ "$STATUS" = deleted ] && { echo "import failed"; break; }
  sleep 30
done
SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "$TASK_ID" \
  --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' --output text)

# Register a private AMI: UEFI-preferred, ENA, IMDSv2 required, gp3 root
AMI_ID=$(aws ec2 register-image --name "<AMI_NAME>" --architecture x86_64 \
  --virtualization-type hvm --ena-support --boot-mode uefi-preferred --imds-support v2.0 \
  --root-device-name /dev/xvda \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$SNAPSHOT_ID,DeleteOnTermination=true,VolumeType=gp3}" \
  --query ImageId --output text)
aws ec2 create-tags --resources "$SNAPSHOT_ID" "$AMI_ID" --tags Key=Purpose,Value=<TAG_VALUE>

# Wait until it's usable (the waiter times out after ~10 minutes; re-run it if the state is still "pending")
aws ec2 wait image-available --image-ids "$AMI_ID"
echo "AMI ready: $AMI_ID"

# Clean up the upload, and confirm the AMI isn't shared (expect [])
aws s3 rm s3://<BUCKET>/bootc-imports/<AMI_NAME>.raw
aws ec2 describe-image-attribute --image-id "$AMI_ID" --attribute launchPermission --query LaunchPermissions
```

## 6. Launch and verify

Launch with your EC2 key pair, `HttpTokens=required`, and a root volume of the size you need (it
grows at first boot). Use an RSA or ECDSA key: FIPS-mode sshd refuses ed25519. Log in as
`cloud-user`, then:

```bash
cat /proc/sys/crypto/fips_enabled        # 1
update-crypto-policies --show            # FIPS
grep -o fips=1 /proc/cmdline             # fips=1
ls -ld /usr/local /opt                   # -> ../var/usrlocal, -> var/opt
cloud-init status                        # status: done
df -h /var                               # about the size of the root volume
```

## Notes

- **Image mode:** `/usr` is read-only. Persistent changes go in the Containerfile and a rebuild;
  `/etc` and `/var` are writable. Register at runtime with `rhc connect` or
  `subscription-manager register` if you need RHEL repositories on the host.
- **Updates:** rebuild the image and either create a new AMI, or push the image to a registry the
  hosts track and run `bootc upgrade`.
- **Teardown:** deregister the AMI, delete the snapshot, empty and delete the bucket, then delete
  the `vmimport` role's inline policy and the role.
