# Code review round 2 (2026-11-08): TLS groups, IBI offline, add-nodes stream, agent FIPS check, fapolicyd crun

Read-only review. Refs checked:

- installer `origin/release-5.0` @ 8647f26b29 (2026-10-29), `origin/release-5.1` @ 4da4f1f39d (2026-11-06). For every file cited below, `git diff --stat release-5.0 release-5.1` is empty unless stated otherwise.
- vendored openshift/api in installer release-5.0: `v0.0.0-20260829233811-31af9f93e31e`
- openshift/library-go `origin/release-5.0` @ 3a828ca2, `origin/release-5.1` @ 0d5336f7 (cloned read-only to `/home/danclark/workspace/upstream/library-go`)
- machine-config-operator `origin/release-5.0` @ 0e5e436ae
- openshift-docs `enterprise-5.0` @ b5698adc31 (2026-11-05)
- Jira and the Red Hat portal (OKP), searched 2026-11-08

Nothing here was lab-tested. Every recipe or consequence is marked untested.

## Summary

| # | Item | Finding | Confidence | Proposed action |
|---|---|---|---|---|
| 1 | `tlsSecurityProfile.custom.groups` (DOC-15 / OSDOCS-24203) | The field exists in the 5.0 API but is gated by the **`TLSGroupPreferences`** feature gate, which is enabled only in **TechPreviewNoUpgrade / DevPreviewNoUpgrade**. On a Default cluster the CRD has no `groups` property, so you get "unknown field". This is by design, not an API bug. The docs module presents the field as generally available and lists only 4 of the 7 enum values. The 5.0 docs list `TLSGroupPreferences` among the TechPreviewNoUpgrade gates, which contradicts that module. Two more points: the library-go TLS observer on release-5.0 forwards no groups (support starts in release-5.1), and no named profile includes `SecP256r1MLKEM768`. NE-2935 (To Do) proposes adding it. OCPBUGS-138158, which asked for this, was closed Won't Do ("release notes and future planned work"). | High [CODE][DOC][JIRA] | **Docs, not OCPBUGS.** Add a comment to OSDOCS-24203: state the TP gate; list all 7 values; give a FIPS note. No `jira/draft-api-tls-custom-groups.md` written. |
| 2 | I3 IBI offline | Confirmed. `image-based create image` always takes the ISO URL from the embedded **rhel-10** stream (there is no osImageStream option and no payload extraction). The only exception is `OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE`, which is downloaded with `http.Get` (http/https only). The **cache lookup happens before any download and does no checksum check**, so pre-seeding `~/.cache/imagebased/image_cache/<basename of URL>` works. No version-mismatch warning exists for IBI. | High for the code path. The recipe is untested. | Add the recipe below to findings (marked untested). Lab-test it on the RHEL 10 host. Docs gap: `ibi-create-iso-for-bmh.adoc` does not say the command downloads from rhcos.mirror.openshift.com. |
| 3 | I4 add-nodes stream | In the AddNodes workflow no AgentClusterInstall is generated, so `GetOSImageStream()` returns the build default **rhel-10**. ClusterInfo reads nothing about the cluster's OSImageStream or pool streams. On a cluster or pool that runs rhel-9 (an upgraded 4.x cluster, or `osImageStream: rhel-9`), `oc adm node-image create` therefore builds an **RHCOS 10** ISO (`/coreos/coreos10-x86_64.iso` from the cluster's own payload, so it still works offline). The node should then pivot to the pool's RHCOS 9 osImage on first boot [INFER]. That is a 10 -> 9 major downgrade pivot and is untested. No fix on release-5.1. No matching Jira found. | High for the code path. The consequence is INFER. | Bug candidate (installer / Agent). Lab-test first: set the worker pool to rhel-9 on the lab cluster, run node-image create, inspect the ISO. Workaround idea (untested): none inside node-joiner. |
| 4 | F4 agent wait-for FIPS check | Present in **release-5.0** (AGENT-1455, commit b85360371b, 2026-04-07). It is **not** in release-4.22 or release-4.21. After the operators are stable, `agent wait-for install-complete` checks `spec.fips` in the rendered MachineConfig of the `master` and `worker` pools when install-config has `fips: true`. It fails with `FIPS was enabled in install-config but rendered MachineConfig <name> for <pool> pool has FIPS=false` (or "pool not found" / "no rendered configuration yet"). It does not check nodes (`fips_enabled`) or custom pools. IPI/UPI `wait-for` explicitly sets `VerifyFIPS: false`. Not in the 5.0 docs. | High [CODE] | Add a customer note (text below). For IPI, verify by hand (commands below). |
| 5 | fapolicyd + crun docs gap | Confirmed. The RHEL 9 (13.6) and RHEL 10 (10.6) Security hardening "Running fapolicyd on a system with containers" sections give **runc** rules only, but podman on RHEL 9/10 uses crun. KCS 7072618 (crun) tells customers to comment out the whole `ld_so` pattern rule, which is much broader than needed. The engineering bug **RHEL-37912** (crun, `exe=/`, Planning, many government accounts linked) is open. RHELDOCS-21276 (closed in 10.2) added the runc text only. No RHELDOCS ticket covers crun. | High [DOC][JIRA] | Draft written: `jira/docs-draft-rhel-fapolicyd-crun.md` (RHELDOCS, link RHEL-37912 and RHELDOCS-21276). |

---

## 1. `tlsSecurityProfile.custom.groups`

### Evidence

- **[CODE] The field is feature-gated.** `vendor/github.com/openshift/api/config/v1/types_tlssecurityprofile.go` (installer release-5.0, same text on release-5.1):
  - L205-230: `TLSProfileSpec.Groups []TLSGroup` with `+openshift:enable:FeatureGate=TLSGroupPreferences`, `MinItems=1`, `MaxItems=7`, `listType=set`.
  - L167-191: enum `TLSGroup` = `X25519; secp256r1; secp384r1; secp521r1; X25519MLKEM768; SecP256r1MLKEM768; SecP384r1MLKEM1024`.
  - L300-345: the Old, Intermediate and Modern profiles all carry `X25519MLKEM768, X25519, secp256r1, secp384r1`. No named profile includes `SecP256r1MLKEM768` or `SecP384r1MLKEM1024`.
- **[CODE] The gate is TechPreview/DevPreview only.** `vendor/github.com/openshift/api/features/features.go` L1039-1045 (release-5.0; L1063-1069 on release-5.1): `FeatureGateTLSGroupPreferences ... enable(inDevPreviewNoUpgrade(), inTechPreviewNoUpgrade())`, Jira component "Networking / router", enhancement openshift/enhancements#1894.
- **[CODE] Gated CRDs.** `config/v1/zz_generated.featuregated-crd-manifests.yaml` L11 lists `TLSGroupPreferences` for `apiservers.config.openshift.io`. The same applies in `operator/v1` (L184, IngressController and similar) and `machineconfiguration/v1` (L92, KubeletConfig and similar). The Default-feature-set CRD therefore has no `groups` property. That matches the lab result (`oc patch --dry-run=server` -> unknown field, examples/telemetry-and-tls/RESULTS.md).
- **[CODE] The propagation path is incomplete even with TechPreview on 5.0.** library-go release-5.0 `pkg/operator/configobserver/apiserver/observe_tlssecurityprofile.go` L18-20 and L64-108 observes only `minTLSVersion` and `cipherSuites`. release-5.1 adds `ObserveTLSSecurityProfileWithGroupPaths` (L30-50). Operators that use the shared observer (kube-apiserver and others) do not pass groups to their operands on 5.0 [CODE for the library; INFER for which operators vendor which version]. OCPBUGS-138158 makes the same observation.
- **[CODE] Group mapping in library-go.** release-5.0 `pkg/crypto/crypto.go` L216-225 maps all 7 values, including `SecP256r1MLKEM768` -> `tls.SecP256r1MLKEM768`. `TLSGroupsToCurveIDs` (L382-396) silently drops unknown names. **library-go has no FIPS filtering.** `grep -i fips pkg/crypto` finds only a SHA-1 comment in keygen.go. Dropping X25519 and X25519MLKEM768 in FIPS mode is done by the Go runtime's FIPS mode (RHEL Go OpenSSL backend / strictfipsruntime) [INFER]. The router does it explicitly: per OCPBUGS-138158, cluster-ingress-operator release-5.0 `pkg/operator/controller/ingress/deployment.go` L1107-1153 filters X25519/X25519MLKEM768 in FIPS mode and falls back to classical groups (not re-checked here).
- **[DOC] The docs present the field as GA.** openshift-docs enterprise-5.0 `modules/tls-profiles-understanding.adoc` L69-106: a "TLS key exchange groups" table with only 4 groups (X25519MLKEM768, X25519, secp256r1, secp384r1), and a note: "To configure specific key exchange groups with a custom profile, you must specify them explicitly in `spec.tlsSecurityProfile.custom.groups`." It does not mention a Technology Preview or the gate. It omits secp521r1, SecP256r1MLKEM768 and SecP384r1MLKEM1024.
- **[DOC] The docs contradict themselves.** `modules/nodes-cluster-enabling-features-about.adoc` L122 lists `TLSGroupPreferences` among the TechPreviewNoUpgrade features.
- **[JIRA]**
  - OCPBUGS-138158 "OpenShift 5.0.0 FIPS-mode TLS falls back to classical groups; hybrid group configuration is unavailable or not propagated" (kube-apiserver + router). It already cites the TP gate, the missing observer support and the router filtering. Status: **Closed / Won't Do**, 2026-11-06: "Addressing via release notes and future planned work."
  - NE-2935 "[PQC] Add Go 1.26 FIPS-approved ML-KEM hybrids to named TLS security profiles" (To Do): add `SecP256r1MLKEM768` and `SecP384r1MLKEM1024` to Old, Intermediate and Modern. Cluster-ingress-operator consumption is tracked in OCPBUGS-86050.
  - Per-component adoption epics are in flight: MCO-2642/2643, OCPNODE-4842, OTA-2143/2144/2146, ACM-48655..50065, ROX-37736 and others. OSDOCS-24203 (ours) is open.

### Conclusion

This is **not an API bug**: the field is intentionally TechPreview in 5.0. It is a **docs defect**: the module documents a gated field as if it were generally available and lists an incomplete enum. A separate OCPBUGS would duplicate OCPBUGS-138158, which was closed Won't Do. The existing OSDOCS-24203 is the right place for this, so add a comment there:

> `spec.tlsSecurityProfile.custom.groups` is gated by the `TLSGroupPreferences` feature gate (openshift/api `features.go`: `enable(inDevPreviewNoUpgrade(), inTechPreviewNoUpgrade())`). On a Default feature-set 5.0.0 cluster the APIServer and IngressController CRDs have no `groups` property, and the API server rejects it as an unknown field. The 5.0 docs already list `TLSGroupPreferences` under TechPreviewNoUpgrade (`nodes-cluster-enabling-features-about.adoc`), but `tls-profiles-understanding.adoc` presents the field without a Technology Preview label. Please (1) label `custom.groups` as Technology Preview, available only with TechPreviewNoUpgrade; (2) list all 7 accepted values (add secp521r1, SecP256r1MLKEM768, SecP384r1MLKEM1024); (3) state that in FIPS mode only the NIST curves (and, where the runtime supports them, the NIST ML-KEM hybrids) are used. Related: OCPBUGS-138158 (closed Won't Do), NE-2935.

Customer impact for air-gapped FIPS customers: on 5.0 there is no supported way to choose groups. The named profiles give P-256/P-384 only in FIPS mode. Production clusters should not enable TechPreviewNoUpgrade for this, because it cannot be undone and blocks updates.

No `jira/draft-api-tls-custom-groups.md` was written, because this is not a bug.

---

## 2. I3: image-based install (IBI) offline

### Evidence [CODE] (installer release-5.0, identical on release-5.1)

- `pkg/asset/imagebased/image/baseiso.go`
  - L45-47: when `OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE` is set and non-empty, the installer warns "Found override for OS Image. Please be warned, this is not advised." and calls `cache.DownloadImageFile(urlOverride, "imagebased")`, which passes no checksum.
  - L83-97 otherwise: `GetMetalArtifact(ctx, arch, rhcos.BuildDefaultOSImageStream())` -> embedded `coreos-rhel-10.json` -> `DownloadImageFileWithSha(url, "imagebased", sha)`.
  - There is no `osImageStream` field in `pkg/types/imagebased/imagebased_config_types.go`, and no payload or `oc` extraction anywhere in `pkg/asset/imagebased/image/`. The only network access in that package is this ISO download. `registriesconf.go` only renders the mirror config.
- `pkg/rhcos/stream.go` L23-29: `BuildDefaultOSImageStream()` returns `rhel-10` for installer major >= 5. `pkg/rhcos/builds.go` L43: the stream metadata is embedded, so building it needs no network.
- Embedded rhel-10 ISO (release-5.0 `data/data/coreos/coreos-rhel-10.json`): `https://rhcos.mirror.openshift.com/art/storage/prod/streams/rhel-10.2/builds/10.2.20261026-0/x86_64/rhcos-10.2.20261026-0-live-iso.x86_64.iso`, sha256 `f8e7a949dca553a623ce173ed191a011e5b0c243a03cdb89c249ab25f5039fad`. The rhel-9 stream would be `rhcos-9.8.20261026-0-live-iso.x86_64.iso`, but IBI never uses it.
- `pkg/rhcos/cache/cache.go`
  - L57-82: the cache directory is `os.UserCacheDir()/imagebased/image_cache`, i.e. `$XDG_CACHE_HOME/imagebased/image_cache` or `~/.cache/imagebased/image_cache`.
  - L213-216: the cache file name is the basename of the URL path, minus any `.gz`/`.xz` suffix.
  - **L220-235: `GetFileFromCache` runs first. If the file exists, it is returned immediately, with no checksum or size check.**
  - L238-255: otherwise `http.Get(url)` with 3 retries. Only http/https works; `file://` fails with "unsupported protocol scheme". The default transport honours `HTTP(S)_PROXY`/`NO_PROXY`.
  - L170-200: the sha256 check runs only on download. It uses the embedded sha (default path), or a `?sha256=<hex>` query on the override URL (L283-289). Without the query the override is never verified.
- No version check: `grep -i mismatch pkg/asset/imagebased` finds nothing. Unlike the agent path (`checkReleasePayloadBaseISOVersion`, which warns "base ISO version mismatch"), IBI uses whatever ISO it gets without comment.

### Offline recipe (UNTESTED)

Prerequisites: the mirror holds the 5.0.0 payload, including `machine-os-images` (proven in examples/agent-iso-offline/). You also need `oc`, an authfile for the mirror, the mirror CA trusted, an `openshift-install` that matches the seed version (extracted from the mirror per scripts/38-extract-installer.sh), and `nmstatectl` if networkConfig is used.

```bash
# 1. Find machine-os-images in the mirrored release (mirror-pinned digest)
REL=<mirror>/ocp5/openshift/release-images@sha256:<5.0.0 digest>
MOI=$(oc adm release info --idms-file=idms-oc-mirror.yaml -a pull-secret.json "$REL" --image-for=machine-os-images)

# 2. Extract the RHCOS 10 live ISO (rhel-10; /coreos/coreos-x86_64.iso is RHCOS 9)
mkdir -p ~/ibi-iso && cd ~/ibi-iso
oc image extract --idms-file=idms-oc-mirror.yaml -a pull-secret.json \
  --path /coreos/coreos10-x86_64.iso:. --filter-by-os=linux/amd64 --confirm "$MOI"
VOL=$(isoinfo -d -i coreos10-x86_64.iso | awk -F': ' '/Volume id/{print $2}')   # e.g. rhcos-10.2.20260922-0
mv coreos10-x86_64.iso "${VOL}-live.x86_64.iso"     # versioned name, so a stale cache file is never reused
SHA=$(sha256sum "${VOL}-live.x86_64.iso" | cut -d' ' -f1)

# 3a. Serve it locally (either option)
python3 -m http.server 8080 --bind 127.0.0.1 &      # or:
# podman run -d --rm -p 127.0.0.1:8080:8080 -v "$PWD:/var/www/html:ro,Z" registry.access.redhat.com/ubi9/httpd-24

# 3b. Point the installer at it, with an integrity check
export OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE="http://127.0.0.1:8080/${VOL}-live.x86_64.iso?sha256=${SHA}"
export NO_PROXY=127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}   # if HTTP(S)_PROXY is set on the host

# 4. Build
openshift-install image-based create image-config-template --dir ibi-iso-workdir
#    edit image-based-installation-config.yaml: seedImage/seedVersion (mirror), imageDigestSources,
#    additionalTrustBundle (mirror CA), pullSecret (mirror only), sshKey, installationDisk, networkConfig
openshift-install image-based create image --dir ibi-iso-workdir --log-level debug
#    expect: WARNING Found override for OS Image. Please be warned, this is not advised.
#            DEBUG Obtaining RHCOS image file from 'http://127.0.0.1:8080/...'
#            DEBUG Checksum validation is complete...
#    output: ibi-iso-workdir/rhcos-ibi.iso
```

Alternative without HTTP: pre-seed the cache. Copy the extracted ISO to `~/.cache/imagebased/image_cache/rhcos-10.2.20261026-0-live-iso.x86_64.iso`, i.e. the basename of the **embedded** URL above, which changes with every installer build: check it with `openshift-install coreos print-stream-json --stream rhel-10`, `.architectures.x86_64.artifacts.metal.formats.iso.disk.location`. Then run without the override. The file is used without a checksum check (cache.go L228-235). The trade-off is that nothing verifies it, and if the name does not match, the installer silently goes back to downloading from rhcos.mirror.openshift.com.

Expected differences or warnings:

- The payload's `machine-os-images` ISO (rhcos-10.2.20260922-0 in our 5.0.0 mirror) is older than the installer's embedded stream (10.2.20261026-0). IBI prints **no** warning about this, unlike the agent path.
- [INFER] The live ISO is only the carrier that runs the IBI installer. The node's final OS comes from the seed image, so the ISO's z-version should not matter. A rhel-9 seed with an RHCOS 10 live ISO is a combination nobody has tested.
- The "this is not advised" warning appears with the override but not with the cache pre-seed.
- If `ibi-iso-workdir` contains a generated ISO from a previous run, delete it first. The BaseIso asset does not load from disk (baseiso.go L78-80); a stale cache file with the same name is the real risk.

Docs gap [DOC]: `modules/ibi-create-iso-for-bmh.adoc` (L19, L132) does not mention that `image-based create image` downloads the RHCOS ISO from the internet, or how to avoid that in a disconnected environment. Candidate OSDOCS item.

---

## 3. I4: add-nodes (`oc adm node-image create`) on a rhel-9 cluster

### Evidence [CODE] (installer release-5.0. The release-5.1 diff touches `agentclusterinstall.go`, but only for internalJoinSubnet/OCPBUGS-127102; the stream logic is unchanged)

- `pkg/asset/agent/manifests/agentclusterinstall.go` L167-169: "This manifest is not required for AddNodes workflow". In AddNodes the ACI asset is an empty file, so there is no `installConfigOverrides` annotation. L418-421: the stream override comes from install-config, which exists only in the install workflow.
- `pkg/asset/agent/manifests/agent.go` L127-151: `GetOSImageStream()` returns `rhcos.BuildDefaultOSImageStream()` (rhel-10 on 5.x) when the ACI or its annotation is missing.
- `pkg/asset/agent/image/baseiso.go` L65-76: `osImageStream := agentManifests.GetOSImageStream()` -> `NewBaseISOFetcher(release, osImageStream)`. The release comes from `ClusterImageSet`, which in AddNodes is the cluster's own release image (`manifests/clusterimageset.go` L74-75). The ISO is therefore extracted from the cluster's payload, which works offline: `/coreos/coreos10-x86_64.iso` for rhel-10 (`pkg/asset/rhcos/releaseextract.go` L39-58).
- `ignition.go` L277-278 and `unconfigured_ignition.go` L160 use the same default stream for the OS image info.
- `pkg/asset/agent/joiner/clusterinfo.go` (L95-660): ClusterInfo retrieves the proxy, pull secret, trust bundle, architecture, FIPS, SSH key, chrony, IDMS/ICSP, ignition endpoint, platform, API DNS and the original install-config (`retrieveInstallConfig`, L384). **None of it is used for the stream.** It reads neither the cluster OSImageStream nor the worker pool's stream nor the original install-config's `osImageStream`. `cmd/node-joiner` and `pkg/nodejoiner` have no stream flag.
- `git log origin/release-5.1 --grep=stream -- pkg/asset/agent/`: no add-nodes stream fix. Commit 89cad2311b ("refactored node-joiner to use embedded RHCOS metadata directly") predates the stream split.

### Behaviour

| Cluster | ISO built by `oc adm node-image create` (5.0 node-joiner) | Expected node OS after join |
|---|---|---|
| Fresh 5.0, default rhel-10 | RHCOS 10 (`coreos10-x86_64.iso`) | RHCOS 10. Fine. |
| Fresh 5.0 with `osImageStream: rhel-9` | **RHCOS 10** | [INFER] The MCD first-boot pivot to the pool's rendered osImageURL (RHCOS 9.8) is a 10 -> 9 downgrade. Untested. |
| Upgraded 4.22 -> 5.0 (stays rhel-9 until switched, J10) | **RHCOS 10** | Same as above. This is the most common case. |
| Pool pinned to rhel-9 (e.g. runc, F8) | **RHCOS 10** | Same. The pool cannot render rhel-10 at all (F8). |

Supporting [JIRA] context: OCPBUGS-127477 (POST, docs) found that on bare-metal IPI the joined node ends up on the cluster's default stream regardless of the requested per-host stream. That fits "the pool's osImageURL wins after the pivot". RFE-9938 asks for stream selection for day-2 nodes. Search for an add-nodes / node-joiner stream bug in AGENT, OCPBUGS, MCO and OCPSTRAT: none found (2026-11-08).

Risk [INFER]: whether an RHCOS 10 live/first boot can rebase to RHCOS 9.8 (bootc/rpm-ostree major downgrade, composefs, ignition spec, SELinux policy) is not known. If it fails, a rhel-9 cluster cannot add nodes with the agent day-2 flow. The release notes say mixed RHCOS 9/10 clusters are unsupported (DOC-13), so the node must not stay on RHCOS 10.

### Proposed action

1. Lab test, since it is cheap on the lab cluster: on a disposable cluster with the worker pool at rhel-9 (or an `osImageStream: rhel-9` install), run `oc adm node-image create` and check the ISO volume ID (expect rhcos-10.x). If hardware or VMs are available, boot it and watch the first-boot pivot.
2. File a bug in OCPBUGS (component Installer / Agent based installation) after the test: "node-joiner always uses the build default stream (rhel-10); it should use the target pool's / cluster's OSImageStream". Suggested fix: read `osimagestreams`/MCP `spec.osImageStream` (or the cluster default) in ClusterInfo and set the stream for the base ISO and OS image info.
3. Customer note until then: on clusters still on rhel-9, add nodes with a boot method that follows the pool stream (IPI MachineSets with MCO boot-image management), or switch the cluster to rhel-10 first.

---

## 4. F4: agent `wait-for install-complete` FIPS verification

### Evidence [CODE]

- Introduced by commit **b85360371b "AGENT-1455: Verify FIPS mode after installation completes"** (2026-04-07). It is on release-5.0 (= 4.23) and release-5.1. It is **not** on release-4.22 or release-4.21 (`git merge-base --is-ancestor` and `--grep=AGENT-1455` both negative).
- `cmd/openshift-install/agent/waitfor.go` L125-136 (release-5.0 = 5.1): it loads `OptionalInstallConfig` from the asset store in `--dir`. When `ic.Config.FIPS` is true it sets `WaitOptions{VerifyFIPS: true}`. If the install-config cannot be loaded from the asset store (for example `wait-for` run from another directory, or a ZTP-style `cluster-manifests` flow without install-config), the check is **silently skipped**.
- `cmd/openshift-install/command/waitfor.go`
  - L118-135 order: wait for ClusterVersion initialised -> add router CA -> wait for stable operators -> **then** `verifyFIPSEnabled` -> console URL -> "Install complete".
  - L75-114 `verifyFIPSEnabled`: for pools `worker` and `master` it gets the MachineConfigPool, takes `status.configuration.name`, gets that rendered MachineConfig and checks `spec.fips`. Errors:
    - `FIPS was enabled in install-config but <pool> MachineConfigPool not found`
    - `FIPS was enabled in install-config but <pool> MachineConfigPool has no rendered configuration yet`
    - `FIPS was enabled in install-config but rendered MachineConfig <name> for <pool> pool has FIPS=false`
    - On success: `INFO Verified FIPS mode is enabled on cluster` (DEBUG per pool).
  - A failure goes to `logrus.Exit(ExitCodeInstallFailed)` after logging the ClusterOperator conditions (agent/waitfor.go L138-146).
- Scope limits: only the rendered MachineConfigs, i.e. desired config. It does not check `/proc/sys/crypto/fips_enabled` on nodes, the kernel cmdline, crypto policy or custom pools.
- `cmd/openshift-install/waitfor.go` L22-25: IPI/UPI `getWaitOptionsFromInstallConfig` sets `VerifyFIPS: false // IPI/UPI installer doesn't verify FIPS`. `create cluster` uses the same path. The only FIPS check on IPI/UPI is the install-host check (`pkg/hostcrypt`, F2).
- [DOC] Not mentioned in the 5.0 docs (`grep "Verified FIPS"` / the error strings in openshift-docs enterprise-5.0: no hits; `agent-installer-fips-compliance.adoc` and `agent-installer-configuring-fips-compliance.adoc` do not mention it).

### Customer text (proposed)

> **Agent-based installs (OpenShift 5.0 and later):** when `fips: true` is set in `install-config.yaml`, `openshift-install agent wait-for install-complete` checks, after all cluster operators are stable, that the rendered MachineConfigs of the `master` and `worker` pools have FIPS enabled. If not, the command fails with `FIPS was enabled in install-config but rendered MachineConfig <name> for <pool> pool has FIPS=false` and returns an installation-failed exit code. Run the command from the same directory you used for `agent create image`, otherwise the check is skipped. The check does not inspect nodes or custom pools.
>
> **IPI and UPI installs** do not perform this check. Verify FIPS mode yourself after installation:
>
> ```
> for p in master worker; do
>   oc get mc "$(oc get mcp $p -o jsonpath='{.status.configuration.name}')" -o jsonpath='{.spec.fips}{"\n"}'
> done
> for n in $(oc get nodes -o name); do
>   oc debug "$n" -q -- chroot /host cat /proc/sys/crypto/fips_enabled
> done                                   # expect 1 on every node
> ```

(This matches what our IPI installs I-13, I-14 and install 4/5 verified by hand [LAB].)

---

## 5. fapolicyd: crun docs gap

### Current Red Hat doc text [DOC] (retrieved 2026-11-08 via OKP)

- **RHEL 10** Security hardening, 10.6 "Troubleshooting problems related to fapolicyd", "Running fapolicyd on a system with containers", https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/security_hardening/index#troubleshooting-problems-related-to-fapolicyd :
  > "Because the fapolicyd framework does not fully support namespaces and containers, you must use a workaround on systems running containers. To prevent startup failures of containers because of fapolicyd, create the /etc/fapolicyd/rules.d/25-runc.rules file with the following content: `allow perm=any pattern=ld_so exe=/usr/bin/runc : all` `allow perm=any uid=0 pattern=ld_so exe=/runc : trust=1` Save the file, run the fagenrules script, and enter the fapolicyd-cli --reload-rules command to apply the changes."
- **RHEL 9** Security hardening, 13.6, same section, https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/security_hardening/index#ref_troubleshooting-problems-related-to-fapolicyd_assembly_blocking-and-allowing-applications-using-fapolicyd : the same two runc rules, plus: "Alternatively, you can remove the tmpfs value from the watch_fs option in the /etc/fapolicyd/fapolicyd.conf file and restart the fapolicyd service ..., but this lowers the system security." (The RHEL 10 text does not have this alternative.)
- **KCS 7072618** (crun, RHEL 9, "Solution Verified - Updated 8 Aug 2024"), https://access.redhat.com/solutions/7072618 : the workaround is to **comment out** `deny_audit perm=any pattern=ld_so : all` (and ld_preload, static) in `30-patterns.rules`. That disables the ld_so protection for every process. Root cause cited: RHEL-37912. KCS 7076507 is the runc / RHEL 8 equivalent.

Neither product doc mentions crun, although podman's default runtime on RHEL 9 and 10 is crun and runc is not installed by default [LAB: examples/fapolicyd/RESULTS.md, crun 1.27 / 1.30.1].

### Lab facts (from examples/fapolicyd/RESULTS.md)

- The denial is `rule=5 dec=deny_audit perm=open ... exe=/ : path=/usr/lib64/libsystemd.so.0.35.0` (and `/etc/ld.so.cache`). crun re-executes from a sealed memfd, so fapolicyd sees `exe=/`.
- The documented `exe=/usr/bin/runc` form, adapted to `exe=/usr/bin/crun`, does **not** match (fix D failed). A `trust=1` object form also fails (C), because `ld.so.cache` and `oci-log` are untrusted.
- The working narrow rule (B): `allow perm=open uid=0 pattern=ld_so exe=/ : all` in a `rules.d` file that sorts before `30-patterns.rules`. Tested on RHEL 9.8 FIPS and RHEL 10.2 with fapolicyd 1.4.5, enforcing, STIG deny-all, integrity sha256, across a reboot.
- Rootless podman was not affected.

### Jira [JIRA] (searched 2026-11-08)

| Key | Status | Relevance |
|---|---|---|
| **RHEL-37912** "fapolicyd default rule file 30-patterns.rules prevents starting containers" | **Planning** (open) | The engineering bug for **crun**: the same `rule=5 ... exe=/` denial on a Quay host. Linked accounts include DHS, US Navy/USMC, NAVAIR, USSS, IBM, Kyndryl and Staat der Nederlanden. Comments: Satellite ships its own rule; 2026-08/09 discussion of `allow_filesystem_mark = 1` as a possible workaround (disputed, not confirmed). |
| RHEL-114562 "fapolicyd causes container startup failure" | New | The **runc** variant. The source of the documented runc rules (Renaud Metrich comment). |
| RHELDOCS-21276 "Update product documentation to run fapolicyd on system with containers" | Closed, fixVersion rhel-10.2 | Added the runc rules and the release-note known issues (8.10, 9.6, 9.7, 10.1). **runc only.** |
| RHEL-1507 | Closed Duplicate of RHEL-37912 | Earlier crun/runc report (RHEL 8.7 STIG). |
| SAT-38707 | Closed | Satellite IoP containers hit by crun + fapolicyd. Satellite ships `15-foreman-container.rules`: `allow perm=any pattern=ld_so exe=/usr/bin/crun : path=/usr/lib64/libsystemd.so.0`. That rule uses `exe=/usr/bin/crun`, which did **not** match in our lab (subject `exe=/`). Possibly crun-version dependent [INFER]; worth flagging. |
| RHELDOCS-22952 "Please document fapolicyd configuration recommendations for image mode" | New | Separate gap: overlay is not in `watch_fs`, so on image mode most of `/usr` is unchecked. Relevant to our bootc RHEL 10 hosts (B-3/B-5). Not a duplicate. |
| RHELDOCS-22589 | New | Audit-rule syntax in "Deploying fapolicyd". Not a duplicate. |
| RHEL-212482 / RHEL-212483 (fapolicyd 2.0 in RHEL 10.3 / 9.9) | Release Pending | The rebase may change behaviour. Re-test the crun rule on 9.9 / 10.3. |

No RHELDOCS ticket for crun was found. Draft: `jira/docs-draft-rhel-fapolicyd-crun.md`.

### Impact for this project

Customers running fapolicyd (STIG) on the mirror-registry host hit this on the first `mirror-registry install`. Our template proposal (examples/fapolicyd/template-change.md) carries the narrow crun rule. Customer guidance should cite RHEL-37912 and say that the narrow rule is lab-validated but not a Red Hat-documented configuration.
