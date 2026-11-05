# Code review: I5 (RHCOS 10 boot images for IPI in disconnected environments) and I6 (capabilities in 5.0)

Date: 2026-11-04. Source: `openshift/installer` `origin/release-5.0` @ 8647f26b29 (2026-10-29). Line numbers refer
to that commit (`git show origin/release-5.0:<path>`). Lab cross-checks use the 5.0.0 installer (commit f49486a4)
and the 5.0.0 CVO image. See `examples/install-config-validation/RESULTS.md`.

---

## I5: how IPI picks the RHCOS image, and what a disconnected customer must host

### Stream selection

- `osImageStream` is a top-level install-config field. Valid values: `rhel-9`, `rhel-10` (and `centos-10` for SCOS) (`pkg/types/installconfig.go:780-790`) [CODE].
- If it is empty, it defaults to `rhcos.GetDefaultOSImageStream()` (`pkg/types/defaults/installconfig.go:137-138`), which returns `rhel-10` when the installer's major version is >= 5 and `rhel-9` otherwise (`pkg/rhcos/stream.go:14-29`) [CODE].
- The installer embeds one stream file per stream: `data/data/coreos/coreos-rhel-9.json` (rhcos-4.21 = 9.8.20261026-0) and `coreos-rhel-10.json` (rhcos-4.22 = 10.2.20261026-0), loaded by `fetchRawCoreOSStream()` through `getStreamFileName()` = `coreos/coreos-<stream>.json` (`pkg/rhcos/builds.go:118-119`, `pkg/rhcos/stream.go:31-33`) [CODE]. Both streams have AWS AMIs in 34 regions, including `us-gov-east-1`/`us-gov-west-1`, and none in `us-iso*`/`us-isob*` [CODE].
- `openshift-install coreos print-stream-json --stream rhel-9|rhel-10` prints either stream; without `--stream` it prints the build default, rhel-10 (`pkg/coreoscli/cmd.go:15-44,66`) [CODE][LAB]. **Customers should always pass `--stream`** when they script image downloads. The 5.0 docs examples (`modules/ipi-install-creating-an-rhcos-images-cache.adoc`, `modules/installation-nutanix-download-rhcos.adoc`) call `coreos print-stream-json` without `--stream` [DOC], which silently returns the rhel-10 image even when the cluster uses `osImageStream: rhel-9`.
- Per-platform image selection: `osImage()` in `pkg/asset/rhcos/image.go:86-245` calls `rhcos.FetchCoreOSBuild(ctx, ic.Config.OSImageStream)` (`:93`) and then switches on platform. `OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE` overrides everything (`:58-62`) [CODE].

### Per platform (release-5.0)

| Platform | Default source of the boot image | Override field | Disconnected: what to host | Citation |
|---|---|---|---|---|
| **Bare metal IPI** | **The release payload** (`machine-os-images`). The installer returns "" ("Use image from release payload"). The bootstrap VM's live ISO is extracted from the payload per stream: `/coreos/coreos10-<arch>.iso` for rhel-10, `/coreos/coreos-<arch>.iso` for rhel-9. The installer labels BareMetalHosts and Machines with the stream (`machineconfiguration.openshift.io/osstream`) and builds a `hostSelector` that excludes the other stream. | `platform.baremetal.clusterOSImage` / `bootstrapOSImage` are **deprecated** ("no longer required, the OS image is now part of the OpenShift release"). If set, the installer logs "is no longer required" and does an HTTP HEAD check. | **Nothing** beyond the mirrored payload (incl. `machine-os-images`, which the M5 lab showed contains both ISOs). Do not use clusterOSImage on 5.0. | `pkg/asset/rhcos/image.go:171-177`; `pkg/asset/rhcos/bootstrap_image.go:40-43`; `pkg/infrastructure/baremetal/bootstrap.go:172-181`; `pkg/asset/rhcos/releaseextract.go:40-58`; `pkg/asset/machines/baremetal/machines.go:68-100`, `hosts.go:180,200,285`; `pkg/types/baremetal/platform.go:220-235`; `pkg/types/baremetal/validation/platform.go:235-255` |
| **Agent-based** (any platform) | The release payload (`machine-os-images`), per stream. Falls back to downloading from `rhcos.mirror.openshift.com` when `oc` is missing or extraction fails. | `OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE` (http(s) URL) | Nothing beyond the payload. `oc` must be on PATH (proven offline in examples/agent-iso-offline). | `pkg/asset/rhcos/iso.go:40-56,125-165` |
| **vSphere IPI** | OVA from the stream file (`artifacts.vmware.formats.ova`, a `rhcos.mirror.openshift.com` URL, with `?sha256=`), downloaded and uploaded by the installer. | `platform.vsphere.clusterOSImage` (URL) | **Host the RHCOS OVA for the chosen stream** on a local HTTP server and set `clusterOSImage` (e.g. `rhcos-10.2.20261026-0-vmware.x86_64.ova` for rhel-10). [INFER] A pre-uploaded template per failure domain (`topology.template`) also avoids the download. | `pkg/asset/rhcos/image.go:178-203`; `pkg/types/vsphere/platform.go:82-83` |
| **OpenStack / PowerVC / oVirt** | qcow2.gz from `artifacts.openstack` (rhcos.mirror URL), downloaded and uploaded to Glance. | `platform.openstack.clusterOSImage`: http(s) or `file://` URL, **or the name of an existing Glance image** | Host the RHCOS openstack qcow2 for the stream, or pre-upload it to Glance and give its name. | `pkg/asset/rhcos/image.go:130-140`; `pkg/types/openstack/platform.go:66-69` |
| **Nutanix** | `artifacts.nutanix` qcow2 (rhcos.mirror URL). | `platform.nutanix.clusterOSImage` (URL) or `preloadedOSImageName`. A preloaded image is validated against the **stream's** RHCOS major version. | Host the qcow2 or preload it in Prism. | `pkg/asset/rhcos/image.go:234-241`; `pkg/asset/installconfig/nutanix/validation.go:68-70,117-140` |
| **PowerVS** | COS bucket object per region from the stream. | `platform.powervs.clusterOSImage` | Out of scope here. | `pkg/asset/rhcos/image.go:204-229` |
| **AWS IPI** | Public RHCOS AMI from the stream file for the region (`st.GetAMI(archName, region)`). If the region has no AMI, the us-east-1 AMI is used and copied into the target region during infra creation (`"<ami>,us-east-1"` marker -> `copyAMIToRegion` -> `ec2:CopyImage`). | `amiID` on `platform.aws.defaultMachinePlatform`, `controlPlane.platform.aws` or `compute[].platform.aws` (the `platform.aws.amiID` field is deprecated) | Commercial and **GovCloud**: nothing, because both streams publish AMIs in us-gov-east-1/west-1. **ISO / ISO-B**: the customer must import an RHCOS AMI (see below). | `pkg/asset/rhcos/image.go:104-118`; `pkg/asset/machines/master.go:213-218` (also `worker.go:484-489`, `clusterapi.go:116-121`); `pkg/infrastructure/aws/clusterapi/ami.go:17-29`, `aws.go:78`; `pkg/types/aws/machinepool.go:17-21`, `platform.go:21` |
| GCP / Azure / IBM Cloud | Cloud-published images from the stream (marketplace for Azure). | `osImage` / `clusterOSImage` fields per platform | Not applicable to the target customers. | `pkg/asset/rhcos/image.go:119-170` |
| none / external | "" (UPI / agent) | - | Customer-provided. | `pkg/asset/rhcos/image.go:230-233` |

### AWS ISO / ISO-B in detail (ties into ISO-1 / ISO-4)

- `validateAMI()` (`pkg/asset/installconfig/aws/validation.go:136-191`, called first in `Validate()` at `:59`) accepts the config if the region is in the stream's AMI list (`:138`) or if any `amiID` is set at the platform / defaultMachinePlatform level (`:142-153`) or on the control plane plus all non-zero compute pools (`:155-172`). As the last fallback it allows an AMI copy from us-east-1 **only if the region's EC2 endpoint is in the `aws` partition** (`:174-188`). Otherwise it fails with `platform.aws.amiID: Required value: AMI must be provided` (`:190`) [CODE]. In `aws-iso`/`aws-iso-b` there is no stream AMI and no copy fallback, so **`amiID` is mandatory**. This matches what `generate-install-config.sh` enforces with `RHCOS_AMI_ID` (ISO-1).
- The AMI has to be imported by the customer from the stream's `artifacts.aws.formats["vmdk.gz"]` (`rhcos-10.2.20261026-0-aws.x86_64.vmdk.gz` for rhel-10, the 9.8 vmdk for rhel-9; get the URL with `openshift-install coreos print-stream-json --stream <s>`), carried across the boundary, then imported with `ec2 import-snapshot` + `register-image` [INFER; procedure per the 4.x "secret/top secret region" docs].
- **The installer does not check that a custom `amiID` matches `osImageStream`** [INFER: no such check in `validateAMI` or `validateAMIBootMode` at `:1196`]. An RHCOS 9 AMI with `osImageStream: rhel-10` (or the reverse) boots one OS and then pivots to the stream's node image, which is a slower, unvalidated path. Customers must import the AMI from the **same stream** and ideally the same build as `coreos print-stream-json --stream <s>` of the installer they use.
- A custom AMI also turns off MCO-managed boot image updates for that role: `customBootImages()` -> `awsBootImages()` (`pkg/asset/manifests/mco.go:36-70`) [CODE]. After an upgrade or a stream switch (`rhel-9` -> `rhel-10`) the customer must import a new AMI and update the MachineSets themselves.

### I5 conclusion

- **Bare metal IPI and Agent: no locally hosted RHCOS image is needed on 5.0.** The boot images come from the mirrored payload (`machine-os-images`), per stream. `clusterOSImage` on bare metal is deprecated.
- **vSphere, OpenStack and Nutanix IPI: yes.** Host the platform-specific RHCOS artifact **for the stream in `osImageStream`** (rhel-10 by default) and set `clusterOSImage`, or pre-upload it (Glance image name, Nutanix preloaded image, vSphere template).
- **AWS: commercial and GovCloud need nothing.** ISO / ISO-B need an imported RHCOS AMI of the matching stream in `amiID`. AGENTS.md "I5: IPI clusterOSImage needs a locally hosted RHCOS 10 image" is therefore only true for vSphere, OpenStack and Nutanix (plus AWS ISO via amiID), not for bare metal.

---

## I6: capabilities in 5.0

### What the vendored API defines (installer release-5.0, `vendor/github.com/openshift/api/config/v1/types_cluster_version.go`)

- `ClusterVersionCapabilitySet` enum: `None; v4.11; v4.12; ... v4.18; vCurrent` (`:471`). **There is no `v4.19`-`v4.22` and no `v5.0` baseline.** The newest named set is `v4.18` (`:629-647`) [CODE]. The CVO's 5.0.0 ClusterVersion CRDs show the same `baselineCapabilitySet` enum on every feature set [LAB].
- 19 capability constants (`:320-444`) and `KnownClusterVersionCapabilities` (`:448-468`). New since v4.18: **CompatibilityRequirements** (`:436`, "Compatibility Requirements operator which enforces CRD compatibility constraints via validating webhooks") and **ClusterAPI** (`:444`, "Cluster API operator and controllers"; hard dependency on CompatibilityRequirements) [CODE]. OperatorLifecycleManagerV1 and CloudControllerManager already exist in v4.18.
- `vCurrent` (`:648-668`) = the v4.18 set **plus CompatibilityRequirements and ClusterAPI** (19 entries) [CODE].
- Feature-set-aware enum for `additionalEnabledCapabilities` (`:308-311`): the Default feature set (`featureGate=""`) allows 17 values (no CompatibilityRequirements, no ClusterAPI). `CRDCompatibilityRequirementOperator` adds CompatibilityRequirements, and `ClusterAPIMachineManagement` adds ClusterAPI. CEL rules (`:21-22`): marketplace requires OperatorLifecycleManager, and ClusterAPI requires CompatibilityRequirements [CODE].
- 5.0.0 CVO image (`ocp-v5.0-art-dev@sha256:363cd1db...`, `/manifests/0000_00_cluster-version-operator_01_clusterversions-<FeatureSet>.crd.yaml`): **Default and OKD: 17 values; TechPreviewNoUpgrade, DevPreviewNoUpgrade and CustomNoUpgrade: 19 values** [LAB]. (AGENTS.md I-10 says "16"; the correct count is 17. The `[16]` in the error is a 0-based index.)

### What the installer enforces (release-5.0)

- `validateCapabilities()` (`pkg/types/validation/installconfig.go:1575-1599`) accepts any baseline name in `ClusterVersionCapabilitySets` and **any capability in the union of all sets (19)**. It does not use the feature set. This is the root cause of I-10 / OCPBUGS-136614 [CODE][LAB].
- Cross-capability rules (`installconfig.go:238-286`) [CODE]:
  - `Ingress` is always required (`:282-285`).
  - `CloudCredential` may be disabled only on `baremetal` or `none` (`:263-269`).
  - `CloudControllerManager` may be disabled only on `baremetal`, `none` or `external` with `cloudControllerManager: ""`/none (`:271-280`).
  - `marketplace` requires `OperatorLifecycleManager` (`:248-251,258-261`).
  - With `baselineCapabilitySet: None`, platform `baremetal` requires `baremetal` (`:252-255`).
- **IPI requires `MachineAPI`**: `PlatformProvisionCheck` fails with "IPI requires MachineAPI capability" (`pkg/asset/installconfig/platformprovisioncheck.go:60-63`) [CODE]. Bare metal without MachineAPI skips creating Machines (`pkg/asset/machines/master.go:432-435`). Agent-based and UPI can run without MachineAPI.
- `GetEnabledCapabilities()` (`pkg/types/installconfig.go:692-705`) uses vCurrent when nothing is set, so the installer internally treats CompatibilityRequirements and ClusterAPI as enabled. That is harmless as long as only `baselineCapabilitySet: vCurrent` (not an explicit list) reaches the ClusterVersion object.
- Docs: `modules/enabling-baseline-capability-set.adoc:25` (openshift-docs enterprise-5.0) says "you can specify `vCurrent`, `v{product-version}`, or `None`". On 5.0 that renders as `v5.0`, which the CRD rejects. This is a docs bug candidate [DOC][LAB enum].

### Which capabilities can be disabled at install on 5.0 (Default feature set)

| Capability | Disable at install? | Notes for air-gapped installs |
|---|---|---|
| Insights | Yes | **Disable** (remote health / "Red Hat Lightspeed" reporting; useless offline). |
| openshift-samples | Yes | **Disable** (N-8: probes registry.redhat.io for about 5 min; payload ImageStreams do not depend on it). |
| Console | Yes | Keep unless the customer is headless. Disabling it also removes the Lightspeed console UI. |
| Build, DeploymentConfig | Yes | Optional. Keep if workloads use BuildConfigs or DCs (DC is deprecated). |
| ImageRegistry | Yes | Optional. Without it there is no internal registry (Builds and ImageStream-backed workloads are affected) [INFER]. |
| marketplace | Yes | Optional offline: it only ships the default CatalogSources, which are disabled anyway (`disableAllDefaultSources`). Keep it if you want the OperatorHub UI and `operatorhub/cluster` [INFER]. |
| OperatorLifecycleManager (v0) | Yes (only if marketplace is off too) | Keep: most mirrored operators, incl. lightspeed-operator in our lab, install through OLM v0. |
| OperatorLifecycleManagerV1 | Yes | Keep if you use ClusterExtensions (cert-manager in our post-install). Its default ClusterCatalogs need the N-1 day-0 manifests. |
| CSISnapshot, Storage, NodeTuning | Yes | Keep on clouds. The Storage API doc warns against disabling it on OpenStack/RHEV (`:343-349`). |
| MachineAPI | Yes, but **not for IPI** | Required for IPI on any platform. Agent/UPI only. |
| baremetal | Yes, except on platform baremetal | Harmless on AWS. |
| CloudCredential | Only on baremetal / none | Required on AWS (also with Manual/STS). |
| CloudControllerManager | Only on baremetal / none / external(ccm none) | Required on AWS. |
| Ingress | **No** | Always required. |
| CompatibilityRequirements, ClusterAPI | Cannot be **enabled** on the Default feature set | Must be left out of an explicit list (I-10). With `vCurrent` they are not a problem. |

### Recommended minimal set for an air-gapped 5.0 install

On AWS IPI (what `scripts/generate-install-config.sh` renders with DISABLE_INSIGHTS and DISABLE_SAMPLES), `baselineCapabilitySet: None` plus:

```yaml
capabilities:
  baselineCapabilitySet: None
  additionalEnabledCapabilities:
  - baremetal            # optional on AWS; harmless
  - Console
  - marketplace          # optional; needs OperatorLifecycleManager
  - Storage
  - CSISnapshot
  - NodeTuning
  - MachineAPI           # required for IPI
  - Build                # optional
  - DeploymentConfig     # optional
  - ImageRegistry        # optional
  - OperatorLifecycleManager
  - OperatorLifecycleManagerV1
  - CloudCredential      # required on AWS
  - Ingress              # always required
  - CloudControllerManager  # required on AWS
  # not Insights, not openshift-samples
  # never CompatibilityRequirements / ClusterAPI on a Default feature set
```

The truly minimal AWS IPI set is `MachineAPI, CloudCredential, CloudControllerManager, Ingress` plus whatever operators the customer needs (`OperatorLifecycleManager` for mirrored operators) [CODE: installer rules above; untested in the lab]. Keep Storage and CSISnapshot on clouds. On bare metal/Agent, CloudCredential and CloudControllerManager can also go, and `baremetal` is required on platform baremetal.

Reminder: a capability can be enabled later (`oc patch clusterversion ... additionalEnabledCapabilities`) but never disabled after install. Upgrades may implicitly enable capabilities that newly own resources [INFER from CVO behaviour; not verified for 4.22 -> 5.0].

### I6 open points
- File a docs bug for `enabling-baseline-capability-set.adoc` (`v{product-version}` -> `v5.0` does not exist).
- Correct the "16 values" in AGENTS.md I-10 to 17 (owner of that row).
- Optional lab check: install with no `capabilities` block (vCurrent) and read `clusterversion.status.capabilities.enabledCapabilities` to see whether the CVO lists CompatibilityRequirements/ClusterAPI on a Default cluster.
