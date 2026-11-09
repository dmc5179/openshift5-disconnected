# Mirroring for a disconnected OpenShift 4.x to 5.0 upgrade with oc-mirror v2

Status: DRAFT, 2026-11-08. Tracker item M8. Built from lab runs in this repository (AWS us-east-2, simulated
air gap) and the published OpenShift 5.0 documentation. Each section says whether it was lab-validated.

**Labels used in this document**
- **Lab-validated**: we ran it and saw the stated result.
- **Documented only**: Red Hat documentation says so, but we did not run it.
- **Untested**: our recommendation or inference. Check it before you rely on it.

## 1. Summary

| If your cluster runs | Mirror like this | Status |
|---|---|---|
| **4.22.z** that has an edge to 5.0 in the channel you use | **One** ImageSetConfiguration, **one** 5.x platform channel, `minVersion: <your 4.22.z>`, `maxVersion: 5.0.z` | Lab-validated (mirror and update service; the cluster upgrade itself was not run) |
| **4.21 or older** | **Two** oc-mirror runs: (1) the 4.x hops up to a 4.22.z that has an edge to 5.0, using 4.x channels only; (2) the 4.22.z → 5.0 hop, using one 5.x channel | Untested as a pair. Each half is covered by a lab run (see section 4) |

**Never put a 4.x channel and a 5.x channel in the same ImageSetConfiguration.** oc-mirror v2 fails on it
(see section 2). This applies until the oc-mirror bug is fixed.

Other things you need:
- The mirror mapping for `quay.io/openshift-release-dev/ocp-v4.0-art-dev` (the 4.22 payload) **and**
  `quay.io/openshift-release-dev/ocp-v5.0-art-dev` (the 5.0 payload). oc-mirror writes both into its
  ImageDigestMirrorSet when the mirror holds both releases. Lab-validated.
- The release signatures. oc-mirror v2 copies them and writes signature ConfigMaps. Lab-validated.
- A local OpenShift Update Service (OSUS) so the cluster can see the 4.22 → 5.0 edge. Lab-validated.
- On FIPS hosts, the oc-mirror binary from the container image, not the CDN tarball. Lab-validated.

## 2. Why one ImageSetConfiguration cannot span 4.x and 5.x

When an ImageSetConfiguration lists several platform channels, oc-mirror v2 works out the hops between them by
building the next channel name itself: it adds one to the minor version (`4.22` → `4.23` → `4.24` ...). It never
moves to the next major version, so it never reaches `5.0`.

What we saw (Lab-validated, oc-mirror 4.22.0 build, 2026-11-02 and 2026-11-04):

| Channels listed | Result |
|---|---|
| `candidate-4.22` + `candidate-5.0` | Fails. oc-mirror walks `candidate-4.23`, then `candidate-4.24`, and never queries `candidate-5.0` |
| `stable-4.22` + `stable-5.0` | Fails: `NoVersionsFound: no cluster versions found for "amd64" in the "stable-4.23" channel` |
| `candidate-5.0` only, `minVersion: 4.22.20`, `maxVersion: 5.0.0` | Works: 4.22.20 → 5.0.0 |
| `candidate-4.21` + `candidate-4.22` (control) | Works: 4.21.0 → 4.21.41 → 4.22.21 |

The single-channel case works because a 5.x channel already contains the 4.22.z releases that can update to 5.0,
plus the edges between them. oc-mirror then computes the path inside that one channel, with no channel walk.

The code path (`calculate()` in `internal/pkg/release/core-cincinnati.go`) is the same in the 4.22 and 5.x
oc-mirror branches. We have not yet re-run case A/B with the async oc-mirror 2.0.0 build, but the 2.0.0 single-channel
run in section 3 shows the workaround works with it.

## 3. Starting from 4.22.z: one run, one 5.x channel

### 3.1 Pick the channel

Check which 5.x channel has an edge from your exact 4.22.z **on the day you mirror**. Channel content changes after
GA. What we saw:

| Date | Channel | Content |
|---|---|---|
| 2026-11-02 | `candidate-5.0` | 4.22.x, 5.0.0-rc.*, 5.0.0; edge 4.22.21 → 5.0.0 |
| 2026-11-04 | `fast-5.0` | 23 nodes, including **4.22.18, 4.22.19, 4.22.20, 4.22.21 → 5.0.0** |
| 2026-11-04 | `stable-5.0` | **5.0.0 only, no 4.22 edges yet** |

The 5.0 documentation says updates from 4.x go through `stable-5.0` and `candidate-5.0`. At the time we checked,
only `fast-5.0` and `candidate-5.0` had the 4.22 edges. Use `stable-5.0` once it carries them.

Check from any connected machine (no credentials needed):

```bash
CH=fast-5.0          # or stable-5.0
FROM=4.22.18         # your cluster's current version
curl -s -H 'Accept: application/json' \
  "https://api.openshift.com/api/upgrades_info/v1/graph?channel=${CH}&arch=amd64" > graph.json
# versions in the channel
jq -r '.nodes[].version' graph.json | sort -V
# where can FROM go in this channel?
jq -r --arg v "$FROM" '.nodes as $n | .edges[] | select($n[.[0]].version==$v) | $n[.[1]].version' graph.json
```

If the second command prints no 5.0.z, either update the cluster to a 4.22.z that has the edge (with a 4.x-only
mirror run), or wait for the channel to gain it.

### 3.2 ImageSetConfiguration

Lab-validated shape (2026-11-04, oc-mirror 2.0.0, mirror-to-mirror into mirror-registry, 34 min including
operators):

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    graph: true                       # builds the graph-data image for the local update service
    channels:
    - name: fast-5.0                  # ONE channel only; stable-5.0 when it carries your 4.22.z
      type: ocp
      minVersion: 4.22.18             # your cluster's current 4.22.z
      maxVersion: 5.0.0               # the 5.0.z you want to reach
      shortestPath: true
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v5.0
    packages:
    - name: cincinnati-operator       # OpenShift Update Service
    # - name: <the operators your cluster runs, from the v5.0 catalog>
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
```

Notes:
- `scripts/generate-imageset-config.sh` renders this from `cluster.env` (`OCP_CHANNEL`, `OCP_UPGRADE_FROM`,
  `OCP_VERSION`) and refuses an `OCP_UPGRADE_FROM` that is not 4.22.z.
- The operators your cluster runs must also exist in the **v5.0** catalog, at a version that supports 5.0, before
  you upgrade. Mirror them from `redhat-operator-index:v5.0`. Whether you also need the v4.22 catalog for the
  period before the upgrade depends on your operators; we did not test an operator upgrade across the catalog
  change. Untested.
- A package listed without `channels` brings in the head of **every** channel of that package, not only the default
  channel (seen with 3scale-operator). List the channel when you can. Lab-validated.

### 3.3 Run oc-mirror

Mirror-to-mirror (a host that can reach both Red Hat and the mirror registry). Lab-validated:

```bash
oc-mirror --v2 -c imageset-config.yaml \
  --workspace file://$HOME/oc-mirror/m2m \
  --authfile ./auth.json \
  docker://<mirror-host>:8443/<namespace>
```

Fully air-gapped (mirror-to-disk on the connected side, disk-to-mirror inside the enclave):

```bash
# connected side - Lab-validated for 5.0.0 platform only (199 images, 24.85 GB archive, 273 s)
oc-mirror --v2 -c imageset-config.yaml file://<archive-dir> --authfile ./auth.json

# carry <archive-dir> (the mirror_*.tar files and working-dir) and the same imageset-config.yaml across

# enclave side - Documented only for 5.0 (not run in this lab)
oc-mirror --v2 -c imageset-config.yaml --from file://<archive-dir> \
  docker://<mirror-host>:8443/<namespace> --authfile ./mirror-auth.json
```

Things we hit:
- **Mirror-to-disk writes no cluster resources.** `working-dir/cluster-resources/` stays empty. The IDMS, ITMS,
  signature ConfigMaps and UpdateService are written by the disk-to-mirror (or mirror-to-mirror) step, when the
  destination registry is known. Lab-validated.
- Two oc-mirror runs on one host at the same time collide on port 55000. Give each its own `--port`. Lab-validated.
- `--dry-run` is not free of side effects: with `graph: true` it builds the graph image, and with operators it
  extracts the catalogs. Lab-validated.
- The async oc-mirror reports version **2.0.0**, not 4.x/5.x. Scripts that parse the version break. Lab-validated.

### 3.4 What oc-mirror generates, and what to apply

For a mirror holding 4.22.18 and 5.0.0, `working-dir/cluster-resources/idms-oc-mirror.yaml` (`idms-release-0`) has
three release sources (Lab-validated):

```yaml
  - source: quay.io/openshift-release-dev/ocp-v4.0-art-dev   # the 4.22 payload
  - source: quay.io/openshift-release-dev/ocp-release
  - source: quay.io/openshift-release-dev/ocp-v5.0-art-dev   # the 5.0 payload
```

A mirror holding only 5.x releases produces only `ocp-v5.0-art-dev` and `ocp-release`. So the `ocp-v4.0-art-dev`
mapping is **not** needed to install 5.0, but it **is** needed while the mirror carries a 4.22 upgrade path.
(The 5.0 payload still refers to `ocp-v4.0-art-dev` in the default `ClusterImagePolicy` scope and for the KubeVirt
boot images, so keeping the mapping does no harm.)

On the 4.22 cluster, **before** the upgrade:

```bash
cd <workspace>/working-dir/cluster-resources
ls                                   # idms-oc-mirror.yaml, itms-oc-mirror.yaml, cs-*.yaml, cc-*.yaml,
                                     # signature-configmap.yaml, updateService.yaml
for f in idms-oc-mirror.yaml itms-oc-mirror.yaml signature-configmap.yaml; do oc apply -f "$f"; done
# wait for the MachineConfigPools to roll the new mirror config out to every node
oc get mcp
oc wait mcp --all --for=condition=Updated=True --timeout=30m
```

Why wait: IDMS/ITMS changes reach each node's `registries.conf` through a MachineConfig rollout (no reboot). Until a
node has it, pulls of newly mirrored images go to the source registry, which is blocked. On a 5.0 cluster we saw an
operator bundle pull go to registry.redhat.io one minute after the IDMS was applied; it succeeded through the
mirror 30 s later. Lab-validated on 5.0; the same mechanism applies on 4.22. Untested on 4.22.

Check that the 4.22 cluster now has the 5.0 mapping (without it, the 5.0 payload images are pulled from quay.io and
the upgrade stalls):

```bash
oc get imagedigestmirrorset -o yaml | grep -E 'source: quay.io/openshift-release-dev/(ocp-release|ocp-v4.0-art-dev|ocp-v5.0-art-dev)'
```

### 3.5 Signatures

- oc-mirror v2 copies the sigstore `.sig` tags along with every payload image (388 of 388 in our mirror) and writes
  release signature ConfigMaps. `--remove-signatures` turns this off; do not use it. Lab-validated.
- The default `ClusterImagePolicy/openshift` (owned by the cluster version operator) checks Red Hat signatures for
  `ocp-release`, `ocp-v4.0-art-dev` and `ocp-v5.0-art-dev`. The Machine Config Operator extends the signature
  lookup to the mirror repositories listed in the IDMS. We saw no signature failures on 5.0. Lab-validated.
- The mirror held signatures for **both** release digests (4.22.18 and 5.0.0). Lab-validated.
- Use oc-mirror v2. `oc adm release mirror` does not copy sigstore signatures. Documented only (OpenShift docs
  issue, not tested here).
- A known 4.22 → 5.0 signature identity problem between the two art-dev repositories was fixed by Red Hat before
  GA. We did not run an upgrade to confirm it on GA bits. Untested.

### 3.6 Local OpenShift Update Service

Lab-validated on 5.0.0 (OSUS operator 5.0.3 from the mirrored catalog). The same steps apply on 4.22 with the
operator from your 4.22 catalog. Untested on 4.22.

```bash
# 1. Install the cincinnati-operator (OLM v0) from the mirrored CatalogSource, namespace openshift-update-service
# 2. The OSUS reads the mirror CA from openshift-config/<image.config additionalTrustedCA ConfigMap>,
#    key "updateservice-registry". Add that key next to your registry key:
oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}{"\n"}'
#    (the ConfigMap must contain both "<host>..<port>" and "updateservice-registry" keys with the mirror CA)
# 3. Create the UpdateService that oc-mirror wrote
oc apply -n openshift-update-service -f working-dir/cluster-resources/updateService.yaml
URI=$(oc get updateservice -n openshift-update-service -o jsonpath='{.items[0].status.policyEngineURI}')
# 4. The policy engine route uses the ingress CA; trust it cluster-wide
oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > ingress-ca.crt
#    append ingress-ca.crt to openshift-config/user-ca-bundle (key ca-bundle.crt), then:
oc patch proxy cluster --type merge -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
# 5. Point the CVO at it, with the SAME channel you mirrored
oc patch clusterversion version --type merge \
  -p "{\"spec\":{\"upstream\":\"${URI}/api/upgrades_info/v1/graph\",\"channel\":\"fast-5.0\"}}"
oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="RetrievedUpdates")]}{"\n"}'
oc adm upgrade
```

What we saw: a local OSUS fed from the `fast-5.0` 4.22.18 → 5.0.0 mirror serves the edge 4.22.18 → 5.0.0 to a
query. `RetrievedUpdates=True`. Lab-validated (graph query; no 4.22 cluster consumed it).

### 3.7 Before you start the upgrade

| Check | Why | Status |
|---|---|---|
| runC → crun | RHCOS 10 has no runC. The upgrade itself is not blocked, but the later switch to RHCOS 10 is. See `docs/checklist-f7-rhcos10-fips-workloads.md` item 8 | Lab-validated (on 5.0) |
| Keep RHCOS 9 images in the mirror | Upgraded clusters stay on the `rhel-9` stream until you switch `osimagestream`. A standard oc-mirror run mirrors both RHCOS 9.8 and 10.2 node images | Lab-validated |
| Manual (STS) credentials | Our 5.0 STS cluster reported `Upgradeable=False` because the `cloudcredential.openshift.io/upgradeable-to` annotation was missing. For Manual mode, update the cloud credentials for the target release with `ccoctl` (extract the CredentialsRequests from the **mirrored 5.0 payload**), then set the annotation | Documented only (OpenShift 4.x procedure); not run for 4.22 → 5.0 |
| OpenShift Lightspeed already installed | Clusters that already run OpenShift Lightspeed get the new agentic console plug-in (AI Hub) after the upgrade and operator reconcile. If AI must stay off, remove the Lightspeed console plug-in or the operator first, and apply the admission policy in `examples/ai-opt-out-policy/` | Untested (from Red Hat engineering tracking, not documentation) |
| Operators | Each installed operator must have a 5.0-compatible version in the mirrored v5.0 catalog | Untested |

## 4. Starting below 4.22: two runs

oc-mirror handles several channels correctly **inside** one major version (control case D above). So:

**Run 1: 4.x only.** All hops up to a 4.22.z that has an edge to 5.0 in the 5.x channel you will use.

```yaml
# run-1-4x.yaml  - example for a 4.20 cluster. Adjust to your real versions and the channels' edges.
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    graph: true
    channels:
    - name: stable-4.21
      type: ocp
      minVersion: 4.20.<z>          # your cluster's current version (must be in this channel)
      maxVersion: 4.21.<z>
      shortestPath: true
    - name: stable-4.22
      type: ocp
      minVersion: 4.22.18           # must equal run 2's minVersion
      maxVersion: 4.22.18
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: cincinnati-operator
```

The two-channel 4.x shape matches the lab control (`examples/oc-mirror-cross-major-test/isc-D-control-same-major.yaml`,
`candidate-4.21` 4.21.0 + `candidate-4.22` 4.22.21: worked). With EUS-to-EUS paths, use the `eus-4.x` channels
the 4.x documentation lists for your path. Untested here.

**Run 2: 4.22.z → 5.0.** Exactly the single-channel configuration in section 3.2, with `minVersion` = run 1's final
4.22.z.

Practical points (all Untested as a pair):
- Use a **separate workspace** (`--workspace` or archive directory) per run, or keep each run's
  `working-dir/cluster-resources/` before the next run overwrites it.
- Both runs push the release images into the same `<namespace>/openshift/release-images` repository, so the local
  OSUS sees every release from both runs.
- Both runs name their release IDMS `idms-release-0`. Applying the second replaces the first. Run 2's IDMS already
  contains the `ocp-v4.0-art-dev` and `ocp-release` sources that run 1 needs (they map to the same mirror
  repositories), so apply run 2's IDMS last, or merge the `imageDigestMirrors` lists by hand and check with the
  `grep` in section 3.4.
- Upgrade the cluster to the 4.22.z from run 1 first. Only then point the CVO at the 5.x channel.
- You can also do this as two maintenance windows: run 1 and upgrade to 4.22.z, later run 2 and upgrade to 5.0.

## 5. Which oc-mirror to use

oc-mirror is no longer part of the 5.0 release payload. It ships separately, and `oc adm release extract` no longer
offers an `oc-mirror` command. Update any automation that extracted it from the payload.

| Build | Where | FIPS | Status |
|---|---|---|---|
| CDN tarball, version 2.0.0 | `https://mirror.openshift.com/pub/cgw/oc-mirror/latest/oc-mirror-rhel9-linux-amd64.tar.gz` | **Not FIPS-capable**: static Go binary (`CGO_ENABLED=0`), never loads the system OpenSSL FIPS provider | Lab-validated: runs and mirrors on FIPS and non-FIPS RHEL 9 and RHEL 10 hosts, but does not use validated crypto |
| Container image build, 5.0.0 | `registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0`, file `/usr/bin/oc-mirror.rhel9` | **FIPS-capable**: `CGO_ENABLED=1`, `strictfipsruntime`, loads `libcrypto.so.3` and `fips.so` | Lab-validated on RHEL 9.8 FIPS and RHEL 10.2 FIPS (full 5.0.0 mirror, 199 images, 8 min 32 s) |

On a FIPS host, extract the image build:

```bash
oc image extract registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0 -a ./pull-secret.json \
  --filter-by-os=linux/amd64 --path /usr/bin/oc-mirror.rhel9:. --confirm
chmod 755 oc-mirror.rhel9 && sudo mv oc-mirror.rhel9 /usr/local/bin/oc-mirror
# check: the binary must be dynamically linked and load the FIPS provider
oc-mirror version
LD_DEBUG=libs oc-mirror version 2>&1 | grep -E 'libcrypto.so.3|fips.so' | head -3
```

The CDN 2.0.0 build lists `supportedOCPVersions` 4.12 to 4.23 and 5.0, so one binary covers both runs in section 4.
Red Hat supports one oc-mirror version at a time; take the newest. If fapolicyd is enforcing on the host, re-run the
trust script after replacing the binary (`examples/fapolicyd/fapolicyd-trust-tools.sh`).

## 6. KubeVirt boot images (hosted control planes on OpenShift Virtualization only)

`mirror.platform.kubeVirtContainer: true` mirrors only the **RHCOS 9.8** KubeVirt boot image on 5.0. oc-mirror reads
the old single-stream key of the `coreos-bootimages` ConfigMap and ignores the per-stream list, so the RHCOS 10.2
image is never mirrored. Lab-validated. Workaround: add the RHCOS 10 KubeVirt image digest from the release's
`coreos-bootimages` manifest as an `additionalImages` entry (the digest changes per release). Untested as a
workaround.

## 7. What is and is not lab-validated

| Item | Status |
|---|---|
| oc-mirror fails on 4.x + 5.x channels together (candidate and stable) | Lab-validated |
| Single 5.x channel spanning 4.22.z → 5.0 (`candidate-5.0` dry run; `fast-5.0` full mirror-to-mirror with oc-mirror 2.0.0) | Lab-validated |
| Generated IDMS contains `ocp-v4.0-art-dev`, `ocp-v5.0-art-dev`, `ocp-release` | Lab-validated |
| Signatures for both release digests in the mirror | Lab-validated |
| Local OSUS serves the 4.22.18 → 5.0.0 edge | Lab-validated (graph only) |
| FIPS oc-mirror (image build) on RHEL 9 and RHEL 10 FIPS | Lab-validated |
| Mirror-to-disk for 5.0 | Lab-validated (platform only) |
| Disk-to-mirror for 5.0 | Documented only |
| Two-run approach for clusters below 4.22 | Untested (each half covered separately) |
| **An actual 4.22 → 5.0 cluster upgrade, disconnected** | **Untested** (no 4.22 cluster in the lab) |
| `stable-5.0` with 4.22 edges | Not yet possible on 2026-11-04 (channel had only 5.0.0) |
| Operator upgrades across the v4.22 → v5.0 catalogs | Untested |

## Sources in this repository

- `examples/oc-mirror-cross-major-test/` (case configs A-D, runbook)
- `examples/oc-mirror-5.0-m2d/RESULTS.md`, `examples/oc-mirror-5.0-m2m/README.md`
- `examples/install-results/RESULTS.md` (install 4: `fast-5.0` 4.22.18 → 5.0.0 mirror, OSUS)
- `examples/operator-fips-and-signatures/RESULTS.md`, `examples/clusterimagepolicy/README.md`
- `examples/rhel10-fips-host/RESULTS.md`, `RESULTS-round2.md` (FIPS oc-mirror)
- `scripts/generate-imageset-config.sh`, `scripts/bastion-mirror-to-mirror.sh`, `scripts/45-post-install.sh`
- Published docs: OpenShift 5.0 Updating clusters, https://docs.redhat.com/en/documentation/openshift_container_platform/5.0/html-single/updating_clusters/index ;
  Disconnected environments, https://docs.redhat.com/en/documentation/openshift_container_platform/5.0/html-single/disconnected_environments/index
