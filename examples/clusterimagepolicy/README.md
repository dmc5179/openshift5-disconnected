# ClusterImagePolicy and sigstore signatures on a disconnected OpenShift 5.0 cluster (M7)

Checked on 2026-11-04 against the lab cluster: OpenShift 5.0.0, FIPS, RHCOS 10.2, installed from
a mirror-registry (Quay) that was filled with oc-mirror v2 mirror-to-mirror. Everything here was
read-only. The only write was `oc apply --dry-run=server` for the template.

Tags: **[LAB]** means seen on the cluster or mirror. **[CODE]** means read in the source
(openshift/oc-mirror `origin/release-5.0` @ 4b6e461b). **[INFER]** means a conclusion that was not tested.

## Summary

- OpenShift 5.0 enforces Red Hat sigstore signatures on **payload images only**. On a disconnected
  cluster this works through the mirror with no extra steps, because oc-mirror v2 copies the
  `sha256-<digest>.sig` tags along with the images. [LAB]
- No signature failures were found on the cluster (CRI-O journal, pod events). [LAB]
- Operator images (registry.redhat.io) are mirrored together with their signatures, but no policy
  checks them. The node default is `insecureAcceptAnything`. [LAB]
- oc-mirror does **not** create a ClusterImagePolicy, and its CLI cannot sign your own images.
  Use `cosign` for that, plus the template in this directory. [CODE]

## 1. The default `openshift` ClusterImagePolicy [LAB]

`oc get clusterimagepolicy` returns one object, `openshift`. `oc get imagepolicy -A` returns none.

| Field | Value |
|---|---|
| Owner | ClusterVersion `version` (CVO manifest, `include.release.openshift.io/self-managed-high-availability`). The CVO reverts manual edits. |
| Description | "Require Red Hat signatures for quay.io/openshift-release-dev/ocp-release container images." |
| `scopes` | `quay.io/openshift-release-dev/ocp-release`, `quay.io/openshift-release-dev/ocp-v4.0-art-dev`, `quay.io/openshift-release-dev/ocp-v5.0-art-dev` |
| `policyType` | `PublicKey` (not Fulcio, no Rekor key) |
| Root of trust | RSA 4096-bit public key, SHA-256 of the DER key `ba9d26350d78893a20f337e2153a113108bfcf064085afaee60d446e63405576` |
| `signedIdentity` | not set in the CR. On the nodes it becomes `matchRepoDigestOrExact`. |
| `status` | empty |

## 2. What the nodes enforce [LAB]

Read on worker `ip-10-0-56-98` with `oc debug node`:

- `/etc/containers/policy.json`: `default: insecureAcceptAnything`. The three quay.io scopes above
  are `sigstoreSigned` with the same key and `matchRepoDigestOrExact`, for both the `docker` and
  `atomic` transports. Nothing else is checked.
- `/etc/containers/registries.d/sigstore-registries.yaml` (written by the MCO) sets
  `use-sigstore-attachments: true` for the three quay.io scopes **and for the mirror repositories
  taken from the IDMS**: `<mirror>:8443/ocp5/openshift/release` and
  `<mirror>:8443/ocp5/openshift/release-images`. The `registry.redhat.io.yaml` and
  `registry.access.redhat.com.yaml` files also turn on sigstore attachments, but there is no policy for
  those registries.
- CRI-O journal since install: no signature, sigstore, "not trusted" or "rejected" messages (the
  only matches were the configuration dumps at startup). No `Failed` events mention signatures.

How this works through the mirror: pods reference `quay.io/openshift-release-dev/ocp-v5.0-art-dev@sha256:...`.
The policy is checked against that name, CRI-O fetches the image and its `.sig` attachment from the
IDMS mirror, and the signature identity (`quay.io/...@sha256:...`) matches by digest. [INFER from the
node configuration plus the clean journal]

## 3. Signatures in the mirror [LAB]

Counted with the registry v2 `tags/list` API (paginated):

| Mirror repository | Image tags | `.sig` tags |
|---|---|---|
| `ocp5/openshift/release` (payload components, 4.22.18 + 5.0.0) | 388 | 388 (one per image) |
| `ocp5/openshift/release-images` | 2 | 2 (`sha256-5d7ed8b3...sig` = 5.0.0, and the other mirrored release) |
| `ocp5/cert-manager/jetstack-cert-manager-rhel9` | 1 | 5 |
| `ocp5/openshift-lightspeed/lightspeed-rhel9-operator` | 1 | 3 |
| `ocp5/openshift-update-service/openshift-update-service-rhel8` | 1 | 2 |
| `ocp5/openshift/graph-image` (built locally by oc-mirror) | 1 | 0 |

The 5.0.0 release signature (`release-images:sha256-5d7ed8b3...sig`) is an OCI manifest with 8
`application/vnd.dev.cosign.simplesigning.v1+json` layers, each with the
`dev.cosignproject.cosign/signature` and `dev.sigstore.cosign/bundle` annotations. The payload is
`{"docker-reference":"quay.io/openshift-release-dev/ocp-release@sha256:5d7ed8b3..."}`, so the identity
is the quay.io name, not the mirror name. This is why the policy scopes stay on quay.io.

**If the mirror had no signatures** (for example, after `oc-mirror --remove-signatures`): every
payload image pull would hit a `sigstoreSigned` requirement with no signature to check, and CRI-O
would refuse it. Installs and upgrades would fail. The policy is not limited to quay.io traffic:
it applies to the logical quay.io name even when IDMS sends the pull to the mirror. [INFER; not
tested, because it would mean changing the `ocp5` org]

## 4. How oc-mirror v2 (5.0, async 2.0.0) handles sigstore signatures [CODE]

- Signatures are copied **by default**. `--remove-signatures` turns this off
  (`internal/pkg/cli/executor.go` L284). When it copies, oc-mirror sets up a working-dir
  `registries.d` with `use-sigstore-attachments: true` for every source and destination host
  (`internal/pkg/registriesd/registriesd.go`, `internal/pkg/mirror/mirror.go` L114-128).
- Mirror-to-disk archives include the signature blobs
  (`internal/pkg/archive/image-blob-gatherer.go`). For manifest lists it takes the per-architecture
  signatures, because Red Hat signs only the single-architecture manifests (OCPBUGS-87160 comment, L86-89).
- `oc-mirror delete --delete-signatures` deletes signatures too. For multi-arch images it deletes
  only the manifest-list signature (`internal/pkg/cli/delete.go` L101).
- Separately, release signatures in the older GPG format go into the `mirrored-release-signatures`
  ConfigMap (`internal/pkg/clusterresources/const.go`). The CVO uses those, not CRI-O.
- oc-mirror does **not** generate a ClusterImagePolicy. No `sign-by*` CLI flag is registered
  (the internal `SignBySigstorePrivateKey` option in `internal/pkg/mirror/options.go` is not wired to a flag).

## 5. Template: verify your own images in the mirror

`clusterimagepolicy-mirror-template.yaml` is a ClusterImagePolicy for a mirror scope
(`<MIRROR_HOST>:8443/<ORG>`) with a `PublicKey` root of trust (placeholder key) and
`MatchRepoDigestOrExact`. The comments describe a `RemapIdentity` variant for images signed under a
build-registry name before mirroring.

Server-side dry run on 5.0.0 [LAB]:

| File | Result |
|---|---|
| Template as shipped (`<MIRROR_HOST>` placeholders) | rejected: "invalid image scope format, scope must contain a fully qualified domain name or 'localhost'". Replace the placeholders first. |
| Placeholders replaced (`mirror.example.com:8443/myorg`) | `created (server dry run)` |
| `RemapIdentity` variant | `created (server dry run)` |

Note: admission accepted the placeholder `keyData`, which is not a real key. The API server does
not check the key. A wrong key shows up only later, as failed pulls on the nodes. Check
`base64 -d <<<"$keyData" | openssl pkey -pubin -noout` before you apply.

Customer workflow:
1. Create a key pair: `cosign generate-key-pair`. Keep `cosign.key` off the cluster.
2. Push or mirror the image, then sign it by digest under the name pods use:
   `cosign sign --key cosign.key <MIRROR_HOST>:8443/<ORG>/app@sha256:...`. In an air gap, add
   `--tlog-upload=false`, because there is no Rekor. The policy has no `rekorKeyData`, so no transparency log is needed.
3. Fill in the template, run `oc apply --dry-run=server -f`, then apply it on a test cluster. The MCO
   rolls out the new `policy.json` / `registries.d` to all pools. Watch `oc get mcp`.
4. Check: a signed image runs. An unsigned image in the scope fails with `SignatureValidationFailed`.

Cautions:
- Do not add scopes under `quay.io/openshift-release-dev`. The `openshift` policy owns them.
- If a scope covers the mirror path that holds the payload (`<mirror>/ocp5/openshift/...`) and pods
  pull it under the quay.io name, your policy does not apply to those pulls. Keep customer images
  in a separate org or path. [INFER]
- A namespaced `ImagePolicy` (same spec) limits enforcement to one namespace. It is useful for a pilot.
