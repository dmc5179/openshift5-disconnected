# OpenShift 5 disconnected install lab on AWS

Scripts and a CloudFormation template that build a **simulated disconnected (air-gapped) environment
in AWS**. Use it to test OpenShift 5 installs, release and operator mirroring with oc-mirror v2, and
the settings for disabling AI features and telemetry, before taking the same procedure to a real
restricted network.

Customers who need this are often in **AWS GovCloud** or the **AWS secret and top secret regions
(ISO / ISO-B)**. A commercial account can simulate some of the ISO constraints (`TARGET_ENV`, below).

> Status: lab tooling for OpenShift 5.0. Validate everything in your own environment before
> treating it as a supported procedure. It is not a Red Hat product, and it is not supported by
> Red Hat.

## Architecture

```
                    Internet
                       |
               Internet gateway
                       |
 +----------------- public subnet ---------------------------------+
 |  bastion ("connected side")      Squid egress filter (NAT host) |
 |  - downloads oc, openshift-install,  - iptables REDIRECT 80/443  |
 |    ccoctl, oc-mirror, mirror-registry  - allowlist by domain/SNI |
 |  - oc-mirror from Red Hat registries   - no IP forwarding        |
 +-----------------------------------------------^-----------------+
                       | oc-mirror push (8443)    | default route
 +----------------- private subnet --------------+-----------------+
 |  mirror-registry (Quay, :8443)  <--- image pulls ---             |
 |  OpenShift cluster (publish: Internal, private hosted zone)     |
 +------------------------------------------------------------------+
```

- **VPC** (`cloudformation/disconnected_vpc_plus.yaml`): 1 to 3 AZs, a public and a private subnet
  per AZ, a staging S3 bucket.
- **Squid egress filter**: the private route table's default route points at this instance.
  Ports 80 and 443 are redirected to Squid. Squid splices HTTPS by SNI without decrypting it.
  Only the allowlisted domains get through: the AWS APIs, the RHEL RHUI repositories and the
  lab domain. quay.io, registry.redhat.io and the rest of the internet are blocked. Instance
  metadata cannot be reached through the proxy.
- **Bastion** (public subnet, SSH only from `ALLOWED_SSH_CIDR`): the connected side. It downloads
  the tools, stages them in S3 for the registry node, and runs oc-mirror against Red Hat's
  registries. RHEL 9 or RHEL 10, chosen when the stack is created.
- **Mirror registry** (private subnet): Red Hat's `mirror-registry` (Quay) on port 8443. The stack
  reports complete only after Quay passes its health check.
- **Cluster**: installed into the private subnets from a host inside the VPC (the registry node by
  default). It pulls every image from the mirror registry.

## Prerequisites

On your workstation:

- AWS CLI v2, `jq`, and **Go yq v4** (mikefarah; `dnf install yq` on Fedora. The Python `yq` will
  not work). `shellcheck` is optional.
- `secrets/aws.env`: IAM user credentials and the region (copy `secrets/aws.env.example`). The
  installer needs IAM user keys to create infrastructure, even with STS.
- `secrets/pull-secret.json`: your Red Hat pull secret from console.redhat.com.
- An EC2 key pair in the region whose **private key is on this machine** (`EC2_KEY_NAME`,
  `SSH_PRIVATE_KEY`). The scripts reach the registry node through the bastion over SSH.
- A public Route 53 hosted zone for `BASE_DOMAIN`. If you leave it blank, the account's single
  zone is detected.

Review `cluster.env` before the first run. All scripts read it.

## Workflow

Run the scripts from the repository root unless a step says otherwise. Each script logs to
`logs/`.

### 1. Build the environment

```bash
scripts/10-deploy-vpc.sh            # --dry-run to check inputs only
```

This takes 20 to 40 minutes. The registry node waits for the bastion to stage the tools, then
installs mirror-registry. The stack fails if a download, the install, or the Quay health check
fails.

### 2. Mirror the release (on the bastion)

Render the ImageSetConfiguration locally, then copy it and the mirror script to the bastion:

```bash
scripts/generate-imageset-config.sh -o imageset-config.yaml
scp imageset-config.yaml scripts/bastion-mirror-to-mirror.sh ec2-user@<BastionPublicIp>:
```

On the bastion, as `ec2-user`, run the script. The Quay `init` password is in the registry node's
`/tmp/mirror-registry-install.log` (root only). Pass it in `MIRROR_PASSWORD`, or let the script
prompt for it:

```bash
MIRROR_PASSWORD=... ./bastion-mirror-to-mirror.sh <RegistryPrivateDnsName> imageset-config.yaml
```

This is mirror-to-mirror: oc-mirror v2 copies straight from Red Hat into Quay. Use `--dry-run`
first to see the plan. The generated IDMS, ITMS and signature resources are written to the
oc-mirror workspace (`~/oc-mirror/m2m/working-dir/cluster-resources/`). See
`examples/oc-mirror-5.0-m2m/` for a recorded run.

### 3. Fetch the registry CA and build the cluster pull secret

```bash
scripts/30-fetch-mirror-credentials.sh
```

This writes `secrets/mirror-rootCA.pem` and `secrets/pull-secret-mirror.json`: the Red Hat pull
secret plus the mirror credentials, without `cloud.openshift.com`. It never prints the password.

### 4. Render install-config.yaml

```bash
scripts/generate-install-config.sh [--publish internal|external] [--fips on|off] \
                                   [--os-image-stream rhel-9|rhel-10]
```

The flags override `PUBLISH`, `FIPS` and `OS_IMAGE_STREAM` for this run. The output uses the stack's
subnets, the mirror `imageDigestSources` (including `ocp-v5.0-art-dev`), the mirror CA in
`additionalTrustBundle`, and the capability and day-0 settings below.

### 5. Prepare STS credentials (credentialsMode: Manual)

```bash
scripts/20-prepare-sts.sh           # --dry-run writes the IAM/OIDC JSON only
```

This step uses `ccoctl aws create-all` to create the IAM OIDC provider, its S3 bucket, and one IAM
role per CredentialsRequest for the enabled capabilities. Run it on a connected host.

### 6. FIPS only: put the install host in FIPS mode

```bash
scripts/35-enable-fips-host.sh bastion
export INSTALL_HOST=bastion         # or set it in cluster.env
```

On RHEL 9, this runs `fips-mode-setup --enable` and reboots. RHEL 10 has no `fips-mode-setup`: the
host must be installed in FIPS mode, so the script refuses.

### 7. Install the cluster

```bash
scripts/40-install-cluster.sh start        # copy inputs, create manifests, start the install detached
scripts/40-install-cluster.sh status       # installer state and log tail
scripts/40-install-cluster.sh wait         # poll until the installer exits
scripts/40-install-cluster.sh fetch-auth   # kubeconfig + kubeadmin password -> clusters/<name>/auth
```

The installer runs on `INSTALL_HOST`. The default is the registry node, which can reach the
internet only through Squid. The cluster API is internal, so `oc` must also run inside the VPC, or
over an SSH tunnel through the bastion.

### 8. Tear down

Tear down in this order. A cluster left in the VPC blocks the stack deletion.

```bash
# On the install host (ec2-user):
cd ~/ocp-install/<CLUSTER_NAME> && . ../aws.env && openshift-install destroy cluster --dir .

# On your workstation:
bin/ccoctl aws delete --name <CCOCTL_NAME> --region <region>
scripts/90-destroy-vpc.sh                  # empties the staging bucket, deletes the stack
```

## Key settings (`cluster.env`)

| Setting | Default | Meaning |
|---|---|---|
| `OCP_VERSION` / `OCP_CHANNEL` | `5.0.0` / `candidate-5.0` | Release to download and mirror. Use one platform channel only (see known issues). |
| `OCP_UPGRADE_FROM` | blank | Optional 4.22.z start of an upgrade path, added as `minVersion` in the same 5.x channel. |
| `TARGET_ENV` | `auto` | `auto` uses the partition of your credentials. `commercial`, `govcloud`, `iso` or `isob` force one. `iso`/`isob` in a commercial account simulates the ISO constraints: private cluster only, custom AWS CA bundle, custom RHCOS AMI. |
| `BASTION_RHEL_VERSION` | `9` | `9` or `10`. Fixed when the stack is created; rebuild the stack to change it. |
| `CREDENTIALS_MODE` | `Manual` | `Manual` uses ccoctl/STS (step 5). `Mint` and `Passthrough` are also accepted. |
| `PUBLISH` | `Internal` | `Internal` gives a private cluster. `External` puts the API and ingress load balancers on the public subnets. |
| `FIPS` | `false` | `true` needs `openshift-install-fips` on a FIPS-mode RHEL host (step 6). Cannot be changed after install. |
| `OS_IMAGE_STREAM` | `rhel-10` | RHCOS stream. `rhel-9` if you need runc or the RHEL 9 FIPS-validated modules. |
| `DISABLE_INSIGHTS` | `true` | Leaves out the Insights capability at install. This cannot be undone later. |
| `DISABLE_SAMPLES` | `true` | Leaves out the `openshift-samples` capability, so the samples operator never runs and never probes registry.redhat.io (it otherwise tries for about 5 minutes on first start, then turns itself off). Samples can be enabled later; a capability cannot be disabled after install. |
| `DISABLE_LIGHTSPEED` | `true` | Day-0 manifest that sets the console `LightspeedButton` capability to `Disabled`. Also leave `lightspeed-operator` out of `MIRROR_OPERATORS`. |
| `DISABLE_DEFAULT_CATALOGS` | `true` | Day-0 manifest that sets OperatorHub `disableAllDefaultSources`. Without it, the default catalogs sit in ImagePullBackOff. |
| `INSTALL_HOST` | `registry` | Host that runs `openshift-install`: `registry` or `bastion`. |
| `MIRROR_OPERATORS` | blank | Operators to mirror, as `package` or `package:channel`. |

## Known issues

- **oc-mirror and cross-major channels**
  ([OCPBUGS-136257](https://issues.redhat.com/browse/OCPBUGS-136257)): an ImageSetConfiguration that
  lists a 4.x and a 5.x channel together fails, because oc-mirror never queries the 5.x channel.
  Mirror a 4.22.z to 5.0 upgrade with a single 5.x channel and `minVersion`. Starting below 4.22
  needs a second, separate oc-mirror run. `generate-imageset-config.sh` enforces this.
- **Capability validation** ([OCPBUGS-136614](https://issues.redhat.com/browse/OCPBUGS-136614)): the
  5.0 installer accepts capabilities (`ClusterAPI`, `CompatibilityRequirements`) that the
  ClusterVersion API rejects on a Default feature-set cluster. Bootstrap then stalls with no
  ClusterVersion. `generate-install-config.sh` lists only the accepted capabilities.
- **oc-mirror is no longer in the release payload** from 5.0. `oc adm release extract` cannot
  provide it, and `clients/ocp/<version>/` has no oc-mirror tarball. Download it separately from
  `mirror.openshift.com/pub/cgw/oc-mirror/` (the template's `OcMirrorUrl` parameter).
- **No RHEL 10 client builds yet**: only rhel8 and rhel9 builds of oc, ccoctl and oc-mirror are
  published, and openshift-install only as rhel9. A RHEL 10 bastion uses the rhel9 builds.
- **ISO regions: NLB security groups (parked)**: network load balancers in the ISO regions do not
  support security groups, but the 5.0 IPI installer always attaches one to the API NLB. A real ISO
  install needs another approach, such as pre-created load balancers or UPI. That is not covered
  here yet.
- **The stack is commercial-partition only**: the AMI map, the Squid allowlist and some IAM ARNs
  assume the commercial partition.
- **After install**: apply the oc-mirror `cluster-resources` (signature ConfigMap, ITMS, catalog
  sources) and, for updates, an OpenShift Update Service. This is not scripted yet.

## Security notes

- `secrets/`, `clusters/`, `logs/`, `bin/`, the rendered `install-config.yaml` and
  `imageset-config.yaml` are gitignored. Never commit them. `secrets/` holds only
  `aws.env.example` in git.
- The pull secret is passed to the stack as a `NoEcho` parameter and written mode 600 on the
  bastion. It is still in the bastion's EC2 user data, which anyone with
  `ec2:DescribeInstanceAttribute` can read. Use a sandbox account, or move it to Secrets Manager.
- The cluster's pull secret leaves out `cloud.openshift.com` (no telemetry), and the Insights
  capability is disabled by default.
- `secrets/aws.env` (IAM user keys) is copied to the install host, mode 600, because
  `openshift-install` needs it until the cluster is destroyed. Remove it from the host after
  teardown.
- With its defaults, ccoctl creates a **public S3 bucket** for the OIDC discovery documents, because
  AWS STS must be able to read them. `CCOCTL_PRIVATE_BUCKET=true` uses a private bucket behind
  CloudFront instead, but CloudFront is not available in the ISO regions.
- Bastion SSH is limited to `ALLOWED_SSH_CIDR`, by default your current public IP /32. The registry
  and Squid instances accept SSH only from inside the VPC.
- mirror-registry runs as root (Quay in root podman). `fapolicyd` is disabled on the lab hosts if
  it is present, because it breaks mirror-registry.

## Repository layout

```
cloudformation/   disconnected_vpc_plus.yaml - VPC, Squid, bastion, mirror registry
scripts/          numbered workflow scripts, generators, shared libraries
templates/        install-config.yaml template for the AWS disconnected install
examples/         OpenShift 5.0 ImageSetConfiguration and install-config examples, oc-mirror test runs
cluster.env       non-secret settings read by every script
fips-rhel10-readiness.sh  read-only RHEL 9 -> RHEL 10 FIPS readiness check (draft)
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
