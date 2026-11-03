# oc-mirror v2 operator mirroring, OpenShift 5.0 catalog: dry run (2026-11-03)

Run on the FIPS-mode RHEL 9.6 bastion with oc-mirror 2.0.0
(`2.0.0-202610201601.p2.gc4d52fa.assembly.stream.el9`, from `pub/cgw/oc-mirror/latest/`).
Mirror-to-mirror **dry run only**, nothing was copied.

## Catalog listing (M4)

`registry.redhat.io/redhat/redhat-operator-index:v5.0` **exists** and resolved to
`@sha256:427a7d09fce4bda0311699dce3fb303272f7b23804a62d5b26f6e3128dfd7a39`.

| Package | Default channel | Head | Install modes | Dependencies |
|---|---|---|---|---|
| web-terminal | fast | web-terminal.v1.17.2 | AllNamespaces | **requires devworkspace-operator >=0.6.0** (+ DevWorkspace GVKs) |
| devworkspace-operator | fast | devworkspace-operator.v1.0.0 | AllNamespaces | none |
| kubernetes-nmstate-operator | stable | kubernetes-nmstate-operator.5.0.0-202610271435 | Own/Single/AllNamespaces | none |
| openshift-cert-manager-operator | stable-v1 (also stable-v1.20) | cert-manager-operator.v1.20.1 | Own/Single/AllNamespaces | none |

Install modes and dependencies were read from the catalog FBC (`oc image extract --path /configs/<pkg>/`).
cert-manager is the OLM v1 candidate: AllNamespaces and no dependencies. Webhook support was not checked,
and it has not been installed through a ClusterExtension.

Commands (v2 syntax, `=` form):
```
oc-mirror --v2 list operators --catalog=registry.redhat.io/redhat/redhat-operator-index:v5.0 --package=<pkg> \
  --authfile ~/pull-secret.json --cache-dir <dir> --port <port>
```
**Surprise:** `oc-mirror --v2 list operators --catalogs --version=5.0 --authfile ~/pull-secret.json`
fails for all three indexes with `unable to retrieve auth token: invalid username/password`, while
`--catalog=... --package=...` works with the same `--authfile`. The `--catalogs` path seems to
ignore `--authfile` [INFER; not checked in the code]. Do not work around it with REGISTRY_AUTH_FILE,
because the embedded registry crashes.

## Dry run

ImageSetConfiguration: `imageset-operators.yaml` (operators only, no platform; the 5.0.0 release is
already mirrored). Command (via `scripts/bastion-mirror-to-mirror.sh --dry-run --namespace ocp5
--workspace ~/opmirror --cache-dir ~/opmirror-cache`, password from the registry install log through
`MIRROR_PASSWORD`, ssh `-A`):
```
oc-mirror --v2 -c imageset-operators.yaml --workspace file:///home/ec2-user/opmirror \
  docker://<registry>:8443/ocp5 --authfile <merged tmp> --cache-dir ~/opmirror-cache --dry-run
```
- Exit 0 in **41 s**. The catalog collection took about 40 s. The workspace used 1.5 GB (extracted catalog).
- `mapping.txt`: **21 lines**. That is 19 operator/bundle/operand images plus the source index and the rebuilt, filtered
  index (`127.0.0.1:55000/redhat/redhat-operator-index`). Breakdown: cert-manager 6 (operator, bundle,
  cert-manager, acmesolver, istio-csr, trust-manager), devworkspace 4, nmstate 4 (operator, bundle,
  handler, console plugin), web-terminal 4, `ubi9/ubi-minimal` 1. In m2m mode no `missing.txt` is written.
- Cluster resources generated **even in dry-run mode**, in `~/opmirror/working-dir/cluster-resources/`:
  - `cs-redhat-operator-index-v5-0.yaml`: CatalogSource `cs-redhat-operator-index-v5-0` (openshift-marketplace, grpc).
  - `cc-redhat-operator-index-v5-0.yaml`: ClusterCatalog `cc-redhat-operator-index-v5-0`
    (`olm.operatorframework.io/v1`, priority 0).
  - `idms-oc-mirror.yaml`: IDMS `idms-operator-0` mapping `registry.redhat.io/{ubi9,cert-manager,openshift5,web-terminal,devworkspace}`.
  - No ITMS ("No images by tag were mirrored").
  - Both index refs point at `<registry>:8443/ocp5/redhat/redhat-operator-index:v5.0`.
- The 5.0 operator images live under `registry.redhat.io/openshift5/...` (for example
  `openshift5/kubernetes-nmstate-rhel9-operator`), a new namespace that needs its own IDMS entry.
  oc-mirror generates it.

## Notes

- oc-mirror v2 did **not** pull in devworkspace-operator from web-terminal's dependency by itself. It is
  listed explicitly in the ISC. Without it, the web-terminal install fails offline [INFER].
- The bastion-mirror-to-mirror.sh script has no `--port` option, so oc-mirror used the default 55000
  (checked free first). Add `--port` before running it next to other oc-mirror jobs.
- On the FIPS bastion, ssh prints `sshkey_read: Ed25519 keys are not allowed in FIPS mode` (ed25519
  host keys in known_hosts). The connection still works because the stack key is RSA.
- The cluster's built-in OLM v1 ClusterCatalogs (`openshift-redhat-operators` and so on) still point at
  registry.redhat.io and fail. Apply `cc-*.yaml` and disable those (see `../squid-egress-audit/RESULTS.md`).
- The real mirror has not been run. The workspace is left at `~/opmirror` on the bastion.
