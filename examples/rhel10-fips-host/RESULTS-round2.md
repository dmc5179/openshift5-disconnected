# OpenShift 5.0 tooling on a RHEL 10 FIPS host (image mode), round 2 - lab results, 2026-11-04

Round 2 repeats and extends [RESULTS.md](RESULTS.md) on the new bastion image. It answers four questions
for a RHEL 10.2 FIPS host that sits next to an existing mirror registry:

- Can it extract the FIPS installer from the mirror?
- Can it prepare AWS STS?
- Can it mirror with the FIPS-built oc-mirror?
- Can it build an Agent ISO offline?

Tags: **[LAB]** observed on this host, **[CODE]** read in `openshift/installer` `release-5.0`, **[INFER]**
not directly tested. Validate on your own build before you rely on these results.

## Summary

| # | Test | Result |
|---|---|---|
| R2 | Extract `openshift-install-fips` from the mirrored 5.0.0 payload with the RHEL 9 `oc` 5.0.0 | **PASS**: 31 s. The binary is pinned to the mirror digest, built with `CGO_ENABLED=1` + `strictfipsruntime`, and loads `libcrypto.so.3` and `fips.so` |
| R3 | CredentialsRequests from the mirror + `ccoctl aws create-all --dry-run` (RHEL 9 ccoctl 5.0.0) | **PASS**: 6 CredentialsRequests, 6 roles + 6 policies, OIDC/JWKS/IdP JSON, 7 manifests, RSA 4096 signer key. No AWS credentials needed for the dry run |
| R4 | FIPS-built oc-mirror 5.0.0 (container image) mirror-to-mirror into the stack's Quay | **PASS**: 2/2 images in 28 s. ITMS generated (no IDMS, because tags only). Loads `libcrypto.so.3` + `fips.so` |
| R5 | Agent ISO built offline (`agent create image`, SNO, `fips: true`, nmstate `networkConfig`) | **PASS**: 4 min 08 s. RHCOS 10.2 ISO and stream metadata came from `machine-os-images` in the mirror, the ISO is 839,985,152 bytes with volume `rhcos-10.2.20260922-0` and `fips=1`. A rerun with quay.io, registry.redhat.io, mirror.openshift.com, rhcos.mirror.openshift.com and api.openshift.com blackholed passed too (4 min 18 s, 0 connection attempts) |

## Environment

| Item | Value |
|---|---|
| Host | EC2 m6i.2xlarge, AMI `ami-098b8add0cef379d4` (`rhel10-bootc-aws-fips-bastion-20261104-102712`, us-east-2), RHEL 10.2 image mode (bootc), `fips_enabled=1`, crypto policy `FIPS`, 300 GB root. User `cloud-user` |
| Image layout | `/usr/local` -> `/var/usrlocal` and `/opt` -> `/var/opt` (writable with sudo). Baked-in tools: wget, unzip, nmstatectl 2.2.60, xorriso, awscli 2.33, podman, skopeo, jq. No dnf repositories. No `strings`, `go` or `yq` |
| Network | Public subnet of the lab VPC, with a direct internet route, so this host cannot prove "no internet" by itself. Offline claims below rest on what each tool pulled (mirror references in the logs), plus explicit `/etc/hosts` + `iptables` blocks of the Red Hat internet endpoints during R5 |
| Mirror | mirror-registry (Quay 3.12) on the stack's registry node, `ip-10-0-55-212.us-east-2.compute.internal:8443`, org `ocp5` (4.22.18 + 5.0.0 + operators). Reached from this host on 8443 (health 200) |
| Clients | `oc`/`kubectl` 5.0.0 and `ccoctl` 5.0.0, RHEL 9 builds from `https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/5.0.0/` (sha256 checked against `sha256sum.txt`), installed with `sudo install -m 755 ... /usr/local/bin/`. No RHEL 10 builds are published |
| Inputs | `idms.yaml` built from the lab install-config `imageDigestSources` (`ocp-release` -> `.../ocp5/openshift/release-images`; `ocp-v4.0-art-dev` and `ocp-v5.0-art-dev` -> `.../ocp5/openshift/release`), merged mirror pull secret, mirror root CA. All copied mode 600 to `~/rtests` and deleted afterwards |

The IDMS was built on the workstation, the same way `scripts/38-extract-installer.sh` does it:

```bash
yq '{"apiVersion": "config.openshift.io/v1", "kind": "ImageDigestMirrorSet",
     "metadata": {"name": "install-mirrors"},
     "spec": {"imageDigestMirrors": .imageDigestSources}}' install-config.yaml > idms.yaml
```

## R2 - Extract the FIPS installer from the mirror (I1, F2)

```bash
REF=<mirror>:8443/ocp5/openshift/release-images:5.0.0-x86_64
oc adm release info    --idms-file idms.yaml -a auth.json --certificate-authority ca.pem $REF
oc adm release extract --idms-file idms.yaml -a auth.json --certificate-authority ca.pem \
    --command=openshift-install-fips --to ~/rtests/bin $REF          # rc 0, 31 s
```

`release info` reports `Name: 5.0.0`, `Digest: sha256:5d7ed8b3e98bc3a10c50f36f07262a962d59ad2d3ea5fb4935ff10c408c02e55`,
936 manifests. `oc` prints `warning: --idms-file ... only applies to images referenced by digest and will be
ignored for tags`. This warning is harmless: the release tag is already a mirror reference, and the payload's
component images are digests.

| Check | Result |
|---|---|
| `openshift-install-fips version` | `5.0.0`, commit `f49486a42a4058fb486d6444e6cc13bc56e2eb59`, **release image `<mirror>:8443/ocp5/openshift/release-images@sha256:5d7ed8b3...2e55`**, architecture amd64 |
| Size / sha256 | 844,234,512 bytes, `7f0ec9f1...fb39` |
| Build info (`grep -a`, since `go`/`strings` are not in the image) | `go1.26.10`, `CGO_ENABLED=1`, `GOEXPERIMENT=strictfipsruntime`, `-tags=baremetal,fipscapable,release,strictfipsruntime` |
| `ldd` | dynamic: `libresolv.so.2`, `libc.so.6` (libcrypto is loaded with dlopen at run time) |
| `LD_DEBUG=libs ... version` | `calling init: /lib64/libcrypto.so.3` and `calling init: /usr/lib64/ossl-modules/fips.so` |

**Result: PASS [LAB].** The binary you extract is the same commit that the tarball ships (`f49486a4`, also seen
on the RHEL 9 registry node). Its default release image is the mirror digest, so it takes RHCOS boot images
from the mirrored `machine-os-images`, not from the CDN.

## R3 - ccoctl STS dry run from the mirrored release (F2, B-2)

```bash
oc adm release extract --idms-file idms.yaml -a auth.json --certificate-authority ca.pem \
    --credentials-requests --included --install-config install-config-aws.yaml \
    --to ~/rtests/credreqs $REF                                      # rc 0, 9 s
ccoctl aws create-all --name r3-test-sts --region us-east-2 \
    --credentials-requests-dir ~/rtests/credreqs --output-dir ~/rtests/ccoctl-out --dry-run   # rc 0, 1 s
```

`install-config-aws.yaml` is a copy of the lab AWS install-config: `credentialsMode: Manual`,
`baselineCapabilitySet: None` plus 15 capabilities (no Insights). `oc` notes: "If the eventual cluster will not
be the same minor version as this 5.0.0 'oc', the known capability sets may differ."

| Check | Result |
|---|---|
| CredentialsRequests (6) | `aws-ebs-csi-driver-operator`, `cloud-credential-operator-iam-ro`, `openshift-cloud-network-config-controller-aws`, `openshift-image-registry`, `openshift-ingress`, `openshift-machine-api-aws`. This matches the 6 roles in the live install (AGENTS.md I-9) |
| Generated files | `01-oidc-bucket.json`, `02-openid-configuration`, `03-keys.json`, `04-iam-identity-provider.json`, 6 x `05-*-role.json`, 6 x `06-*-policy.json`, 7 manifests (`cluster-authentication-02-config.yaml` plus 6 credentials Secrets), `serviceaccount-signer.private/.public`, `tls/bound-service-account-signing-key.key` |
| Issuer URL | `https://r3-test-sts-oidc.s3.us-east-2.amazonaws.com` (public S3 bucket, the default; see ISO-5 for ISO regions) |
| Signer key | RSA 4096, generated under the FIPS provider |
| AWS credentials | **None present** (no `~/.aws`, no `AWS_*` variables): the dry run makes no AWS calls |
| ccoctl build | `go1.26.10`, `CGO_ENABLED=1`, `GOEXPERIMENT=strictfipsruntime`. `LD_DEBUG` shows `libcrypto.so.3` and `fips.so` loaded |

**Result: PASS [LAB].** You can extract CredentialsRequests from the mirror on the disconnected side, and RHEL 10
FIPS can prepare the STS artifacts. A real `create-all` still needs AWS IAM/S3 API access with credentials.
It was not run here.

## R4 - FIPS-built oc-mirror into the stack's Quay (N-2 workaround on RHEL 10)

```bash
oc image extract registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0 -a rh-auth.json \
    --filter-by-os=linux/amd64 --path /usr/bin/oc-mirror.rhel9:bin/ --confirm      # 21 s
mv bin/oc-mirror.rhel9 bin/oc-mirror
sudo install -m 644 ca.pem /etc/pki/ca-trust/source/anchors/rtests-mirror-ca.pem && sudo update-ca-trust
```

```yaml
# isc.yaml
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi-minimal:latest
  - name: registry.redhat.io/ubi10/ubi-minimal:latest
```

```bash
LD_DEBUG=libs LD_DEBUG_OUTPUT=/tmp/r4-lddebug \
oc-mirror -c isc.yaml --workspace file://$HOME/rtests/ws \
    docker://<mirror>:8443/rhel10-r4 --v2 --port 56600 \
    --cache-dir $HOME/rtests/cache --authfile $HOME/rtests/auth.json     # rc 0, 29 s
```

| Check | Result |
|---|---|
| oc-mirror | image digest `sha256:c259dcb3...6855` (`version=v5.0.0`, `release=202610271435.p2.ga3e6cc2.assembly.stream.el9`), binary sha256 `70eab4d5...70c7`, `GoVersion: go1.26.10 (Red Hat 1.26.10-1.el9_8) X:strictfipsruntime`. The same build as in round 1 |
| Result | `2 / 2 additional images mirrored successfully`, mirror time 28.2 s. Quay created the `rhel10-r4` organization on push |
| Mirrored | `rhel10-r4/ubi9/ubi-minimal` `sha256:dfa0eb04...` (9.8), `rhel10-r4/ubi10/ubi-minimal` `sha256:c039ecb9...` (10.2), checked with `skopeo inspect` |
| Cluster resources | `itms-oc-mirror.yaml` only (`registry.redhat.io/ubi9` -> `.../rhel10-r4/ubi9`, `registry.redhat.io/ubi10` -> `.../rhel10-r4/ubi10`). oc-mirror logs "No images by digests were mirrored. Skipping IDMS generation." |
| FIPS | `LD_DEBUG`: `/lib64/libcrypto.so.3` and `/usr/lib64/ossl-modules/fips.so` initialised |
| Pinned configs | `isc_pinned_<ts>.yaml` and `disc_pinned_<ts>.yaml` written to the workspace |

**Result: PASS [LAB].** The OCPBUGS-136646 workaround (use the container-image build of oc-mirror) works on
RHEL 10.2 FIPS against a remote Quay over TLS with the system trust store. Clean-up: both tags were deleted
with `skopeo delete --authfile ... docker://<mirror>:8443/rhel10-r4/<repo>:latest`. The empty org
`rhel10-r4` and its two empty repositories remain in Quay. Delete them in the Quay UI or API if you want them gone.

## R5 - Agent ISO built offline on RHEL 10 FIPS (I1)

Inputs: the same pattern as [../agent-iso-offline/](../agent-iso-offline/). SNO, `platform: none`, `fips: true`,
default `osImageStream` (rhel-10), the three mirror `imageDigestSources`, mirror root CA in
`additionalTrustBundle` (`additionalTrustBundlePolicy: Always`), and the merged mirror pull secret. The
agent-config has one master with a fake MAC and a static nmstate `networkConfig`, so the `nmstatectl`
validation runs. `oc` 5.0.0 is in `/usr/local/bin` (on `PATH`). A fresh `XDG_CACHE_HOME` was used, so nothing
came from an earlier cache.

```bash
XDG_CACHE_HOME=$HOME/rtests/xdg \
  ~/rtests/bin/openshift-install-fips agent create image --dir ~/rtests/agent --log-level=debug
```

### Run A: `rhcos.mirror.openshift.com` blocked

Before the run, `rhcos.mirror.openshift.com` was pointed to `192.0.2.1` in `/etc/hosts`. Its four current
CloudFront IPv4 addresses and `192.0.2.1` got `iptables -I OUTPUT -d <ip> -j REJECT` rules with per-rule
counters. A `curl` probe confirmed the block and made the one hit counted below.

Result: rc 0, **248 s**, 18:50:50 -> 18:54:58 UTC. Log excerpt (digest shortened):

```
level=warning msg=The imageDigestSources configuration in install-config.yaml should have at least one source field matching the releaseImage value <mirror>:8443/ocp5/openshift/release-images@sha256:5d7ed8b3...
level=info  msg=Extracting base ISO from release payload
level=debug msg=extracting /coreos/coreos10-x86_64.iso to ~/rtests/xdg/agent/image_cache, [oc image extract --path=/coreos/coreos10-x86_64.iso:... --filter-by-os=linux/amd64 --insecure=true --confirm --icsp-file=/tmp/icsp-file... quay.io/openshift-release-dev/ocp-v5.0-art-dev@sha256:4c73d4784e8e...]
level=info  msg=Base ISO obtained from release and cached at [~/rtests/xdg/agent/image_cache/coreos10-x86_64.iso]
level=debug msg=extracting /coreos/coreos10-stream.json to ~/rtests/xdg/agent/files_cache, ...
level=warning msg=base ISO version mismatch in release payload. Expected version 10.2.20261026-0 but found 10.2.20260922-0
level=debug msg=        Generating NMState Config...
level=debug msg=adding MAC interface map to host static network config - Name: eno1 MacAddress:52:54:00:aa:bb:01
level=debug msg=extracting /usr/bin/agent-tui ... ; extracting /usr/lib64/libnmstate.so.* ...
level=info  msg=Generated ISO at ~/rtests/agent/agent.x86_64.iso.
```

| Artifact / check | Value |
|---|---|
| Base ISO (cache) | `coreos10-x86_64.iso`, 831,520,768 bytes |
| Stream metadata | `coreos10-stream.json`: stream `rhcos-4.22`, metal release `10.2.20260922-0` |
| Other files from the payload | `agent-tui`, `libnmstate.so.2.2.60` |
| Agent ISO | `agent.x86_64.iso`, **839,985,152 bytes**, volume ID **`rhcos-10.2.20260922-0`** |
| Kernel arguments (`/EFI/redhat/grub.cfg`) | `coreos.liveiso=rhcos-10.2.20260922-0 ignition.firstboot ignition.platform.id=metal fips=1` |
| nmstate | Host `nmstatectl` 2.2.60 validated the static `networkConfig` (no error, unlike the first run on the RHEL 9 node without nmstate) |
| "Downloading base ISO" / `rhcos.mirror` in the log | 0 lines |
| REJECT counters after the run | 0 on the four CloudFront IPs. 1 on `192.0.2.1`, which was the pre-run `curl` probe |

The base ISO size, agent ISO size, volume ID and RHCOS release are identical to the RHEL 9 FIPS registry-node run (same payload).

### Run B: every Red Hat internet endpoint blackholed

This host has an internet route, and the merged pull secret also holds quay.io and registry.redhat.io
credentials. `oc image extract` tries the ICSP mirror first and can fall back to the source. Run A alone
therefore does not prove that the ISO came from the mirror. Run B added `quay.io`, `cdn.quay.io`,
`cdn01..03.quay.io`, `registry.redhat.io`, `registry.access.redhat.com`, `mirror.openshift.com` and
`api.openshift.com` to `/etc/hosts` as `192.0.2.1` (REJECTed), zeroed the counters, and used a new cache and
work directory.

Result: rc 0, **258 s** (18:55:34 -> 18:59:52 UTC). `Base ISO obtained from release`, `Generated ISO`, ISO
839,985,152 bytes, volume `rhcos-10.2.20260922-0`, `fips=1`. **All REJECT counters stayed at 0**: no tool even
tried to connect to any of those names. The ISO sha256 differs from run A, as expected, because each build
embeds freshly generated ignition, keys and timestamps.

**Result: PASS [LAB].** On RHEL 10.2 FIPS, the mirror-extracted `openshift-install-fips` builds the Agent ISO
entirely from the mirror: it extracts the RHCOS 10 live ISO and stream metadata from `machine-os-images`
through the `imageDigestSources` mapping. The two benign warnings are the same as on RHEL 9: the
release-image/imageDigestSources mismatch, and the payload vs installer-pinned RHCOS version
(10.2.20260922-0 vs 10.2.20261026-0). **[CODE]** The installer falls back to downloading from
`rhcos.mirror.openshift.com` only if the `oc` extraction fails (`pkg/asset/rhcos/iso.go` `retrieveBaseIso()`,
release-5.0; see the negative control in ../agent-iso-offline/RESULTS.md). Keep `oc` on `PATH`.

## Clean-up

- Host: `~/rtests` deleted (secrets, binaries, workspaces, caches and both ISOs). `/etc/hosts` restored from
  backup. All `rtests-R5` iptables rules removed (`iptables -S OUTPUT` shows only `-P OUTPUT ACCEPT`). The
  mirror CA anchor `rtests-mirror-ca.pem` removed and `update-ca-trust` rerun. No processes left running.
- Left on purpose: `oc`, `kubectl` and `ccoctl` 5.0.0 (RHEL 9 builds) in `/usr/local/bin`.
- Quay: the `rhel10-r4` tags were deleted. The empty org `rhel10-r4` (repositories `ubi9/ubi-minimal`,
  `ubi10/ubi-minimal`) remains. The `ocp5` org and the cluster were only read from.
- Workstation: the temporary input directory (mode 700) was deleted.

## What this means for customers

- **[LAB]** A RHEL 10.2 FIPS host (image mode) runs the whole disconnected preparation chain with today's
  RHEL 9 builds: extract the installer from the mirror, extract CredentialsRequests, run the ccoctl dry run,
  mirror with oc-mirror, and build the Agent ISO. Red Hat has not yet published a support statement for RHEL 9
  client builds on RHEL 10, and RHEL 10 tarballs do not exist yet (B-2).
- **[LAB]** Use the container-image build of oc-mirror (`registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0`,
  `/usr/bin/oc-mirror.rhel9`) on FIPS hosts. The CDN tarball does not use the FIPS module (OCPBUGS-136646).
- **[LAB]** In image mode, install clients under `/usr/local/bin` only if your image links `/usr/local` to
  `/var/usrlocal` (this AMI does). Otherwise use `~/.local/bin`. The tools the Agent ISO path needs (`oc` on
  `PATH`, `nmstatectl`) must be in the image, because there are no dnf repos at run time.
