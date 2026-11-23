# Laptop-only fix verifications, 2026-11-22

Approved by Dan. No cluster and no AWS: a laptop with a Red Hat pull secret and internet access, oc-mirror `--dry-run` / `list` against registry.redhat.io and quay.io. Nothing was posted to Jira or GitHub. Logs: `~/ocp5-verify/<ticket>/` on the laptop. The large artifacts (builds, downloads, dry-run workspaces) were deleted afterwards.

**Shipped builds checked first:**
- CDN `pub/cgw/oc-mirror/latest/` is still **oc-mirror 2.0.0**, commit c4d52fa, built 2026-10-20, last-modified 2026-10-21.
- The newest container image is `registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0.0-202611030132` (g4b6e461).
- Neither contains any of the fixes below: `git merge-base --is-ancestor ebef96212a0d` fails for both commits.
- So every PASS below is **"verified on an upstream build at <sha>, not a shipped image"**.
- Builds: `CGO_ENABLED=0 go build` with the Makefile's CGO-off tags (`json1 exclude_graphdriver_devicemapper exclude_graphdriver_btrfs containers_image_openpgp`), from `git archive` of the commit. The upstream working trees were not touched.

| Ticket | Build used | Result | Key evidence |
|---|---|---|---|
| OCPBUGS-136644 (ON_QA) `list operators --catalogs` ignores `--authfile` | oc-mirror upstream @ **ebef96212a0d** (PR #1646 merge, main) | **PASS** (upstream build, not shipped) | See 1 |
| OCPBUGS-136646 (POST) CDN oc-mirror not FIPS-capable | Published CDN `latest` = 2.0.0 c4d52fa | **NOT FIXED YET in the published binary** | See 2 |
| OCPBUGS-136257 (PR #1641 approved) cross-major channels | oc-mirror upstream @ **3fd6d8b3f047** (`pull/1641/head`) | **PASS** (unmerged PR build) | See 3 |
| OCPBUGS-138157 (PR #1642) kubeVirtContainer ignores rhel-10 | oc-mirror upstream @ **98b756bb263d** (`pull/1642/head`) | **PASS** (unmerged PR build) | See 4 |
| OCPBUGS-112350 `--tools` skips openshift-install-fips | oc upstream @ **1de7ceb24a40** (`pull/2384/head`, openshift/oc PR #2384, open since 2026-08-30, no review) | **PASS** (unmerged PR build) | See 5 |
| OCPBUGS-136614 installer accepts TP-only capabilities | openshift-install **5.0.1** (8647f26b) | **FIX NOT AVAILABLE; still reproduces on 5.0.1** | See 6 |

## 1. OCPBUGS-136644
Clean auth for every run: temporary `XDG_RUNTIME_DIR` and `DOCKER_CONFIG`, `REGISTRY_AUTH_FILE` unset. Command: `--v2 list operators --catalogs --version=5.0 --authfile <pull secret>`.

| Run | Result |
|---|---|
| Control: CDN 2.0.0 (c4d52fa) | rc 1. `failed to check catalog "registry.redhat.io/redhat/{redhat,certified,community}-operator-index" versions ... unable to retrieve auth token: invalid username/password` (3 times) |
| Fixed: upstream ebef96212a0d | rc 0 in 1 s. Lists `registry.redhat.io/redhat/redhat-operator-index:v5.0`, `certified-operator-index:v5.0`, `community-operator-index:v5.0` |
| Regression: `--catalog=...redhat-operator-index:v5.0 --package=lightspeed-operator --authfile` | rc 0 in 13 s (lightspeed-operator: alpha/stable, v2.0.1) |
| Regression: bad authfile | rc 1, the same clean auth error for the 3 catalogs. No panic |
| Regression: no `--authfile`, pull secret at `$XDG_RUNTIME_DIR/containers/auth.json` | rc 0, 3 catalogs (the old workaround path still works) |

Still open: verification on a **shipped** build. None exists yet. Dan earlier preferred waiting for one; the upstream result is labelled accordingly.

## 2. OCPBUGS-136646
Published CDN `oc-mirror-rhel9-linux-amd64.tar.gz` (latest -> 2.0/):
- `gitVersion 2.0.0-202610201601.p2.gc4d52fa`, `goVersion go1.26.5`;
- `go version -m`: `CGO_ENABLED=0`, no `strictfipsruntime` in GOEXPERIMENT or goVersion;
- `ldd`: "not a dynamic executable"; `file`: statically linked.

This is the same binary as the 11-04 baseline. PR #1651 (native Konflux CDN builds) merged on 11-12, but no new CDN build has been published. Dylan said ART is doing the pipeline work and he will link the build.

**Blocked: no environment:** a runtime check on a FIPS host (that the binary loads `libcrypto.so.3` + `fips.so`) once a new build exists.

## 3. OCPBUGS-136257
ISCs (`~/ocp5-verify/136257/isc-{A,B}.yaml`): `graph: false`, amd64. Channel 1 is 4.22.21-4.22.22, channel 2 is 5.0.1. m2d `--dry-run`.

| Case | Control (2.0.0) | PR #1641 build |
|---|---|---|
| A: fast-4.22 + fast-5.0 | rc 2, 1 s: `NoVersionsFound: no cluster versions found for "amd64" in the "fast-4.23" channel` | rc 0, 15 s. Mapping 582 lines, releases 4.22.21, 4.22.22, 5.0.1 |
| B: stable-4.22 + stable-5.0 | rc 2, 0 s: same, `"stable-4.23" channel` | rc 0, 14 s. Same 3 releases, plus `WARN NoUpgradePath: no qualifying unconditional upgrade path from version 4.22.21 in channel "stable-4.22" to version 5.0.1 in channel "stable-5.0"` |

Case B behaves correctly: stable-5.0 still has no 4.22 nodes (channel check 2026-11-22: stable-5.0 = {5.0.0, 5.0.1}), so there is no edge. The fix now reports that as a warning instead of looking up the non-existent `stable-4.23`.

The case-B rerun promised in the ticket (stable-5.0 with real 4.22 edges) still waits for those edges.

## 4. OCPBUGS-138157
Release 5.0.1 `0000_50_installer_coreos-bootimages.yaml`:
- `stream` = rhcos-4.21 9.8.20261026-0, KubeVirt `ocp-v4.0-art-dev@sha256:b58ab403...`;
- `streams.rhel-10` = rhcos-4.22 10.2.20261026-0, KubeVirt `ocp-v4.0-art-dev@sha256:9cf09e8e...`;
- `streams.rhel-9` = b58ab403.

ISC: fast-5.0, 5.0.1, `kubeVirtContainer: true`, m2d `--dry-run`.

| Build | Mapping | rhel-9 b58ab403 | rhel-10 9cf09e8e |
|---|---|---|---|
| Control 2.0.0 | 199 lines | 1 (`...:5.0.1-x86_64-kube-virt-container`) | **0** |
| PR #1642 | 201 lines | 2 (`...-kube-virt-container`, `...-kube-virt-container-rhel-9`) | **1** (`...:5.0.1-x86_64-kube-virt-container-rhel-10`) |

The PR keeps the legacy tag (rhel-9 content) and adds per-stream tags.

## 5. OCPBUGS-112350
openshift/oc PR #2384 (author palakvoraaaa, opened 2026-08-30, no review yet) builds a default target list that includes the FIPS installer.

- PR build `oc adm release extract --tools` on 5.0.1: rc 0 in 48 s. 8 archives, including **`openshift-install-fips-5.0.1.tar.gz`** (510 MB). It contains `openshift-install-fips` 5.0.1, built from 8647f26b.
- Control (2026-11-17, oc 5.0.1): 7 archives, no FIPS installer.

Note: the PR names the archive `openshift-install-fips-<ver>.tar.gz`. The current `--command` target uses `openshift-install-rhel-%s.tar.gz`.

## 6. OCPBUGS-136614
- No fix PR found in openshift/installer: searches for "OCPBUGS-136614", "CompatibilityRequirements" and the feature-set capability wording, updated after 2026-11-01. The only hit was #11047 (OCPBUGS-134587, merged, the dependency check).
- Re-confirmed with openshift-install 5.0.1 (8647f26b), platform none, dummy pull secret, `baselineCapabilitySet: None` plus the ticket's 18-entry list including `CompatibilityRequirements` and `ClusterAPI`: `create manifests` rc 0 in 0 s.
- `manifests/cvo-overrides.yaml` lines 28-29 list both values, so the installer still accepts what a Default-feature-set ClusterVersion rejects.
- Dan said he'll retest on AWS when a build exists (a live install is "blocked: no environment").
