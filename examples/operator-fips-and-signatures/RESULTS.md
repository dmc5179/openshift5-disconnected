# Mirrored operators on a FIPS 5.0 cluster (F5) and RHCOS 9/10 images in the mirror (M5)

Checked on 2026-11-04 (read-only) on the lab cluster: OpenShift 5.0.0, `fips: true`, all nodes on
RHCOS 10.2.20261027-0 with `fips_enabled=1`. The mirror is a mirror-registry (Quay) filled by
oc-mirror v2 mirror-to-mirror (`ocp5` org; release 4.22.18 -> 5.0.0 plus the operator catalog
subset). The sigstore / ClusterImagePolicy check (M7) is in `examples/clusterimagepolicy/README.md`.

Tags: **[LAB]** means seen on the cluster or mirror. **[CODE]** means read in the source.
**[INFER]** means a conclusion that was not tested.

Method: image digests came from the running pods and the CSV `relatedImages`. cert-manager is installed
through OLM v1 (ClusterExtension, no CSV), so its operand images came from the operator Deployment's
`RELATED_IMAGE_*` variables. All 19 images were present in the mirror. (The full-filesystem sweep for bundled crypto was done for the two Lightspeed Python images. rhokp, dataverse-exporter and PostgreSQL got only targeted checks, because of the 60-minute limit.) For each image the
entrypoint binary was extracted from the mirror with `oc image extract` and checked with
`readelf -d` (dynamic libraries) and `strings` (Go build info: `CGO_ENABLED`, `GOEXPERIMENT`,
`-tags`, `GOFIPS140`; Rust crate names). For Python images and images with C servers, the image
filesystem was extracted and the OpenSSL linkage checked. **At runtime**, the memory maps
(`/proc/<pid>/maps`) of every running operator process were read on the FIPS nodes to see which
crypto library is actually loaded.

## T3 / F5: are the mirrored operators FIPS-capable?

Verdict key: **capable** = uses the RHEL OpenSSL FIPS provider (Go built with `CGO_ENABLED=1`
and the Red Hat OpenSSL backend, or C/Python linked to the system `libcrypto`). **strict** = also
built with `strictfipsruntime`, so the binary refuses to start in FIPS mode without OpenSSL.
**caveat** = capable, but see the note.

### OpenShift Update Service 5.0.3 (OLM v0)

| Image | Component | Language / base | CGO | strictfipsruntime | Verdict | Evidence |
|---|---|---|---|---|---|---|
| `openshift-update-service-rhel8-operator@sha256:759f4de1...` | updateservice-operator | Go **1.21.11**, RHEL **8.10** | 1 | **no** | caveat | golang-fips/openssl compiled in. Runtime: loads `/usr/lib64/libcrypto.so.1.1.1k` [LAB]. Old Go toolchain, RHEL 8 OpenSSL 1.1.1k, not strict (it would not fail closed if OpenSSL were missing). |
| `openshift-update-service-rhel8@sha256:a9468a66...` | graph-builder | Rust 1.75, RHEL 8.10 | n/a | n/a | caveat | `NEEDED libssl.so.1.1 libcrypto.so.1.1`, runtime loads `libssl/libcrypto 1.1.1k` [LAB]. **`ring-0.16.20` is also compiled in**: some primitives may bypass OpenSSL. [INFER] |
| same image | policy-engine | Rust 1.75, RHEL 8.10 | n/a | n/a | caveat | Same as graph-builder [LAB]. |
| `ocp5/openshift/graph-image:latest` | graph-data init container | data image built by oc-mirror (`coreutils` only) | n/a | n/a | n/a | No crypto [LAB]. |

### cert-manager Operator 1.20.1 (OLM v1, operand 1.20.4)

| Image | Component | Language | CGO | strictfipsruntime | Verdict | Evidence |
|---|---|---|---|---|---|---|
| `cert-manager-operator-rhel9@sha256:207804f9...` | operator | Go 1.26.7 (Red Hat) | 1 | yes (`GOEXPERIMENT` + `-tags=strictfipsruntime,openssl`) | **strict** | Runtime: `libcrypto.so.3.5.8` + `ossl-modules/fips.so` loaded [LAB] |
| `jetstack-cert-manager-rhel9@sha256:b3305a06...` | controller | Go 1.26.7 | 1 | yes | **strict** | Log: `go_version="go1.26.7 (Red Hat 1.26.7-1.el9_8) X:strictfipsruntime"`. Runtime: `fips.so` loaded [LAB] |
| same image | webhook | Go 1.26.7 | 1 | yes | **strict** | Same as above [LAB] |
| same image | cainjector | Go 1.26.7 | 1 | yes | **strict** | Same as above [LAB] |
| `jetstack-cert-manager-acmesolver-rhel9@sha256:8ce8e3f2...` | acmesolver | Go 1.26.7 | 1 | yes | strict | Build info [LAB]; not running (no ACME issuer) |
| `cert-manager-istio-csr-rhel9@sha256:f63c50a7...` | istio-csr 0.16.0 | Go 1.26.7 | 1 | yes | strict | Build info [LAB]; not deployed |
| `cert-manager-trust-manager-rhel9@sha256:1fef2bff...` | trust-manager 0.20.3 | Go 1.26.7 | 1 | yes | strict | Build info [LAB]; not deployed |

### OpenShift Lightspeed operator 2.0.0 (OLM v0; no OLSConfig, so only the two managers run)

| Image | Component | Language / base | CGO | strictfipsruntime | Verdict | Evidence |
|---|---|---|---|---|---|---|
| `lightspeed-rhel9-operator@sha256:8d0eb397...` | lightspeed-operator | Go 1.26.7, RHEL 9.8 | 1 | tag only (`-tags=strictfipsruntime`, no `GOEXPERIMENT`) | capable | Runtime: `libcrypto.so.3` + `fips.so` loaded [LAB]. Whether the tag alone gives strict mode is not confirmed. |
| `lightspeed-agentic-rhel9-operator@sha256:b6ff1ae1...` | agentic operator | Go 1.26.7 | 1 | tag only, plus **`GOFIPS140=v1.0.0-c2097c7c`** and `fips140v1.0` | capable | Also contains the upstream Go FIPS 140-3 module, but at runtime `libcrypto.so.3` + `fips.so` are loaded [LAB]. Ask the Lightspeed team which module is the validated boundary. |
| `lightspeed-console-plugin-rhel9@sha256:7d107630...` | console plugin | nginx (static files), RHEL 9.8 | n/a | n/a | capable | `nginx NEEDED libssl.so.3 libcrypto.so.3`, image has `fips.so` [LAB] |
| `lightspeed-agentic-console-rhel9@sha256:3f023753...` | agentic console plugin | nginx, RHEL 9.8 | n/a | n/a | capable | Same as above [LAB] |
| `lightspeed-service-api-rhel9@sha256:21d38165...` | lightspeed-service API (5.1 GB) | Python 3.12, RHEL 9.6 | n/a | n/a | caveat | `_ssl`/`_hashlib` link system `libssl/libcrypto.so.3` (3.2.2). `cryptography` is built from source (`cp312-abi3-linux_x86_64`, not manylinux) and links system OpenSSL. grpc and pyarrow also link system OpenSSL. No bundled `libssl`/`libcrypto` [LAB]. **Exception: `hf_xet` (Hugging Face Xet download client, Rust) carries its own static TLS crypto (BoringSSL strings, no libssl NEEDED)**. It is only used for Hugging Face downloads, which a disconnected cluster cannot make. [INFER] |
| `lightspeed-agentic-sandbox-rhel9@sha256:48a69d0c...` | agentic sandbox | Python 3.12, RHEL 9.6 | n/a | n/a | capable | Same system-OpenSSL linkage as the service API, no hf_xet [LAB] |
| `lightspeed-agentic-alerts-adapter-rhel9@sha256:31e97eef...` | alerts adapter | Go 1.26.7 | 1 | yes (`GOEXPERIMENT` + tag) | strict | Build info [LAB] |
| `otelcol-lightspeed-rhel9@sha256:4aa417e9...` | OTel collector | Go 1.26.7 | 1 | tag only | capable | Build info [LAB] |
| `openshift-mcp-server-rhel9@sha256:a551fd58...` | **openshift-mcp** server 1.0.0 | Go 1.26.7 | 1 | yes (`GOEXPERIMENT` + tag) | strict | Build info [LAB] |
| `rhokp-rhel9@sha256:adbe5135...` | **offline-knowledge-portal** (7.7 GB) | Rust 1.92 server `mel` + httpd, RHEL 9.8 | n/a | n/a | capable | `mel` uses `openssl-sys-0.9.113`, `NEEDED libssl.so.3 libcrypto.so.3`. `mod_ssl` links system OpenSSL [LAB] (partial filesystem extract; no bundled-crypto sweep) |
| `dataverse-exporter-rhel9@sha256:dfa181d4...` | dataverse exporter | Python 3.12, RHEL 9 | n/a | n/a | capable | `_ssl`/`_hashlib` link system `libssl/libcrypto.so.3` [LAB]. site-packages not swept. Sends data to Red Hat, so it is unused offline. |
| `postgresql-16@sha256:42f385ac...` | PostgreSQL 16 | C, RHEL 9 | n/a | n/a | capable | `postgres NEEDED libssl.so.3 libcrypto.so.3` [LAB] |

### Runtime check on the FIPS nodes [LAB]

- Inside every container the crypto policy reads `FIPS`, although the images ship `DEFAULT` in
  `/etc/crypto-policies/config`. CRI-O on a FIPS node mounts the host's FIPS policy into containers.
- Libraries loaded by the running processes (from `/proc/<pid>/maps`):
  - cert-manager operator, controller, webhook, cainjector; both Lightspeed managers:
    `libcrypto.so.3.x` + `/usr/lib64/ossl-modules/fips.so`.
  - OSUS operator, graph-builder, policy-engine: `libcrypto.so.1.1.1k` (+ `libssl.so.1.1.1k`).
    RHEL 8 OpenSSL 1.1.1 has its FIPS mode built in (no separate provider) and switches it on from
    `/proc/sys/crypto/fips_enabled`.
- Logs of all 12 containers: no FIPS or crypto start-up errors. The only crypto-related lines are cert-manager's
  version banner (`X:strictfipsruntime`) and a recurring OSUS graph-builder DEBUG message:
  `unable to process certificate ca-bundle.trust.crt: ... PEM routines:get_name:no start line`.
  That is a CA-bundle parsing message, not a FIPS failure. Graph retrieval works (CVO RetrievedUpdates=True, I-11).

### F5 conclusions

1. **cert-manager 1.20.1: fully FIPS-ready.** All 7 binaries are strict FIPS builds, and the running
   ones use the RHEL 9 OpenSSL FIPS provider.
2. **Lightspeed 2.0.0: FIPS-capable.** Go components use OpenSSL (4 strict, 3 with the build tag only).
   The Python service and sandbox use system OpenSSL. Open points for the Lightspeed team: (a) the agentic
   operator also embeds the Go-native FIPS 140-3 module (`GOFIPS140=v1.0.0`), so which module counts?
   (b) `hf_xet` carries its own crypto in the service image; (c) three Go components lack
   `GOEXPERIMENT=strictfipsruntime`.
3. **OpenShift Update Service 5.0.3: the weakest of the three.** It works on a FIPS cluster, but it is
   built on **RHEL 8** with OpenSSL 1.1.1k (a RHEL 8 module, not the RHEL 9/10 modules that OCP 5 FIPS
   claims rest on). The operator uses Go 1.21.11 without strictfipsruntime, and the Rust operand also
   embeds `ring`. Customers with strict FIPS 140-3 requirements should ask Red Hat for a statement on
   OSUS, or file an RFE for a RHEL 9 rebuild. [INFER on the validation status]

## M5: RHCOS 9 and RHCOS 10 images in the 5.0 payload and in the mirror

### Payload (`oc adm release info --idms-file` against the mirror, 5.0.0 `sha256:5d7ed8b3...`) [LAB]

The release has 936 manifests. Metadata: `machine-os 10.2.20261027-0 Red Hat Enterprise Linux CoreOS 10.2`.

| Payload tag | Content | In mirror (`ocp5/openshift/release@digest`) | Size |
|---|---|---|---|
| `rhel-coreos` | RHCOS **9.8.20261026-0** node image | PRESENT | 1473 MiB |
| `rhel-coreos-extensions` | RHCOS 9 extensions | PRESENT | 865 MiB |
| `rhel-coreos-10` | RHCOS **10.2.20261027-0** node image | PRESENT | 936 MiB |
| `rhel-coreos-10-extensions` | RHCOS 10 extensions | PRESENT | 899 MiB |
| `machine-os-images` | boot ISOs for both streams (`/coreos/coreos-x86_64.iso` = 9.8, `/coreos/coreos10-x86_64.iso` = 10.2, see `examples/agent-iso-offline/`) | PRESENT | 2274 MiB |
| `ironic-machine-os-downloader` | bare-metal IPI downloader | PRESENT | 1045 MiB |
| `kubevirt-cloud-controller-manager`, `kubevirt-csi-driver` | HCP KubeVirt platform components | PRESENT | 91 / 110 MiB |

`OSImageStream cluster`: `defaultStream: rhel-10`. `status.availableStreams` lists `rhel-10`
(osImage `5478d866...`, extensions `9e9093c5...`) and `rhel-9` (`d4854a03...`, `78aa4520...`).
These are the same digests as the payload tags above, so both streams can be used offline.
The MachineConfigPools have no `osImageStream` set, so they follow the default (rhel-10).

### Boot images: `coreos-bootimages` ConfigMap (openshift-machine-config-operator) [LAB]

The ConfigMap has two keys:
- `stream` (the old single-stream key): `rhcos-4.21`, **RHCOS 9.8.20261026-0** (AWS us-east-2
  `ami-0670f9faff18f1fc1`).
- `streams` (new, per stream): `rhel-10` -> 10.2.20261026-0 (`ami-013b7ccf3fbe9800c`) and
  `rhel-9` -> 9.8.20261026-0 (`ami-0670f9faff18f1fc1`).

The ISO/qcow2/AMI boot images are URLs and cloud images (rhcos.mirror.openshift.com, AWS AMIs),
not container images. oc-mirror does not mirror them. Offline ISOs come from `machine-os-images` (above).

KubeVirt boot container images (used by OpenShift Virtualization / HCP KubeVirt node pools), all in **`ocp-v4.0-art-dev`**:

| Stream | Reference | In mirror |
|---|---|---|
| rhel-10 (x86_64) | `ocp-v4.0-art-dev:rhel-10.2-coreos-kubevirt` = `@sha256:9cf09e8e...` | **MISSING** |
| rhel-9 (x86_64) | `ocp-v4.0-art-dev:rhel-9.8-coreos-kubevirt` = `@sha256:b58ab403...` | **MISSING** |
| rhel-9 aarch64 / s390x | `@sha256:d87906e4...` / `@sha256:db80c803...` | MISSING (not requested) |

Missing is expected: our ImageSetConfiguration did not set `mirror.platform.kubeVirtContainer: true`.
What matters is what happens when it is set: [CODE] oc-mirror `release-5.0`
`internal/pkg/release/local_stored_collector.go` `getKubeVirtImage()` parses **only `data.stream`**
and takes **only `architectures.x86_64.images.kubevirt.digest-ref`**. On 5.0.0 that is the
**RHCOS 9.8** kubevirt image. The RHCOS 10.2 kubevirt image (only listed under `data.streams.rhel-10`)
is never mirrored. `main` (2e526488) adds multi-architecture support (x86_64 + s390x,
OCPBUGS-104448) but still reads only `data.stream`. So the RHCOS 10 kubevirt image is not
picked up there either. [CODE; not lab-run with kubeVirtContainer: true]

### M5 answer

- **Node images: yes.** A standard oc-mirror v2 platform run (no extra flags) mirrors both RHCOS 9.8
  (`rhel-coreos`, `rhel-coreos-extensions`) and RHCOS 10.2 (`rhel-coreos-10`,
  `rhel-coreos-10-extensions`), and `machine-os-images` with both boot ISOs. They are ordinary payload
  images. Both OS streams can be selected offline. [LAB]
- **KubeVirt boot container images: no.** They are not payload images. They are mirrored only with
  `kubeVirtContainer: true`, and even then oc-mirror 5.0 picks up only the legacy-stream (RHCOS 9.8)
  image, not the RHCOS 10.2 default. [CODE] Customers using HCP on OpenShift Virtualization with
  RHCOS 10 node pools must mirror `quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:9cf09e8e...`
  themselves (an `additionalImages` entry by digest) and keep the `ocp-v4.0-art-dev` IDMS mapping.
  Candidate oc-mirror bug: `getKubeVirtImage` should read `data.streams` (all streams). [INFER]
- Cloud boot images (AMIs) and the ISO/qcow2 URLs in `coreos-bootimages` are not container images
  and are never mirrored. On AWS IPI the public RHCOS AMI is used. In ISO regions, import the AMI yourself (ISO-4).
