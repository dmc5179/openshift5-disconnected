#!/usr/bin/env bash
#
# generate-imageset-config.sh - render an oc-mirror v2 ImageSetConfiguration
#                               for the OpenShift 5 release in cluster.env.
#
# Usage: scripts/generate-imageset-config.sh [-o <output file>]
#
# From cluster.env:
#   OCP_CHANNEL, OCP_VERSION     platform channel and target release
#   OCP_UPGRADE_FROM             optional 4.22.z start of an upgrade path
#   MIRROR_OPERATORS             "pkg" or "pkg:channel", comma-separated
#   MIRROR_ADDITIONAL_IMAGES     fully qualified images, comma-separated
#   MIRROR_GRAPH                 build the OSUS graph-data image
#   MIRROR_KUBEVIRT              true: mirror.platform.kubeVirtContainer (RHCOS
#                                KubeVirt boot image, for HCP on OpenShift Virtualization)
#
# ONE platform channel only, always. An upgrade start version goes into the 5.x
# channel as minVersion with shortestPath. Listing a 4.x and a 5.x channel
# together makes oc-mirror fail (OCPBUGS-136257); clusters below 4.22 need a
# separate imageset config and a separate oc-mirror run.
#
# Run it with oc-mirror v2 (async download from pub/cgw/oc-mirror/ in 5.x):
#   oc-mirror --v2 -c imageset-config.yaml file://<dir>            # mirror to disk, bastion
#   oc-mirror --v2 -c imageset-config.yaml --from file://<dir> \
#       docker://<registry>:8443/<MIRROR_NAMESPACE>                 # disk to mirror, registry node

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${ROOT}/imageset-config.yaml"

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)   sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "generate-imageset-config.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"

for cmd in yq jq; do
    command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is not installed." >&2; exit 1; }
done
yq --version 2>&1 | grep -q 'mikefarah/yq.* v4\.' \
    || { echo "Error: needs Go yq v4 (dnf install yq)." >&2; exit 1; }

# candidate-5.0 -> 5.0 -> catalog tag v5.0
CH_VER="${OCP_CHANNEL##*-}"
[[ "$CH_VER" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "Error: cannot parse a version from OCP_CHANNEL='${OCP_CHANNEL}'." >&2; exit 1; }
[[ "$OCP_VERSION" == "${CH_VER}."* ]] || echo "    Warning: OCP_VERSION ${OCP_VERSION} is not in channel ${OCP_CHANNEL}."
CATALOG="registry.redhat.io/redhat/redhat-operator-index:v${CH_VER}"

MIN="$OCP_VERSION"
if [ -n "$OCP_UPGRADE_FROM" ]; then
    [[ "$OCP_UPGRADE_FROM" == 4.22.* ]] || {
        echo "Error: OCP_UPGRADE_FROM=${OCP_UPGRADE_FROM}: only 4.22.z can share the 5.x channel." >&2
        echo "       Mirror the 4.x hops (e.g. stable-4.20 + stable-4.22) with a separate imageset and run;" >&2
        echo "       combining 4.x and 5.x channels fails (OCPBUGS-136257)." >&2
        exit 1; }
    MIN="$OCP_UPGRADE_FROM"
fi

# "pkg[:channel],..." -> [{"name":pkg, "channels":[{"name":channel}]}]
PKGS_JSON="$(printf '%s\n' "${MIRROR_OPERATORS:-}" | jq -R -c '
    split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) |
    map(split(":") as $p | {name: $p[0]} + (if ($p|length) > 1 then {channels: [{name: $p[1]}]} else {} end))')"
IMGS_JSON="$(printf '%s\n' "${MIRROR_ADDITIONAL_IMAGES:-}" | jq -R -c '
    split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map({name: .})')"

if printf '%s' "$PKGS_JSON" | jq -e 'map(.name) | index("lightspeed-operator")' >/dev/null; then
    echo "    Note: lightspeed-operator is listed. Mirroring it makes the OpenShift Lightspeed AI features installable."
fi

cat > "$OUTPUT_FILE" <<'EOF'
# oc-mirror v2 ImageSetConfiguration, rendered by scripts/generate-imageset-config.sh
# from cluster.env. Do not edit by hand; change cluster.env and re-render.
#
# One platform channel only (OCPBUGS-136257: 4.x + 5.x channels together fail).
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels: []
    graph: true
  operators: []
  additionalImages: []
EOF

case "${MIRROR_KUBEVIRT:-false}" in
    true|false) ;;
    *) echo "Error: MIRROR_KUBEVIRT must be true or false (got '${MIRROR_KUBEVIRT}')." >&2; exit 1 ;;
esac

V_CH="$OCP_CHANNEL" V_MIN="$MIN" V_MAX="$OCP_VERSION" V_GRAPH="$MIRROR_GRAPH" V_KUBEVIRT="${MIRROR_KUBEVIRT:-false}" \
V_OPS="$(jq -n -c --arg cat "$CATALOG" --argjson p "$PKGS_JSON" 'if ($p|length) > 0 then [{catalog: $cat, packages: $p}] else [] end')" \
V_IMGS="$IMGS_JSON" \
yq -i '
      .mirror.platform.channels = [{"name": strenv(V_CH), "type": "ocp",
                                    "minVersion": strenv(V_MIN), "maxVersion": strenv(V_MAX),
                                    "shortestPath": true}]
    | .mirror.platform.graph = env(V_GRAPH)
    | (select(strenv(V_KUBEVIRT) == "true") | .mirror.platform.kubeVirtContainer) = true
    | .mirror.operators = env(V_OPS)
    | .mirror.additionalImages = env(V_IMGS)
    | ... style=""' \
    "$OUTPUT_FILE"

# Drop empty sections so oc-mirror does not see "operators: []".
yq -i 'del(.mirror.operators | select(length == 0)) | del(.mirror.additionalImages | select(length == 0))' "$OUTPUT_FILE"

echo "==> Wrote ${OUTPUT_FILE}"
echo "    channel=${OCP_CHANNEL} ${MIN} -> ${OCP_VERSION}  catalog=${CATALOG}"
echo "    kubeVirtContainer=${MIRROR_KUBEVIRT:-false}"
echo "    operators=$(printf '%s' "$PKGS_JSON" | jq -r 'map(.name) | join(",") | if .=="" then "(none)" else . end')"
