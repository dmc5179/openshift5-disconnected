# oc-mirror v2 against OCP 5.0.0: mirror-to-disk tests (2026-11-03)

Local Fedora 44 workstation. Test area outside the repo: `~/ocm-ocp5-m2d/` (logs in `logs/`).
No disk-to-mirror was run. Tags: **[OBS]** = observed in this run, **[INFER]** = inference.

## Versions

| Binary | gitVersion | Go | Notes |
|---|---|---|---|
| async latest (used for all runs) | `2.0.0-202610201601.p2.gc4d52fa.assembly.stream.el9-c4d52fa` | go1.26.5 | from `mirror.openshift.com/pub/cgw/oc-mirror/latest/oc-mirror-rhel9-linux-amd64.tar.gz`, sha256 `fd2b899c…6d72` matched `sha256sum.txt`. `supportedOCPVersions`: 4.12, 4.14, 4.16, 4.18, 4.20, 4.21, 4.22, 4.23, 5.0 |
| local `~/.local/bin/oc-mirror` | `4.22.0-202610061703.p2.ged9ff0d.assembly.stream.el9-ed9ff0d` | go1.25.14 `X:strictfipsruntime` | not used for the runs |

[OBS] The async build reports a new version scheme (**2.0.0**, not 4.x/5.x). Its Go version string does **not** include `X:strictfipsruntime`, unlike the 4.22 payload build. [INFER] The async binary may not be FIPS-capable in the same way. Check this before using it on a FIPS bastion (see F1/F2).

Free disk before the tests: 479 GB (`df -h ~`).

## Commands

```bash
# list (catalog check)
oc-mirror --v2 list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v5.0 \
  [--package <pkg>] --authfile ~/.docker/config.json --cache-dir ~/ocm-ocp5-m2d/list-cache

# dry run, per case (own dest, cache and port)
oc-mirror --v2 -c <isc> file://$HOME/ocm-ocp5-m2d/<case> --dry-run \
  --cache-dir $HOME/ocm-ocp5-m2d/<case>-cache --authfile ~/.docker/config.json \
  --log-level debug --port <port>

# real mirror-to-disk, case (a)
oc-mirror --v2 -c isc-a-platform.yaml file://$HOME/ocm-ocp5-m2d/real \
  --cache-dir $HOME/ocm-ocp5-m2d/real-cache --authfile ~/.docker/config.json \
  --log-level debug --port 55200
```

The configs are in this directory: `isc-a-platform.yaml`, `isc-b-docs-candidate.yaml` (copy of `../imageset-config-5.0.yaml` with only `stable-5.0` changed to `candidate-5.0`), and `isc-c-platform-webterminal.yaml`. All of them use `graph: true`.

## Per-case results (dry run)

| Case | Exit | Time | mapping.txt | ocp-v5.0-art-dev | ocp-v4.0-art-dev | Other | Warnings/errors |
|---|---|---|---|---|---|---|---|
| a: platform only, candidate-5.0, 5.0.0 | 0 | 8 s | 199 | 197 | **0** | 1 `ocp-release:5.0.0-x86_64`, 1 graph-image | only "198/199 not in cache" (expected) |
| b: docs example, candidate-5.0 | 0 | 42 s | 227 | 197 | **0** | release, graph, v5.0 catalog, 2 ubi, 3 ALBO, 22 3scale and related images | same "not in cache" warning only |
| c: platform + web-terminal | 0 | 39 s | 204 | 197 | **0** | release, graph, v5.0 catalog, 4 web-terminal images | same |

The first parallel attempt at b and c crashed with `panic: listen tcp 127.0.0.1:55000: bind: address already in use`. See Gotchas.

**Release image chosen [OBS]:** `quay.io/openshift-release-dev/ocp-release:5.0.0-x86_64`. Registry digest `sha256:5d7ed8b3e98bc3a10c50f36f07262a962d59ad2d3ea5fb4935ff10c408c02e55` (skopeo). The signature file is `signatures/5.0.0-x86_64-sha256-5d7ed8b3…`. mapping.txt uses the tag, not the digest. The debug log also prints "image manifest digest sha256:20b5832c…" for the copied release image, which does not match the registry digest. [INFER] It is probably the digest of the local OCI copy. Not investigated.

**v5.0 operator catalog [OBS]:** `redhat-operator-index:v5.0` resolved to `sha256:de7929b2d81d7f870e635120b408795ad56cd57b850b4303f54c309c85c20317`. It has 109 packages, including `lightspeed-operator` (channel `stable`).

| Package | In v5.0? | Default channel | Channels (head) | Mirrored with no channel filter |
|---|---|---|---|---|
| aws-load-balancer-operator | yes | stable-v1 | stable-v1, stable-v1.3 (both v1.3.3) | 1 bundle (v1.3.3) |
| 3scale-operator | yes | threescale-2.13 | threescale-2.13 (v0.10.5), threescale-mas (v0.11.8-mas) | the heads of **both** channels (3scale-amp2 and 3scale-mas image sets, many rhel7 images, plus `openshift4/ose-cli`) |
| web-terminal | yes | fast | fast (v1.17.2) | 1 bundle + 3 images |

[OBS] Catalog filtering works on v5.0: case (c) adds only 4 web-terminal images plus the catalog. [OBS] A package listed without `channels` brought in the head of every channel, not only the default channel. This was seen for 3scale.

## Payload contents worth noting [OBS]

- 197 component images, all under `ocp-v5.0-art-dev`. There is no `oc-mirror` component (consistent with J1).
- `rhel-coreos`, `rhel-coreos-extensions`, `rhel-coreos-10`, `rhel-coreos-10-extensions`, `machine-os-images`, `agentic-skills`, `installer`, `baremetal-installer`, `cli`, `cli-artifacts`, `installer-artifacts`. Both the RHCOS 9 and RHCOS 10 node images are in the payload (M5).
- **`ocp-v4.0-art-dev` is still referenced inside the 5.0 payload manifests**, but not by any payload image:
  - `release-manifests/0000_50_installer_coreos-bootimages.yaml` and `0000_50_installer-artifacts_coreos-bootimages.yaml` (the coreos-bootimages ConfigMap, `"stream": "rhcos-4.21"`) have 18 references each. These are the **KubeVirt boot-image containers** `ocp-v4.0-art-dev:rhel-9.8-coreos-kubevirt` and `ocp-v4.0-art-dev:rhel-10.2-coreos-kubevirt`, with `digest-ref`s. They are not in mapping.txt. They would only be mirrored with `kubeVirtContainer: true` (M5).
  - `0000_90_openshift-cluster-image-policy.yaml`: the default `ClusterImagePolicy/openshift` scopes are `ocp-release`, `ocp-v4.0-art-dev` and `ocp-v5.0-art-dev`.

[INFER] For a plain 5.0.0 install, `imageDigestSources` needs `ocp-release` plus `ocp-v5.0-art-dev`. That matches the docs' 2-entry set (DOC-10). An `ocp-v4.0-art-dev` entry is needed only if the KubeVirt boot images are mirrored (HCP on OpenShift Virtualization), or for upgrades from 4.x releases. It does no harm to add it. Verify this with an actual disk-to-mirror run and the generated IDMS.

## Real mirror-to-disk, case (a) [OBS]

| | |
|---|---|
| Exit / duration | 0 / 273 s wall clock (oc-mirror "mirror time" 4m32s) |
| Images | 199/199 "release images mirrored successfully" |
| Archive | `~/ocm-ocp5-m2d/real/mirror_000001.tar`: 24,852,717,568 bytes (~23.1 GiB), one file |
| Cache dir | 23 GB (deleted after recording, as instructed) |
| working-dir | 550 MB |
| Warnings/errors | none |
| New output files | `working-dir/isc_pinned_<ts>.yaml` and `disc_pinned_<ts>.yaml` (a pinned ISC and a matching DeleteImageSetConfiguration). For platform-only, the pinned ISC is the same as the input; release digests are not pinned. |

**`working-dir/cluster-resources/` is empty after mirror-to-disk.** No IDMS, ITMS, signature ConfigMap or UpdateService was generated. [INFER] This is expected oc-mirror v2 behaviour: cluster resources are written in the disk-to-mirror and mirror-to-mirror phases, when the destination registry is known. So **there is no `idms-oc-mirror.yaml` to quote**. It needs a disk-to-mirror run (out of scope here) or a mirror-to-mirror run (`scripts/bastion-mirror-to-mirror.sh`). The release signature is at `working-dir/signatures/5.0.0-x86_64-sha256-5d7ed8b3…`, and it is inside the archive.

## Gotchas

1. **Parallel oc-mirror runs collide on port 55000**: the embedded registry panics. Give each concurrent run its own `--port`.
2. **`--dry-run` is not side-effect free.** With `graph: true` it builds the graph-data image and pushes it into the cache (~308 MB per cache dir). The dry-run mapping.txt then lists the graph image as `127.0.0.1:<port>/openshift/graph-image:latest`. With operators, the dry run also extracted the catalog (~2 GB working-dir for b and c).
3. The dry-run summary prints both "198/199 images ... are not available in the cache" (WARN) and "all 1 images required for mirroring are available in local cache. You may proceed with mirroring from disk to disconnected registry" (INFO). The second line is misleading.
4. Mirror-to-disk produces no cluster resources (see above).
5. The async binary's version is 2.0.0, so version checks in automation that expect `4.x`/`5.x` will break.
6. The 3scale-operator in the v5.0 catalog is still the old 2.13 and MAS channels, with rhel7 images.

## Against the established facts

- Everything in the brief held: candidate-5.0 has 5.0.0; the v5.0 catalog and `ocp-release:5.0.0-x86_64` exist; the `--authfile` / no-`--workspace`-with-`file://` / `--cache-dir` handling works as stated.
- The brief expected IDMS/ITMS/signature ConfigMaps under `cluster-resources/` after mirror-to-disk. **They are not generated in that phase** (observed).
- "The 5.0 payload references `ocp-v5.0-art-dev`" is true for all 197 images. However, `ocp-v4.0-art-dev` has not disappeared from the payload metadata (KubeVirt boot images, ClusterImagePolicy scope).

## Bastion mirror-to-mirror script

`scripts/bastion-mirror-to-mirror.sh` is a draft and has not been run. It passes shellcheck. Open questions:
- Does the bastion have ssh access to the registry node (key, `ec2-user`, `sudo` without a tty)? If not, use `--ca-file`.
- Is the Quay CA really at `/opt/quay-root/quay-rootCA/rootCA.pem`, and does the server certificate's SAN include the private DNS name?
- Credential check uses `GET /v2/auth?service=<host>:8443&scope=...` with basic auth, expecting 200 for valid credentials. This is unverified against mirror-registry Quay.
- Exact `cluster-resources` file names for 5.x (cs-/cc- prefixes, signature-configmap, updateService.yaml) are assumed from 4.x.
- m2m disk use (cache) is unmeasured.
- The async oc-mirror FIPS status matters if the bastion runs in FIPS mode.
