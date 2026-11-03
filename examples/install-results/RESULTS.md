# OpenShift 5.0 installs in the simulated disconnected VPC (2026-11-03)

Both installs: OCP **5.0.0** (`candidate-5.0`), AWS us-east-2, one AZ, IPI into the pre-existing VPC from
`cloudformation/disconnected_vpc_plus.yaml`, `publish: Internal`, `credentialsMode: Manual` (ccoctl STS),
3 control plane + 2 workers (`m6i.xlarge`). The release was mirrored from the bastion into mirror-registry
with oc-mirror 2.0.0 (`examples/oc-mirror-5.0-m2m/`). The private subnet's only egress is the Squid
allowlist (AWS APIs and RHUI); quay.io and registry.redhat.io are blocked.

Pre-install check, from the registry node (quay.io blocked): the installer's release digest
`sha256:5d7ed8b3...2e55` resolves through the mirror IDMS, and all 197 payload images are present in the mirror.

## Install 1: baseline (installed from the registry node, private subnet)

| | |
|---|---|
| Result | Install complete; 33/33 cluster operators Available, none Degraded |
| Nodes | RHCOS 10.2.20261027-0 (`osImageStream: rhel-10`, the 5.0 default) |
| Images | All pulled from the mirror; node `registries.conf` maps `ocp-v5.0-art-dev` to it |
| Insights | Capability disabled at install (`baselineCapabilitySet: None` + explicit list); no `insights` operator |

Issues found:

1. **Capability list rejected by the cluster (OCPBUGS-136614).** `CompatibilityRequirements` and
   `ClusterAPI` pass install-config validation but the 5.0 ClusterVersion API rejects them on a Default
   feature set. bootkube could not create the ClusterVersion object, the CVO waited ("No cluster version
   object"), masters stayed NotReady. Recovered by `oc create` of a corrected ClusterVersion; the generator
   now uses the 16 accepted values.
2. The delay pushed the installer past its bootstrap timeout; `openshift-install destroy bootstrap` +
   `wait-for install-complete` finished the install.
3. The default OperatorHub catalogs sat in ImagePullBackOff (registry.redhat.io blocked). Now disabled by
   a day-0 manifest (`DISABLE_DEFAULT_CATALOGS`).
4. `credentialsMode: Mint` is rejected when the installer only has an EC2 instance role; STS (Manual +
   ccoctl, `scripts/20-prepare-sts.sh`) is now the default.

## Install 2: FIPS + OpenShift Lightspeed disabled (installed from the FIPS-mode bastion)

47 minutes, no manual intervention.

**FIPS**

| Check | Result |
|---|---|
| Install host | RHEL 9.6 bastion after `fips-mode-setup --enable` + reboot (`scripts/35-enable-fips-host.sh`); `openshift-install-fips` 5.0.0 |
| install-config | `fips: true` |
| Rendered MachineConfigs (master, worker) | `spec.fips: true` |
| Every node (5/5) | `/proc/sys/crypto/fips_enabled = 1`, crypto policy `FIPS`, `fips=1` on the kernel command line, **RHCOS 10.2** |

RHCOS 10 boots and runs the cluster in FIPS mode. (Whether the RHEL 10 crypto modules hold FIPS 140-3
certificates is a separate, compliance question.)

**OpenShift Lightspeed / AI features off**

| Check | Result |
|---|---|
| Console | `consoles.operator.openshift.io cluster`: `LightspeedButton` visibility `Disabled` from first boot (day-0 manifest, `DISABLE_LIGHTSPEED`) |
| Operator availability | `lightspeed-operator` not mirrored; 0 lightspeed packagemanifests; 0 CatalogSources; `disableAllDefaultSources: true` |
| CRDs / namespace | No Lightspeed, OLSConfig or AgenticRun CRDs; no `openshift-lightspeed` namespace |
| CVO AI controller | The payload's `agenticrun-lifecycle-controller` logs `AgenticRun CustomResourceDefinition available? false` and stays inactive |
| Overall | 33/33 operators healthy, no image pull failures, Insights capability absent |

Side effects of FIPS on the bastion: sshd stops offering its ED25519 host key and presents ECDSA, so SSH
reports a changed host key once (expected); podman keeps working after the reboot once the SELinux policy
matches the installed systemd (see the template's full `dnf update`).

## Reproduce

```bash
scripts/10-deploy-vpc.sh
# on the bastion: generate-imageset-config.sh output -> bastion-mirror-to-mirror.sh
scripts/30-fetch-mirror-credentials.sh
scripts/generate-install-config.sh --fips on      # day-0 manifests from cluster.env flags
scripts/20-prepare-sts.sh
scripts/35-enable-fips-host.sh bastion
INSTALL_HOST=bastion scripts/40-install-cluster.sh start
INSTALL_HOST=bastion scripts/40-install-cluster.sh wait
```
