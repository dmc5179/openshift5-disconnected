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

## Install 3: FIPS default + day-0 catalog and CA fixes, on the rebuilt hardened stack

47m56s, no manual intervention (2026-11-04 00:37Z). The stack was rebuilt from the hardened template
first (registry readiness signal, Squid ACLs and SNI logging, persistent iptables), and the bastion was
put in FIPS mode before mirroring.

| Check | Result |
|---|---|
| Cluster | 5.0.0 Available; 33/33 operators Available, none Progressing or Degraded; 0 image pull failures |
| FIPS | All 5 nodes RHCOS 10.2.20261027-0 with `fips_enabled=1`, crypto policy `FIPS`, `fips=1` on the kernel command line |
| OpenShift Lightspeed | `LightspeedButton` Disabled; 0 Lightspeed/OLSConfig/AgenticRun CRDs; 0 lightspeed packagemanifests |
| Insights | Capability absent (no `insights` cluster operator) |
| OLM v0 default catalogs | `disableAllDefaultSources: true`; no CatalogSources |
| **OLM v1 default ClusterCatalogs** (day-0 manifests, `availabilityMode: Unavailable`) | All three stay `Unavailable`, `Serving=False`, 47 min after install; the cluster-olm-operator did not reconcile them back. catalogd logged no registry.redhat.io access. |
| **ImageStream imports** (day-0 `image.config` `additionalTrustedCA` with the mirror CA) | `openshift` namespace: 10 ImageStreams, every tag imported, 0 import failures; references resolve to `ocp-v5.0-art-dev` digests served by the mirror |

**Egress audit (Squid, whole install).** The only attempts to a Red Hat registry were 17 CONNECTs to
registry.redhat.io from one control-plane node, every 20 s from 00:20:31 to 00:25:31, all blocked. The
source is the **cluster-samples-operator**: on first start it probes registry.redhat.io ("test tls connection
to registry.redhat.io experienced SSL handshake error EOF"), then decides it is disconnected and sets itself
to `Removed`. To avoid even this probe, leave `openshift-samples` out of the enabled capabilities.

```bash
# Day-0 manifests used (scripts/generate-install-config.sh, from cluster.env flags)
99-console-disable-lightspeed.yaml                          # DISABLE_LIGHTSPEED
99-operatorhub-disable-default-sources.yaml                 # DISABLE_DEFAULT_CATALOGS
99-olmv1-clustercatalog-openshift-{redhat,certified,community}-operators-unavailable.yaml
99-configmap-mirror-registry-ca.yaml                        # TRUST_MIRROR_FOR_IMAGESTREAMS
99-image-config-additional-trusted-ca.yaml
```

## Install 4: air-gapped FIPS install host, installer from the mirror, hardened stack (2026-11-04)

Fresh stack from the hardened template: m6i.2xlarge bastion, IMDSv2 required, scoped IAM, the NAT readiness
signal. The **registry node** (RHEL 9.8 in FIPS mode, no internet route) was the install host. Its
`openshift-install-fips` was **extracted from the mirrored release payload** (`scripts/38-extract-installer.sh`),
so nothing came from the internet. `DISABLE_SAMPLES=true` (15 capabilities), all day-0 manifests.

| Check | Result |
|---|---|
| Template | IMDSv1 calls return 401, IMDSv2 calls 200 on all three hosts; the staging bucket is readable, `s3 ls` of all buckets is denied; Squid blocks quay.io and registry.redhat.io, and port 3128 returns 403 for disallowed hosts; rules and Squid survive a reboot |
| Mirror (bastion, m6i.2xlarge) | `fast-5.0` 4.22.18 -> 5.0.0, `graph: true`, cincinnati-operator, cert-manager, lightspeed-operator: 34 min. Cluster resources: IDMS (release and operator), ITMS, CatalogSource, ClusterCatalog, signature ConfigMap, UpdateService |
| Installer extraction | `oc adm release extract --idms-file ... --command=openshift-install-fips` against the mirror took 55 s with quay.io blocked. The binary reports the mirror's release digest |
| Install | 45m53s, no intervention. 5.0.0, **32/32** operators available (no `samples` operator), FIPS on all nodes |
| OpenShift Update Service | Operator 5.0.3 from the mirrored CatalogSource; oc-mirror's UpdateService (graph image and releases from the mirror); ingress CA added to the cluster trust bundle; CVO `upstream` set to the local policy engine: `RetrievedUpdates=True`, channel `fast-5.0`, "No updates available" (5.0.0 is the newest release) |
| OLM v1 | cert-manager-operator 1.20.1 installed through a ClusterExtension from the mirrored ClusterCatalog. The catalog takes about 10 min to unpack first; `spec.serviceAccount` is deprecated and ignored in 5.0 |
| lightspeed-operator 2.0.0 installed (OLM v0), no OLSConfig | Console `LightspeedButton` stays **Disabled**; no Lightspeed console plugin is enabled (plugins: networking, monitoring). The operator adds the `olsconfigs.ols.openshift.io` and `agenticolsconfigs.agentic.openshift.io` CRDs and runs two controllers (`lightspeed-operator`, `lightspeed-agentic-operator`) |
| Upgradeable | `False`: the `cloudcredential.openshift.io/upgradeable-to` annotation is missing, as expected for Manual (STS) credentials before an upgrade |

**Egress audit (Squid) during the install, by cluster node.** All attempts were blocked:
- no registry.redhat.io attempts: the samples probe is gone with `DISABLE_SAMPLES`
- **quay.io: 88 attempts** from two control-plane nodes, 06:38-06:59 (66 from one node, about every 20 s, and a burst of 22 from another)
- **api.openshift.com: 22**, from three nodes. Mostly CVO update checks before the CVO was pointed at the local update service
- 70 TLS connections without SNI from two nodes

CRI-O logged no quay.io image pulls (all node pulls went to the mirror), and the openshift-apiserver and
controller-manager logs show none either. The quay.io callers are pods making their own TLS calls, and still
need to be identified (conntrack or a packet capture on the node). Earlier audits looked only for
registry.redhat.io, so installs 1-3 probably had the same traffic.

## Install 5: RHEL 10 FIPS image-mode install host in the private subnet (2026-11-05)

Fresh stack: RHEL 9.8 Squid and registry nodes (newest Red Hat AMI), m6i.xlarge registry, Quay boot-order fix,
IMDSv2, scoped IAM. The install host was a **RHEL 10.2 FIPS image-mode (bootc) instance in the private subnet**:
no internet, egress only through the Squid allowlist. Its tools were copied in from the bastion, and
`openshift-install-fips` was extracted from the mirror on that host. Day 0: FIPS, `rhel-10` stream, Insights and
samples capabilities off, Lightspeed button disabled, OLM v1 default catalogs Unavailable, mirror CA for ImageStreams,
console telemetry annotations.

| Check | Result |
|---|---|
| Template | IMDSv1 401 / IMDSv2 200 on all three hosts; staging bucket readable, `s3 ls` of all buckets denied; Squid blocks quay.io and registry.redhat.io; port 3128 denies google.com; rules survive a Squid reboot |
| RHEL 10 install host | FIPS (`fips_enabled=1`, policy FIPS); rhel9 `oc` 5.0.0 installed; mirror health 200 with the system trust; quay.io blocked |
| Installer extraction | 34 s on the RHEL 10 host from the mirror |
| **Install** | **42m32s** from the RHEL 10 FIPS host, no intervention. 5.0.0, 32/32 operators available, RHCOS 10.2 FIPS nodes |
| Post-install | OSUS 5.0.3 + CVO upstream (`RetrievedUpdates=True`); cert-manager 1.20.1 via OLM v1 (`Installed=True`); lightspeed-operator installed with `LightspeedButton` Disabled and no Lightspeed console plugin; 0 image pull failures |
| **N-11 (kubeVirtContainer)** | oc-mirror 2.0.0 with `kubeVirtContainer: true` mirrored only the RHCOS 9.8 KubeVirt image (`sha256:b58ab403...`); the RHCOS 10.2 image (`sha256:9cf09e8e...`) was **not** mirrored. Confirmed live |

**Egress verdict: FAIL, caused by our post-install script, not the product.**
- **Console telemetry:** **no api.openshift.com calls after the CVO was pointed at the local update service.** The day-0 console telemetry annotations worked.
- **Known exceptions only:** quay.io bursts (OCPBUGS-77404), install-time CVO calls, and the kubernetes service address.
- **The 2 unexpected attempts** were registry.redhat.io from one worker at 05:23:01-16. An OLM bundle-unpack pod pulled the update-service bundle about a minute after the operator IDMS was applied, before the MachineConfig rollout had put the mirror mapping on that node. It succeeded through the mirror 30 s later.
- **Fix:** `45-post-install.sh` now waits for the MachineConfigPools after applying mirror resources (768ee98).

## Upgrade test: 4.22.22 -> 5.0.1, disconnected, FIPS, Manual STS (2026-11-10)
New AWS account (commercial, us-east-2). `TEST_SCENARIO=upgrade scripts/50-rebuild-and-test.sh`. Squid egress
profile `regional`. Install host: the air-gapped FIPS RHEL 9.8 registry node, `openshift-install-fips` 4.22.22
extracted from the mirror. Mirror: one `fast-5.0` channel, 4.22.22 -> 5.0.1, operators from both the v4.22 and
v5.0 catalogs. [LAB]

| Step | Result |
|---|---|
| Stack deploy | OK, 21 min. Template (62 KB) uploaded to S3 and passed by URL (over CloudFormation's 51,200-byte inline limit) |
| Validate | OK. **Pull secret via SSM (CF-9) validated**; regional egress probes OK |
| Mirror | OK, 26 min. Catalogs v4-22 + v5-0. N-11 (OCPBUGS-138157) reproduces on 5.0.1 |
| Install 4.22.22 | **Timed out at 13:53Z**: ingress `DNSReady=False` (`NoZones`), no `*.apps`, authentication/console unavailable. Cause: Squid blocked 384 calls to `tagging.us-east-1.amazonaws.com` (Route 53 zone lookup by tags). Allowed it: record created 14:19:41Z, `wait-for install-complete` OK, 32/32 operators |
| Post-install | Mirror config rolled out; OSUS from the v4.22 catalog; CVO upstream -> local OSUS, `RetrievedUpdates=True`, **5.0.1 offered as a recommended update**. cert-manager 1.20.1 via OLM v1 (needed `spec.serviceAccount` on 4.22); lightspeed-operator 2.0.0 via OLM v0 |
| Checks (4.22) | crun on all nodes, no runC override MCs (installed after 4.18). `unbound-anchor.timer` daily at 00:00 UTC on RHCOS 9.8 (N-12). LightspeedButton Disabled, no Lightspeed plugin, 0 OLSConfig/AgenticOLSConfig |
| Manual-mode credentials | cloud-credential `Upgradeable=False` (`MissingUpgradeableAnnotation`) as expected. `20-prepare-sts.sh --upgrade-to 5.0.1` (5.0.1 CredentialsRequests, `ccoctl aws create-iam-roles` against the existing OIDC provider), secrets applied, `upgradeable-to=5.0.1` annotation. No admin-ack gates |
| Upgrade | `oc adm upgrade --to=5.0.1` through the local OSUS: **Completed in 64 min**, history `5.0.1 Completed verified=true` (signature verified from the mirror, J8), 32/32 operators, 0 image pull failures. Nodes stay on **RHCOS 9.8** (`osimagestream rhel-9`) |
| AI after upgrade (J5) | lightspeed-operator 2.0.0 installed, no OLSConfig: **no AI Hub / Lightspeed console plugin appeared**; LightspeedButton still Disabled. New core plugin `cluster-update-console-plugin` ("Cluster Updates", payload, owned by the console operator) |
| AI opt-out policy (A5) | Applied (left installed). Kill-switch exception: `AgenticOLSConfig` `suspended: true` ALLOWED, `suspended: false` DENIED (server dry runs). `AgenticOLSConfig` is `agentic.openshift.io/v1alpha1`, cluster-scoped |
| Add-nodes (I4) | Not testable on AWS: `oc adm node-image create` supports only baremetal, vsphere, nutanix, none, external |
| Egress audit | FAIL: tagging.us-east-1 x384 (fixed during the run) and **registry.redhat.io x342 from the masters = catalogd pulling the default OLM v1 ClusterCatalogs**. On this 4.22 install cluster-olm-operator created them during bootstrap before the day-0 `Unavailable` manifests applied (field never set), and after the upgrade they point at `:v5.0`. Day-2 `oc patch ... availabilityMode: Unavailable`: 0 calls in the next 4 min. Now applied by 45-post-install (resources) and after the upgrade |

Script fixes from this run: deploy via S3 template URL; destroy cleans the template bucket and SSM parameter;
regional profile allows the tagging endpoint; 45-post-install ClusterCatalog lookup and ClusterExtension service
account; day-2 default-catalog patch; 60-post-upgrade-tests.sh install-host default.

## Reproduce

```bash
scripts/10-deploy-vpc.sh
# on the bastion: generate-imageset-config.sh output -> bastion-mirror-to-mirror.sh
scripts/30-fetch-mirror-credentials.sh
scripts/generate-install-config.sh               # FIPS on by default; day-0 manifests from cluster.env flags
scripts/20-prepare-sts.sh
scripts/35-enable-fips-host.sh bastion
INSTALL_HOST=bastion scripts/40-install-cluster.sh start
# or the whole run, with the RHEL 10 FIPS host in the private subnet as install host:
#   TEST_INSTALL_HOST=rhel10 scripts/50-rebuild-and-test.sh --yes
INSTALL_HOST=bastion scripts/40-install-cluster.sh wait
```
