# oc-mirror v2 mirror-to-mirror, OpenShift 5.0.0 (2026-11-03)

Run from the stack's RHEL 9.6 bastion with `scripts/bastion-mirror-to-mirror.sh`, mirroring
straight from Red Hat into the mirror-registry (Quay 3.12) node in the private subnet.

| | |
|---|---|
| oc-mirror | 2.0.0 (async build from `pub/cgw/oc-mirror/latest/`) |
| ImageSetConfiguration | `candidate-5.0`, 5.0.0 only, `graph: true`, plus `registry.redhat.io/ubi9/ubi:latest` (rendered by `scripts/generate-imageset-config.sh`) |
| Dry run | 200 images planned, 23 s; generates the cluster resources even in dry-run mode |
| Real run | 199/199 release + 1/1 additional images, **12 min 54 s** |
| Disk | ~23 GB in Quay (`/opt/quay-root/data`); 473 MB oc-mirror workspace on the bastion; no archive |

Generated cluster resources (copied here; hostnames are the lab's private names):

- `idms-oc-mirror.yaml`: only two mappings, `ocp-v5.0-art-dev` -> `<ns>/openshift/release` and
  `ocp-release` -> `<ns>/openshift/release-images`. **No `ocp-v4.0-art-dev` entry** for a 5.0 payload,
  matching the mirror-to-disk observation (all 197 payload images are v5.0 art-dev).
- `itms-oc-mirror.yaml`: tag mirrors for the release index and the additional ubi9 image.
- `updateService.yaml`: OSUS UpdateService pointing at the mirrored graph-data image.
- (`signature-configmap.{json,yaml}` were also generated; not copied.)

`scripts/generate-install-config.sh` writes the same two mappings plus a harmless
`ocp-v4.0-art-dev` entry. The rendered install-config passed `openshift-install create manifests`
(5.0.0) up to the credentials check: with the bastion's EC2 instance role, `credentialsMode: Mint`
is rejected ("AWS credentials provided by EC2RoleProvider are not valid for Mint credentials mode").
