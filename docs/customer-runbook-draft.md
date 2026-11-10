# Installing OpenShift 5.0 on AWS in an air-gapped network: runbook (first draft)

Status: **DRAFT 0.1, 2026-11-08. Not reviewed. Not for distribution yet.**

This runbook describes an air-gapped, installer-provisioned (IPI) OpenShift 5.0 install on AWS, written with AWS
GovCloud and the AWS secret regions (ISO / ISO-B) in mind. It is built only from what we have run in a lab or what
Red Hat documents. The lab was a commercial AWS region (us-east-2) set up to behave like an air gap: a private
subnet whose only egress is a filtering proxy that blocks every Red Hat and internet endpoint.

Every step carries one of these labels:

| Label | Meaning |
|---|---|
| **Lab-validated** | We ran it on OpenShift 5.0.0 and saw the stated result (up to five installs, 2026-11-03 to 11-06) |
| **Documented only** | Red Hat documentation describes it; we did not run it |
| **Untested** | Our recommendation; nobody has run it yet. Test it in your environment first |

Read section 13 (GovCloud and ISO gaps) before you plan an ISO / ISO-B install: one blocker (load balancer security
groups) has no IPI workaround yet.

## Contents

1. Architecture and prerequisites
2. Host operating system for the tooling hosts
3. Mirror registry
4. Mirroring the release and operators with oc-mirror
5. Extracting the installer from the mirror
6. AWS credentials for cluster operators (STS with ccoctl)
7. install-config.yaml
8. Day-0 manifests
9. Install
10. Post-install
11. Keeping AI features off
12. Expected blocked egress after install
13. GovCloud and ISO / ISO-B gaps
14. Upgrades
15. Known issues (internal)

---

## 1. Architecture and prerequisites

```
 connected side                      |  air-gapped VPC (no internet route)
                                     |
 [mirror host]  -- oc-mirror ------> |  [mirror registry]  <-- nodes pull images
  (Red Hat registries reachable)     |  [install host]     --> AWS APIs (VPC endpoints or partition endpoints)
                                     |  [cluster: 3 control plane + workers, publish: Internal]
```

- **Mirror host** (connected): runs oc-mirror. In a true air gap it writes an archive to disk, which you carry
  across. In our lab it pushed straight into the registry (mirror-to-mirror).
- **Mirror registry** (air-gapped side): we used `mirror-registry` (Quay 3.12). Any registry that supports the
  Docker v2 API and sigstore signature tags should work (Untested with others).
- **Install host** (air-gapped side): runs `openshift-install-fips`. It needs the mirror registry and the AWS APIs.
  Because the cluster is private (`publish: Internal`), the install host must be inside the VPC (or peered).
- **AWS APIs**: the cluster and the installer need EC2, ELB, Route 53, S3, IAM, STS and tagging. In our lab they
  went through the proxy's allowlist. In a true air gap use VPC endpoints or the partition's private endpoints.
  Untested without any proxy.
- **Allow the Route 53 tagging endpoint in us-east-1, whatever your cluster region** (Lab-validated failure, 2026-11-10).
  The ingress operator finds the cluster's private hosted zone through the Resource Groups Tagging API, and for
  the global Route 53 service that endpoint is `tagging.us-east-1.amazonaws.com` (GovCloud:
  `tagging.us-gov-west-1.amazonaws.com`). An allowlist or VPC-endpoint design that only permits the cluster's own
  region blocks it: the install times out with the ingress operator Degraded (`DNSReady=False`, reason `NoZones`),
  no `*.apps` record, and the authentication and console operators unavailable. Allowing the endpoint fixed it
  within minutes, and `openshift-install wait-for install-complete` then succeeded. Minimum allowlist we validated
  for a region-restricted design (commercial, us-east-2): `*.us-east-2.amazonaws.com`, `iam.amazonaws.com`,
  `route53.amazonaws.com`, `sts.amazonaws.com`, `s3.amazonaws.com`, `tagging.us-east-1.amazonaws.com`.

Sizes that worked (Lab-validated): mirror host m6i.2xlarge (t3.large was too small to run oc-mirror and the
installer's local control plane), registry m6i.xlarge with 300 GB disk (a 5.0.0 platform mirror is about 23 GB in
Quay; with a 4.22 upgrade path and three operators, about 45 GB), cluster nodes m6i.xlarge.

You need:
- A Red Hat pull secret.
- An existing VPC with private subnets. Tag private subnets `kubernetes.io/role/internal-elb: "1"` (and public
  subnets `kubernetes.io/role/elb: "1"` if any), or LoadBalancer Services cannot find subnets. Do not add
  `kubernetes.io/cluster/*: owned` tags. Lab-validated.
- A Route 53 base domain. With `publish: Internal` the installer creates a private hosted zone. Lab-validated.
- `oc` 5.0.z, `jq`, and (if you use our scripts) Go `yq` v4 on the hosts.

## 2. Host operating system for the tooling hosts

### 2.1 RHEL 9 or RHEL 10

| | RHEL 9 (package mode) | RHEL 10 (image mode / bootc) |
|---|---|---|
| OpenShift 5.0.0 clients (`oc`, `kubectl`, `openshift-install-fips`, `ccoctl`) | Lab-validated | Lab-validated with the **RHEL 9 builds** (no RHEL 10 builds are published). Red Hat has not published a support statement for RHEL 9 builds on RHEL 10 |
| FIPS | `fips-mode-setup --enable` + reboot worked in the lab. Red Hat recommends enabling FIPS at installation | **Only at installation** (`fips=1`); `fips-mode-setup` is removed. Lab-validated with a FIPS image-builder AMI |
| mirror-registry | Lab-validated | Lab-validated, with data under `/var` (see 3.1) |
| Install a cluster from it | Lab-validated (installs 2-4) | Lab-validated (install 5: private subnet, no internet, 42 min) |
| Updates | `dnf` | Build tools into the image; `bootc upgrade`. Our stock user data (dnf, wget, `/usr/local`, `/opt`) does not work on an image-mode host |

RHEL 10 image-mode notes (Lab-validated):
- In the RHEL 10.2 bootc base image, `/usr/local` and `/opt` are read-only unless the image links them to `/var`
  (`/usr/local -> /var/usrlocal`, `/opt -> /var/opt`). Build your image that way, or install tools to
  `~/.local/bin` and keep data under `/var`.
- No package repositories by default (bring your own subscription). Bake in what you need: `nmstate`
  (`nmstatectl`, for agent-based installs with network config), `acl` (`setfacl`, needed by mirror-registry),
  `podman`, `skopeo`, `jq`, AWS CLI.
- `sudo`'s `secure_path` may not include `/usr/local/bin`.

### 2.2 FIPS

For `fips: true` the installer must be `openshift-install-fips` running on a host in FIPS mode. It checks only
`/proc/sys/crypto/fips_enabled`, and accepted RHEL 10.2 as well as RHEL 9.8. Lab-validated.

```bash
cat /proc/sys/crypto/fips_enabled       # must be 1
update-crypto-policies --show           # FIPS
```

On a FIPS host, the FIPS-capable oc-mirror is the container image build, not the CDN tarball (section 4.1).

Side effects seen on FIPS RHEL 9 (Lab-validated): sshd stops offering its ED25519 host key and offers ECDSA, so SSH
clients report a changed host key once.

### 2.3 fapolicyd (if your golden image enforces it)

With fapolicyd enforcing, the default rules deny every non-RPM binary (oc, openshift-install-fips, oc-mirror,
ccoctl, AWS CLI v2, mirror-registry) for normal users, and **every rootful `podman run` fails**, which breaks
mirror-registry. Two additions fixed everything we tested on RHEL 9.8 FIPS and RHEL 10.2 (Lab-validated with
`integrity = sha256` and a STIG deny-all rule, across reboots):

1. A rule for crun (it re-executes from a memory file, so fapolicyd sees `exe=/`). Must sort before `30-patterns.rules`:

   ```bash
   cat > /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules <<'EOF'
   allow perm=open uid=0 pattern=ld_so exe=/ : all
   EOF
   chgrp fapolicyd /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
   chmod 644 /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
   fagenrules --load
   ```

   A rule naming `exe=/usr/bin/crun` does **not** work. Red Hat documents the equivalent rule for runc only.

2. A trust file for the non-RPM tools, written by `examples/fapolicyd/fapolicyd-trust-tools.sh` (path, size and
   SHA-256 of each tool):

   ```bash
   sudo MIRROR_REGISTRY_DIR=/opt/mr ./fapolicyd-trust-tools.sh          # after installing or upgrading any tool
   sudo ./fapolicyd-trust-tools.sh --check                              # lists UNTRUSTED / STALE files
   ```

   **Re-run it after every tool upgrade.** With `integrity = sha256` a replaced binary is denied until you do.
   Run tools from the trusted path; the same binary elsewhere is still denied.

Order on a new host: rules, then tools, then the trust script, then mirror-registry.

**Untested:** `openshift-install create cluster` under fapolicyd. The installer unpacks etcd, kube-apiserver and
the Cluster API providers into `<install-dir>/cluster-api/` and runs them; fapolicyd will probably deny that for a
non-root user. Until this is tested, run the install from a host with fapolicyd in permissive mode or disabled.
`create manifests`, `agent create image`, oc-mirror, ccoctl and mirror-registry worked under enforcement.

Also seen: the AWS CLI v2 installer prints success even when fapolicyd blocked its self-check. Check with
`aws --version`.

## 3. Mirror registry

### 3.1 Install mirror-registry

Lab-validated on RHEL 9.8 (mirror-registry 2.0.12) and RHEL 10.2 image mode (2.0.9), as root:

```bash
# RHEL 9 / package mode
./mirror-registry install --quayRoot /opt/quay-root --quayStorage /opt/quay-root/data --sqliteStorage /opt/quay-root/sqlite
# RHEL 10 image mode without a writable /opt
./mirror-registry install --quayRoot /var/quay-root --quayStorage /var/quay-root/data --sqliteStorage /var/quay-root/sqlite
```

- The generated `init` password is printed in the install output. Keep it.
- The generated root CA is at `<quayRoot>/quay-rootCA/rootCA.pem` (RSA 2048, SHA-256). Its certificate SAN is the
  host's FQDN; use that name everywhere.
- On RHEL 10 install the `acl` package first (`setfacl`), or the install fails.
- If an install fails and you retry, remove the leftover secret first or Redis fails with `WRONGPASS`:
  `podman secret rm redis_pass`.
- mirror-registry runs Quay as rootful podman. A rootless install was not tested.

### 3.2 Fix the start order after a reboot

After a reboot `quay-app` can start before the `quay-pod` exists, fail once, and come back about 30 s later (Quay
healthy about 3.5 minutes after boot). This drop-in removes the failed start (Lab-validated: healthy 133 s after a
reboot, no restarts):

```bash
for u in quay-app quay-redis; do
  sudo mkdir -p /etc/systemd/system/${u}.service.d
  sudo tee /etc/systemd/system/${u}.service.d/10-wait-for-pod.conf >/dev/null <<'EOF'
[Service]
ExecStartPre=/usr/bin/timeout 120 /bin/sh -c "until /usr/bin/podman pod exists quay-pod; do sleep 2; done"
EOF
done
sudo systemctl daemon-reload
curl -fsS --cacert <quayRoot>/quay-rootCA/rootCA.pem https://$(hostname -f):8443/health/instance
```

On FIPS hosts Quay logs some Python tracebacks at start-up. We saw no functional impact. Lab-validated.

### 3.3 Trust the registry CA on the tooling hosts

oc-mirror and `oc` use the system trust store; podman and skopeo use `/etc/containers/certs.d`. Lab-validated:

```bash
REG=<registry-fqdn>:8443
sudo install -m 0644 rootCA.pem /etc/pki/ca-trust/source/anchors/mirror-registry.pem
sudo update-ca-trust extract
sudo mkdir -p /etc/containers/certs.d/${REG}
sudo install -m 0644 rootCA.pem /etc/containers/certs.d/${REG}/ca.crt
```

## 4. Mirroring the release and operators with oc-mirror

### 4.1 Which oc-mirror

oc-mirror is no longer in the 5.0 release payload; it ships separately. Lab-validated:

| Build | FIPS-capable | Use on |
|---|---|---|
| CDN tarball, version 2.0.0: `https://mirror.openshift.com/pub/cgw/oc-mirror/latest/oc-mirror-rhel9-linux-amd64.tar.gz` | **No** (static binary, does not use the system OpenSSL FIPS provider) | Non-FIPS hosts |
| Container image build 5.0.0: `registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0`, file `/usr/bin/oc-mirror.rhel9` | **Yes** (loads `libcrypto.so.3` and `fips.so`) | FIPS hosts |

```bash
oc image extract registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0 -a ./pull-secret.json \
  --filter-by-os=linux/amd64 --path /usr/bin/oc-mirror.rhel9:. --confirm
chmod 755 oc-mirror.rhel9 && sudo mv oc-mirror.rhel9 /usr/local/bin/oc-mirror
oc-mirror version
```

Notes: the CDN build reports version 2.0.0 (not 5.0), so scripts that parse the version break. `--v2` is required.

### 4.2 ImageSetConfiguration

Install only (Lab-validated shape; use `stable-5.0` for production, `fast-5.0` / `candidate-5.0` if you need a
release that is not yet in stable):

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    graph: true                         # graph data for a local OpenShift Update Service
    channels:
    - name: stable-5.0
      type: ocp
      minVersion: 5.0.0
      maxVersion: 5.0.0
      shortestPath: true
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v5.0
    packages:
    - name: cincinnati-operator         # OpenShift Update Service
      channels: [{name: v1}]
    - name: openshift-cert-manager-operator
      channels: [{name: stable-v1}]
    # do NOT list lightspeed-operator if AI must stay off (section 11)
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
```

- List channels for each package. A package without `channels` brings in the head of every channel. Lab-validated.
- If you also mirror an upgrade path from 4.22, see `docs/guidance-m8-mirroring-4x-to-5.md`. Never list a 4.x and
  a 5.x channel together; oc-mirror fails (Known issue K1).
- A standard run mirrors both RHCOS 9.8 and RHCOS 10.2 node images and both boot ISOs, so either `osImageStream`
  works offline. Lab-validated.
- `kubeVirtContainer: true` (hosted control planes on OpenShift Virtualization) mirrors only the RHCOS 9 KubeVirt
  image (Known issue K6).

### 4.3 Run it

Fully air-gapped (two steps):

```bash
# connected side: mirror to disk.  Lab-validated (5.0.0 platform: 199 images, 24.85 GB archive, about 5 min)
oc-mirror --v2 -c imageset-config.yaml file:///data/oc-mirror --authfile ./pull-secret.json

# carry /data/oc-mirror (mirror_*.tar and working-dir) plus imageset-config.yaml into the enclave

# air-gapped side: disk to mirror.  Documented only (not run in our lab)
oc-mirror --v2 -c imageset-config.yaml --from file:///data/oc-mirror \
  docker://<registry-fqdn>:8443/ocp5 --authfile ./mirror-auth.json
```

Mirror-to-mirror, when one host sees both sides (Lab-validated: 5.0.0 platform 199 images in 8.5 to 13 min;
with a 4.22 path and three operators, 34 min):

```bash
oc-mirror --v2 -c imageset-config.yaml --workspace file://$HOME/oc-mirror/m2m \
  docker://<registry-fqdn>:8443/ocp5 --authfile ./merged-auth.json
```

`merged-auth.json` = the Red Hat pull secret plus an entry for the mirror registry.

Gotchas (Lab-validated): concurrent runs on one host collide on port 55000 (use `--port`); `--dry-run` still builds
the graph image and extracts catalogs; oc-mirror warns unless the umask is 022.

### 4.4 What you get

`working-dir/cluster-resources/` after disk-to-mirror or mirror-to-mirror (mirror-to-disk writes **nothing** here):
IDMS (`idms-oc-mirror.yaml`), ITMS, CatalogSource, ClusterCatalog (OLM v1), release signature ConfigMaps,
`updateService.yaml`. Lab-validated.

The release IDMS for a 5.0-only mirror has two sources (Lab-validated):

```yaml
  - mirrors: [<registry-fqdn>:8443/ocp5/openshift/release]
    source: quay.io/openshift-release-dev/ocp-v5.0-art-dev      # NEW in OpenShift 5: the 5.0 payload lives here
  - mirrors: [<registry-fqdn>:8443/ocp5/openshift/release-images]
    source: quay.io/openshift-release-dev/ocp-release
```

Without the `ocp-v5.0-art-dev` mapping, bootstrap pulls from quay.io and a disconnected install fails. Several 5.0
documentation pages still show only `ocp-v4.0-art-dev`; copy every entry from the generated IDMS.

oc-mirror copies the sigstore signature tags with the images. Do not use `--remove-signatures`. Lab-validated.

## 5. Extracting the installer from the mirror

Take `openshift-install-fips` from the **mirrored** release instead of carrying the CDN tarball across. The binary is
pinned to the mirrored release digest and takes the RHCOS boot images from that payload. Lab-validated on RHEL 9.8
FIPS (55 s) and RHEL 10.2 FIPS (31-34 s) hosts with no internet route:

```bash
# idms.yaml: an ImageDigestMirrorSet holding the same mirrors you will put in install-config imageDigestSources
cat > idms.yaml <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: install-mirrors
spec:
  imageDigestMirrors:
  - mirrors: [<registry-fqdn>:8443/ocp5/openshift/release-images]
    source: quay.io/openshift-release-dev/ocp-release
  - mirrors: [<registry-fqdn>:8443/ocp5/openshift/release]
    source: quay.io/openshift-release-dev/ocp-v5.0-art-dev
  - mirrors: [<registry-fqdn>:8443/ocp5/openshift/release]
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF
REF=<registry-fqdn>:8443/ocp5/openshift/release-images:5.0.0-x86_64
oc adm release info    --idms-file idms.yaml -a mirror-auth.json --certificate-authority rootCA.pem "$REF"
oc adm release extract --idms-file idms.yaml -a mirror-auth.json --certificate-authority rootCA.pem \
  --command=openshift-install-fips --to ./bin "$REF"
./bin/openshift-install-fips version     # "release image <registry-fqdn>:8443/ocp5/openshift/release-images@sha256:..."
```

The warning `--idms-file ... only applies to images referenced by digest` is harmless.

The 5.0 FIPS documentation's "download from the public mirror" link points at a 4.18 installer. Do not use it
(Known issue K10).

## 6. AWS credentials for cluster operators (STS with ccoctl)

We used `credentialsMode: Manual` with AWS STS: short-lived tokens through an IAM OIDC provider, no long-lived keys
in the cluster. Lab-validated in commercial AWS (all five installs). Not run in GovCloud or ISO (section 13).

```bash
# 1. CredentialsRequests for the capabilities you enable, from the MIRRORED payload (works offline)
oc adm release extract --idms-file idms.yaml -a mirror-auth.json --certificate-authority rootCA.pem \
  --credentials-requests --included --install-config install-config.yaml --to ./credrequests "$REF"
# 2. Plan (no AWS credentials needed), then create
ccoctl aws create-all --name <unique-prefix> --region <region> \
  --credentials-requests-dir ./credrequests --output-dir ./ccoctl --dry-run
ccoctl aws create-all --name <unique-prefix> --region <region> \
  --credentials-requests-dir ./credrequests --output-dir ./ccoctl
```

With our capability set this gave 6 CredentialsRequests, 6 IAM roles and policies, the OIDC provider and its S3
bucket. Lab-validated (the dry run offline on RHEL 10 FIPS; the real run from a connected host).

- `ccoctl`'s default OIDC bucket is **public**, because AWS STS must read the discovery documents. The private
  option (`--create-private-s3-bucket`) uses CloudFront, which the ISO regions do not have. Untested outside
  commercial AWS.
- `openshift-install` itself needs AWS credentials that can create the infrastructure. We used IAM user keys in the
  environment on the install host. With `credentialsMode: Mint`, the installer rejects an EC2 instance role.
  Lab-validated. Instance-role credentials with `Manual` were not tested.
- Clean up after `destroy cluster`: `ccoctl aws delete --name <unique-prefix> --region <region>`.

## 7. install-config.yaml

Lab-validated (installs 3-5) except where marked. Replace every `<...>`.

```yaml
apiVersion: v1
baseDomain: <base-domain>
metadata:
  name: <cluster-name>
publish: Internal                      # private cluster: internal load balancers, private hosted zone
credentialsMode: Manual                # STS, section 6
fips: true                             # needs openshift-install-fips on a FIPS host; cannot be changed later
osImageStream: rhel-10                 # 5.0 default (RHCOS 10.2). rhel-9 = RHCOS 9.8, see note
capabilities:
  baselineCapabilitySet: None
  additionalEnabledCapabilities:       # everything a 5.0 Default cluster accepts, minus Insights and openshift-samples
  - baremetal
  - Console
  - marketplace
  - Storage
  - CSISnapshot
  - NodeTuning
  - MachineAPI
  - Build
  - DeploymentConfig
  - ImageRegistry
  - OperatorLifecycleManager
  - OperatorLifecycleManagerV1
  - CloudCredential
  - Ingress
  - CloudControllerManager
controlPlane:
  name: master
  replicas: 3
  architecture: amd64
  platform:
    aws:
      type: m6i.xlarge
      zones: [<az>]
      # amiID: <rhcos-ami>             # ISO / ISO-B only (section 13); must match osImageStream
compute:
- name: worker
  replicas: 2
  architecture: amd64
  platform:
    aws:
      type: m6i.xlarge
      zones: [<az>]
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: <vpc-cidr>                   # must not overlap 100.64.0.0/16 (OVN-Kubernetes)
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: <region>
    vpc:
      subnets:                         # private subnets only; ControlPlaneExternalLB is not allowed with Internal
      - id: <private-subnet-id>
        roles:
        - type: ClusterNode
        - type: BootstrapNode
        - type: IngressControllerLB
        - type: ControlPlaneInternalLB
imageDigestSources:                    # copy every entry from oc-mirror's idms-oc-mirror.yaml
- mirrors: [<registry-fqdn>:8443/ocp5/openshift/release-images]
  source: quay.io/openshift-release-dev/ocp-release
- mirrors: [<registry-fqdn>:8443/ocp5/openshift/release]
  source: quay.io/openshift-release-dev/ocp-v5.0-art-dev
- mirrors: [<registry-fqdn>:8443/ocp5/openshift/release]
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev     # harmless for 5.0; needed for 4.x upgrade paths
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  <mirror registry root CA>
  -----END CERTIFICATE-----
pullSecret: '<Red Hat pull secret + mirror registry entry, WITHOUT cloud.openshift.com>'
sshKey: '<ssh public key>'
```

Why these choices:

- **Capabilities.** Insights (remote health reporting) cannot work air-gapped. Leaving out `openshift-samples`
  stops the samples operator from probing registry.redhat.io on first start (17 blocked attempts over 5 minutes).
  The ImageStreams in the `openshift` namespace (cli, must-gather, ...) come from the payload, not from samples.
  A capability you leave out can be enabled later; one you enable cannot be removed. Lab-validated.
- **Never add `CompatibilityRequirements` or `ClusterAPI`.** The 5.0 installer accepts them, but a Default
  (non-TechPreview) cluster's ClusterVersion API rejects them. The ClusterVersion object is never created, the
  cluster version operator waits forever and the install stalls at bootstrap with NotReady control-plane nodes.
  Lab-validated (Known issue K3). There is no `v5.0` baseline capability set either (the options stop at `v4.18`
  and `vCurrent`).
- **On AWS IPI**, `Ingress`, `CloudCredential`, `CloudControllerManager` and `MachineAPI` cannot be removed.
- **Pull secret without `cloud.openshift.com`**: no telemetry token. With Insights off we saw no telemetry traffic.
  Lab-validated.
- **`osImageStream`**: `rhel-10` worked with FIPS on all installs. Choose `rhel-9` if you need runC (RHCOS 10 has
  none), or if your accreditation requires FIPS modules with published validation certificates (the 5.0 FIPS
  documentation has no RHCOS 10 statement yet). RHCOS 9 is removed in 5.3. See
  `docs/checklist-f7-rhcos10-fips-workloads.md`. `rhel-9` installs on AWS IPI: Untested (agent ISO build with
  `rhel-9`: Lab-validated).
- **`additionalTrustBundle`** covers node image pulls only. ImageStream imports need the day-0 `image.config`
  manifest in section 8. Lab-validated.

Validate before you install (Lab-validated):

```bash
mkdir install && cp install-config.yaml install/
openshift-install-fips create manifests --dir install
grep -A20 additionalEnabledCapabilities install/manifests/cvo-overrides.yaml   # no CompatibilityRequirements / ClusterAPI
```

## 8. Day-0 manifests

After `create manifests`, copy the ccoctl output and these manifests into the install directory. Lab-validated
(install 5 ran with all of them).

```bash
cp ccoctl/manifests/* install/manifests/
cp -a ccoctl/tls install/
cp day0/*.yaml install/openshift/
```

**8.1 Console: hide the Lightspeed button, stop the organization lookup**

```yaml
# day0/99-console-operator-config.yaml
apiVersion: operator.openshift.io/v1
kind: Console
metadata:
  name: cluster
  annotations:
    # Without these, the console operator calls api.openshift.com every 5 minutes (blocked, harmless).
    # Placeholders: a disconnected cluster has no Red Hat subscription to look up. Do not use on connected clusters.
    telemetry.console.openshift.io/ORGANIZATION_ID: "0000000"
    telemetry.console.openshift.io/ACCOUNT_MAIL: "disconnected@example.com"
spec:
  managementState: Managed
  customization:
    capabilities:
    - name: LightspeedButton
      visibility:
        state: Disabled
```

Result: no Lightspeed button from first boot; zero api.openshift.com calls from the console operator. Lab-validated.

**8.2 OperatorHub: turn off the default OLM v0 catalogs**

```yaml
# day0/99-operatorhub-disable-default-sources.yaml
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
```

**8.3 OLM v1: set the default ClusterCatalogs to Unavailable**

`disableAllDefaultSources` does not cover the OLM v1 ClusterCatalogs; without this they retry registry.redhat.io
forever (Known issue K4). One file per catalog: `redhat`, `certified`, `community`.

```yaml
# day0/99-olmv1-clustercatalog-openshift-redhat-operators-unavailable.yaml
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  name: openshift-redhat-operators       # also openshift-certified-operators, openshift-community-operators
spec:
  availabilityMode: Unavailable
  source:
    type: Image
    image:
      ref: registry.redhat.io/redhat/redhat-operator-index:v5.0   # certified-operator-index / community-operator-index
```

Result: all three stay `Unavailable` and are not reconciled back. Lab-validated.

**8.4 Mirror CA for ImageStream imports and the update service**

```yaml
# day0/99-configmap-mirror-registry-ca.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-registry-ca
  namespace: openshift-config
data:
  <registry-fqdn>..8443: |               # host..port (two dots)
    -----BEGIN CERTIFICATE-----
    <mirror registry root CA>
    -----END CERTIFICATE-----
  updateservice-registry: |              # fixed key read by OpenShift Update Service
    -----BEGIN CERTIFICATE-----
    <mirror registry root CA>
    -----END CERTIFICATE-----
---
# day0/99-image-config-additional-trusted-ca.yaml
apiVersion: config.openshift.io/v1
kind: Image
metadata:
  name: cluster
spec:
  additionalTrustedCA:
    name: mirror-registry-ca
```

Without this, ImageStream imports fail certificate checks against the mirror and fall back to quay.io (blocked).
With it: 10/10 ImageStreams imported from the mirror. Lab-validated.

**8.5 Optional: mask the daily DNSSEC trust-anchor refresh (Untested)**

RHCOS 10 nodes try `data.iana.org` at 00:00 UTC every day (blocked, harmless). The cause is probably
`unbound-anchor.timer`, not yet confirmed. A MachineConfig that masks it per role (`master`, `worker`):

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-mask-unbound-anchor-timer
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.5.0
    systemd:
      units:
      - name: unbound-anchor.timer
        mask: true
```

Do not ship a ContainerRuntimeConfig with `defaultRuntime: runc` together with `osImageStream: rhel-10`: the install
fails at bootstrap render (no runc on RHCOS 10).

## 9. Install

Lab-validated (installs 3-5: 42-48 minutes, no manual steps):

```bash
sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288   # local control plane
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=<region>
nohup openshift-install-fips create cluster --dir install --log-level info > install.out 2>&1 &
openshift-install-fips wait-for install-complete --dir install    # if your session drops
```

Keep the AWS credentials and the install directory until you destroy the cluster.

Check:

```bash
export KUBECONFIG=install/auth/kubeconfig
oc get clusterversion
oc get co --no-headers | awk '{print $3,$5}' | sort | uniq -c     # expect all True False (32/32 with our capability set)
oc get nodes -o wide                                               # RHCOS 10.2 (rhel-10)
for n in $(oc get nodes -o name); do oc debug -q "$n" -- cat /host/proc/sys/crypto/fips_enabled; done   # 1 with fips: true
oc get pods -A | grep -E 'ImagePull|ErrImage'                      # expect nothing
```

If the bootstrap times out but the cluster keeps progressing: `openshift-install-fips destroy bootstrap --dir install`
then `wait-for install-complete`. Seen once, after the capability problem in section 7. Lab-validated.

## 10. Post-install

### 10.1 Apply oc-mirror's cluster resources, then WAIT for the rollout

```bash
cd working-dir/cluster-resources
for f in $(ls | grep -vE '^updateService'); do
  case "$f" in *.yaml|*.yml|*.json) oc apply -f "$f" ;; esac
done
oc wait mcp --all --for=condition=Updated=True --timeout=30m
```

IDMS/ITMS changes reach each node through a MachineConfig rollout (no reboot). Until it finishes, pulls of newly
mirrored images go to the source registry (blocked) and back off. We saw an operator bundle pull try
registry.redhat.io one minute after applying the IDMS. **Install no operators before the pools are Updated.**
Lab-validated.

### 10.2 Local update service and CVO upstream

Lab-validated (OSUS 5.0.3 from the mirrored catalog, `RetrievedUpdates=True`):

```bash
oc create ns openshift-update-service
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: {name: update-service-og, namespace: openshift-update-service}
spec: {targetNamespaces: [openshift-update-service]}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: cincinnati-operator, namespace: openshift-update-service}
spec:
  name: cincinnati-operator
  channel: v1
  source: <mirrored redhat-operator-index CatalogSource name>
  sourceNamespace: openshift-marketplace
EOF
oc get csv -n openshift-update-service -w                       # until Succeeded
oc apply -n openshift-update-service -f working-dir/cluster-resources/updateService.yaml
URI=$(oc get updateservice -n openshift-update-service -o jsonpath='{.items[0].status.policyEngineURI}')

# trust the ingress CA cluster-wide (the policy engine route uses it)
oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > ca-bundle.crt
oc create cm user-ca-bundle -n openshift-config --from-file=ca-bundle.crt --dry-run=client -o yaml | oc apply -f -
#   (if user-ca-bundle already exists, append to its ca-bundle.crt instead of replacing it)
oc patch proxy cluster --type merge -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'

oc patch clusterversion version --type merge \
  -p "{\"spec\":{\"upstream\":\"${URI}/api/upgrades_info/v1/graph\",\"channel\":\"stable-5.0\"}}"
oc adm upgrade
```

Until the upstream points at the local service, the cluster version operator calls api.openshift.com (blocked).

### 10.3 Operators

- OLM v0 (Subscription to the mirrored CatalogSource): Lab-validated (update service, lightspeed-operator).
- OLM v1 (ClusterExtension from the mirrored ClusterCatalog): Lab-validated with cert-manager 1.20.1. Wait until the
  ClusterCatalog reports `Serving=True` (about 10 minutes the first time) before creating the ClusterExtension.
  `spec.serviceAccount` is deprecated and ignored in 5.0, but **required on 4.x** (Lab-validated on 4.22.22: "spec.serviceAccount:
  Required value"). If you install OLM v1 operators on 4.22 before upgrading, create an installer service account with the
  permissions the bundle needs and reference it; it does no harm after the upgrade to 5.0.

```bash
oc get clustercatalog
oc wait clustercatalog/<mirrored-catalog> --for=condition=Serving=True --timeout=20m
```

FIPS notes on mirrored operators (Lab-validated): cert-manager is strict FIPS. OpenShift Update Service runs and
works on FIPS nodes but is built on RHEL 8 / OpenSSL 1.1.1 with a Go operator that is not built for strict FIPS;
ask Red Hat for a statement if that matters to you.

### 10.4 Manual (STS) clusters and upgrades

After install the cloud-credential operator reports `Upgradeable=False` (`MissingUpgradeableAnnotation`) until the
`cloudcredential.openshift.io/upgradeable-to` annotation is set. This is expected for Manual mode. Before a minor or
major update (Lab-validated for 4.22.22 -> 5.0.1, 2026-11-10):

```bash
# on a connected host, with the TARGET release's tools
oc adm release extract --credentials-requests --included --install-config install-config.yaml \
    --to credrequests-<target> quay.io/openshift-release-dev/ocp-release:<target>-x86_64
ccoctl aws create-iam-roles --name <ccoctl-name> --region <region> \
    --credentials-requests-dir credrequests-<target> \
    --identity-provider-arn arn:<partition>:iam::<account>:oidc-provider/<issuer-host> --output-dir out-<target>
# on the cluster
oc apply -f out-<target>/manifests/
oc annotate cloudcredential.operator.openshift.io/cluster \
    cloudcredential.openshift.io/upgradeable-to=<target> --overwrite
```

Reuse the existing OIDC provider (`create-iam-roles`, not `create-all`).

## 11. Keeping AI features off

OpenShift 5.0 has no install-config switch for AI. The AI features need the OpenShift Lightspeed operator (an OLM
add-on) plus an LLM. What we did, in layers:

| Layer | How | Status |
|---|---|---|
| Do not mirror `lightspeed-operator` | Leave it out of the ImageSetConfiguration. No operator, no CRDs, no AI | Lab-validated (installs 2, 3) |
| Hide the console entry point | Day-0 Console manifest, section 8.1 | Lab-validated; stays hidden even with lightspeed-operator 2.0.0 installed |
| Payload pieces stay idle | The payload contains an `agentic-skills` image and a cluster version operator controller that wait for the AgenticRun CRD. Without the operator: "AgenticRun CustomResourceDefinition available? false" | Lab-validated |
| Block it by policy | ValidatingAdmissionPolicy set `examples/ai-opt-out-policy/policy.yaml` | Lab-validated on 5.0.0 with lightspeed-operator 2.0.0 installed |

The policy (built into the API server, nothing to mirror) denies, even for cluster-admin and `system:masters`:
creating or changing any `ols.openshift.io` or `agentic.openshift.io` object (OLSConfig, AgenticOLSConfig,
AgenticRun, LLMProvider, ...); Subscriptions and ClusterExtensions for `lightspeed-operator`; turning the console
`LightspeedButton` back on or adding the Lightspeed console plug-ins; creating the two Lightspeed ConsolePlugins.
Members of the group `ai-opt-out-break-glass` bypass it. One exception is allowed on purpose: creating
`AgenticOLSConfig cluster` with `spec.suspended: true`, which is the vendor's kill switch for the agentic layer
(the CRD and the `spec.suspended` field, "halts all agentic operations cluster-wide", are confirmed on lightspeed-operator 2.0.0; creating it through the admission policy is not yet tested).

If lightspeed-operator is installed anyway, also turn the kill switch on:

```yaml
apiVersion: agentic.openshift.io/v1alpha1   # cluster-scoped; CRD agenticolsconfigs.agentic.openshift.io (lightspeed-operator 2.0.0)
kind: AgenticOLSConfig
metadata:
  name: cluster
spec:
  suspended: true
```

Note: hiding the console button does not hide AI Hub. AI Hub appears once lightspeed-operator from the 5.0
catalog is installed, an `OLSConfig` exists and a 5.x update has completed.

```bash
oc apply -f examples/ai-opt-out-policy/policy.yaml
oc get validatingadmissionpolicies -l ai-opt-out.example.com/policy=true
# test (expect Forbidden)
oc apply --dry-run=server -f examples/ai-opt-out-policy/tests/olsconfig.yaml
# break-glass
oc adm groups new ai-opt-out-break-glass <user>
```

Not covered: hand-made CSVs, Helm installs (the MCP server for OpenShift ships as a Helm chart; do not mirror it),
and LLM egress (block it at the firewall). A cluster-admin can delete the policy; manage it with GitOps or ACM and
restrict who can delete ValidatingAdmissionPolicies.

## 12. Expected blocked egress after install

- **data.iana.org once a day at 00:00 UTC from every node:** `unbound-anchor.timer` (DNSSEC root trust anchor refresh,
  `OnCalendar=daily`, `Persistent=true`) is on RHCOS 9.8 and RHCOS 10.2 nodes (Lab: timer seen on 4.22.22 nodes; calls seen on
  5.0.0 nodes). Harmless when blocked. To stop it, mask `unbound-anchor.timer` with a MachineConfig per pool (our lab generator:
  `DISABLE_UNBOUND_ANCHOR=true`; Untested end to end).


With everything above in place, a healthy disconnected 5.0 cluster still tries these destinations. All are blocked
harmlessly; **do not open firewall exceptions**. Lab-validated by packet capture and proxy logs.

| Destination | Caller | When | Can it be stopped? |
|---|---|---|---|
| quay.io:443 | openshift-controller-manager image-signature-import controller (leader pod) | A burst of about 22 connections every hour at hh:59:57, plus one burst per leader change | No supported switch. It ignores the mirror configuration (Known issue K7). Harmless: imports and pulls still work |
| data.iana.org:443 | All RHCOS 10 nodes | Daily at 00:00 UTC | Probably `unbound-anchor.timer` (unconfirmed); optional mask in 8.5 (Untested) |
| api.openshift.com:443 | Cluster version operator | During install, until 10.2 | Yes: point the upstream at the local update service |
| api.openshift.com:443 | Console operator | Every 5 min | Yes: the day-0 annotations in 8.1 (Lab-validated: zero calls) |
| registry.redhat.io:443 | Samples operator (first start) / OLM v1 default catalogs | 5 min / forever | Yes: leave out `openshift-samples`; day-0 ClusterCatalog manifests |
| 172.30.0.1:443 (no SNI) | Workers while joining | First minutes after a node boots | Not internet traffic (kubernetes Service address before OVN is ready). Drop 172.30.0.0/16 quietly at the proxy if it clutters audits |

Not seen at any time: cloud.openshift.com, console.redhat.com, sso.redhat.com, Insights or telemetry endpoints,
mirror.openshift.com, rhcos.mirror.openshift.com, any LLM endpoint.

## 13. GovCloud and ISO / ISO-B gaps

| Topic | GovCloud (`aws-us-gov`) | ISO / ISO-B (`aws-iso`, `aws-iso-b`) | Status |
|---|---|---|---|
| RHCOS AMI | Published AMIs for both streams in us-gov-east-1/west-1; nothing to do | **None published.** Import an RHCOS AMI of the **same stream** as `osImageStream` and set `amiID` on `controlPlane` and `compute` (or `defaultMachinePlatform`). The installer does not check that the AMI matches the stream. A custom AMI turns off MCO boot-image management | Code review only; Untested |
| Network load balancer security groups | Supported | ISO regions do not support security groups on NLBs. The installer's AWS cluster-api provider skips them in us-iso-east-1, us-iso-west-1 and us-isob-east-1 (since 4.18). Other secret regions (for example us-isob-west-1) are not on that list. Red Hat's 5.0 docs still describe secret regions as not tested | Code review only; Untested |
| AWS API CA bundle | Public CAs | The regions' API endpoints use a private CA: append it to `additionalTrustBundle` | Documented only |
| ccoctl STS | Default public S3 OIDC bucket works; check your policy allows a public bucket | No supported STS path today: ccoctl 5.0 builds commercial-partition ARNs for ISO regions, and the private-bucket option needs CloudFront. Use Mint, Passthrough or manually maintained long-term credentials | Code review only; Untested |
| Private hosted zones / DNS | | A known DNS issue for user-provisioned DNS in Top Secret regions (Red Hat KB 7140712); the fix is not in 5.0.0 | Documented only |
| AWS service endpoints | Partition endpoints | Partition endpoints; the installer's `serviceEndpoints` may be needed | Untested |
| Partition ARNs and DNS suffixes in your own automation | `arn:aws-us-gov:` | `arn:aws-iso:` / `arn:aws-iso-b:` | Our lab template is partition-aware but was only run in commercial |
| Publish | Internal recommended | Internal only | Lab-validated (Internal, commercial) |

## 14. Upgrades

- **4.x → 5.0 mirroring:** use one 5.x channel from 4.22.z, or two oc-mirror runs from older releases. Details,
  ImageSetConfigurations and what is validated: `docs/guidance-m8-mirroring-4x-to-5.md`. An actual disconnected
  4.22 → 5.0 cluster upgrade is **Untested**; the mirror content and the update-service edge are Lab-validated.
- **5.0.z updates:** mirror the new release with the same channel, apply the new cluster resources (10.1, wait for
  the pools), and the local update service offers the edge. Untested (5.0.0 was the newest release in the lab).
- **RHCOS 9 → 10 on upgraded clusters:** clusters upgraded from 4.x stay on `rhel-9` until you switch the
  OSImageStream. Before switching, remove runC (most clusters that ran 4.17.11+ are on runC without knowing it) and
  inventory workloads: `docs/checklist-f7-rhcos10-fips-workloads.md`. RHCOS 9 is removed in 5.3.
- **Clusters that already run OpenShift Lightspeed** get the agentic console plug-in after the upgrade. Remove the
  operator or its plug-in first if AI must stay off, and apply the policy in section 11. Untested.
- Re-run the fapolicyd trust script after replacing any tool on the hosts (2.3).

## 15. Known issues (internal)

**INTERNAL: do not share Jira links with customers. Use the published errata / KCS once available.**

| ID | Issue | Workaround | Jira |
|---|---|---|---|
| K1 | oc-mirror fails when an ImageSetConfiguration lists a 4.x and a 5.x channel | One 5.x channel from 4.22.z; two runs below 4.22 | OCPBUGS-136257 |
| K2 | oc-mirror CDN tarball (2.0.0) is not FIPS-capable | Container image build `oc-mirror-plugin-rhel9:v5.0` | OCPBUGS-136646 |
| K3 | Installer accepts `CompatibilityRequirements` / `ClusterAPI`, cluster rejects them, install stalls | Leave them out | OCPBUGS-136614 |
| K4 | OLM v1 default ClusterCatalogs ignore `disableAllDefaultSources` | Day-0 `availabilityMode: Unavailable` | OCPBUGS-136645; docs OSDOCS-24188 |
| K5 | `oc-mirror list operators --catalogs` ignores `--authfile` | Use `--catalog <index>` | OCPBUGS-136644 |
| K6 | `kubeVirtContainer` mirrors only the RHCOS 9 KubeVirt boot image | Add the RHCOS 10 image as `additionalImages` | OCPBUGS-138157 |
| K7 | image-signature-import controller calls quay.io hourly, ignores IDMS | None (harmless) | OCPBUGS-77404 |
| K8 | mirror-registry: quay-app starts before quay-pod after reboot | systemd drop-in (3.2) | PROJQUAY-14321 |
| K9 | Docs: `ocp-v5.0-art-dev` missing from mirror samples; deprecated `imageContentSources` | Copy the generated IDMS | OSDOCS-24144 |
| K10 | Docs: FIPS installer download link points at 4.18 | Extract from the mirror (section 5) | OSDOCS-24145 |
| K11 | Docs: invalid YAML in AWS sample install-configs | | OSDOCS-24146 |
| K12 | Docs: ImageStream imports need `image.config` `additionalTrustedCA` | Day-0 manifest (8.4) | OSDOCS-24189 |
| K13 | Docs: no RHEL 10 / RHCOS 10 FIPS statement | Ask Red Hat; `rhel-9` if validated modules are required | OSDOCS-24190 |
| K14 | Docs: agent-based disconnected procedure still describes oc-mirror v1 | Use v2 cluster-resources | OSDOCS-24191 |
| K15 | Docs: no AI opt-out guidance | Section 11 | OSDOCS-24192 |
| K16 | Docs: Lightspeed wording ("early access"; Red Hat Lightspeed vs OpenShift Lightspeed) | | OSDOCS-24193 |
| K17 | Docs: FIPS drops X25519 and all PQC groups; `custom.groups` unknown field | Clients must offer P-256/P-384 | OSDOCS-24203 |
| K18 | Docs: console organization lookup after remote-health opt-out | Day-0 annotations (8.1) | OSDOCS-24204 |
| K19 | `EvaluationConditionsDetected` misses the 4.17 runC override MachineConfigs | Use the `RuncDeprecated` alert / node check | Not filed (draft) |
| K20 | RHCOS 10 nodes call data.iana.org daily | Optional mask (8.5), unconfirmed | Not filed |
| K21 | ISO regions: NLB security groups are skipped only for us-iso-east-1, us-iso-west-1, us-isob-east-1 (CAPA list); user-provisioned DNS bug (OCPBUGS-78093) not fixed in 5.0.0; ccoctl STS not supported in ISO (OCPSTRAT-3586) | Mint/Passthrough/manual credentials for ISO | Existing tickets |

## Appendix: lab scripts that implement this runbook

All in this repository; written for the lab VPC, not for direct customer use.

| Step | Script |
|---|---|
| ImageSetConfiguration | `scripts/generate-imageset-config.sh` |
| Mirror-to-mirror | `scripts/bastion-mirror-to-mirror.sh` |
| Registry CA and pull secret | `scripts/30-fetch-mirror-credentials.sh` |
| install-config + day-0 manifests | `scripts/generate-install-config.sh` |
| STS | `scripts/20-prepare-sts.sh` |
| FIPS on a RHEL 9 host | `scripts/35-enable-fips-host.sh` |
| Installer from the mirror | `scripts/38-extract-installer.sh` |
| Install | `scripts/40-install-cluster.sh` |
| Post-install | `scripts/45-post-install.sh` |
| fapolicyd | `examples/fapolicyd/` |
| AI opt-out policy | `examples/ai-opt-out-policy/` |
