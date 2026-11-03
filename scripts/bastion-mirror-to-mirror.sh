#!/usr/bin/env bash
#
# bastion-mirror-to-mirror.sh - run ON the bastion (as ec2-user): mirror an
#                               imageset straight from Red Hat registries into
#                               the private mirror-registry (Quay) with
#                               oc-mirror v2 (mirror-to-mirror).
#
# Usage: bastion-mirror-to-mirror.sh [options] <registry-host> <imageset-config>
#
#   <registry-host>       private DNS name of the mirror-registry node (port 8443)
#   <imageset-config>     oc-mirror v2 ImageSetConfiguration (one platform channel)
#
#   --namespace NS        destination namespace in Quay (default: ocp5)
#   --workspace DIR       oc-mirror workspace (default: ~/oc-mirror/m2m)
#   --cache-dir DIR       oc-mirror cache (default: oc-mirror's own, ~/.oc-mirror)
#   --ca-file PATH        registry root CA; default: fetch it over ssh from the
#                         registry node (/opt/quay-root/quay-rootCA/rootCA.pem)
#   --ssh-user USER       ssh user on the registry node (default: ec2-user)
#   --ssh-key PATH        ssh private key for the registry node (default: ssh's own)
#   --registry-user USER  Quay user (default: init)
#   --pull-secret PATH    Red Hat pull secret (default: ~/pull-secret.json)
#   --authfile-out PATH   keep the merged authfile here (mode 600); by default it
#                         is a temp file deleted on exit
#   --log-level LEVEL     oc-mirror log level: info|debug|trace|error (default: info)
#   --dry-run             pass --dry-run to oc-mirror: write mapping.txt/missing.txt,
#                         copy nothing. It still contacts the registry, so the CA
#                         and the login are still needed and still set up.
#
# The Quay password is read from MIRROR_PASSWORD if set, otherwise prompted for.
# (Not REGISTRY_PASSWORD: oc-mirror's embedded registry parses every REGISTRY_*
# variable and crashes on unknown ones, so this script strips them for oc-mirror.)
#
# Never list a 4.x and a 5.x platform channel in one imageset (OCPBUGS-136257);
# the script refuses such a config.
#
# DRAFT - not yet run against a real bastion/registry pair.

set -euo pipefail

# --- defaults -----------------------------------------------------------------
NAMESPACE="ocp5"
WORKSPACE="${HOME}/oc-mirror/m2m"
CACHE_DIR=""
CA_FILE=""
SSH_USER="ec2-user"
SSH_KEY=""
QUAY_USER="init"
PULL_SECRET="${HOME}/pull-secret.json"
AUTHFILE_OUT=""
LOG_LEVEL="info"
DRY_RUN=0
QUAY_CA_PATH="/opt/quay-root/quay-rootCA/rootCA.pem"
PORT=8443

die()  { echo "Error: $*" >&2; exit 1; }
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "option $1 needs a value."; }

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --namespace)     need "$@"; NAMESPACE="$2"; shift 2 ;;
        --workspace)     need "$@"; WORKSPACE="$2"; shift 2 ;;
        --cache-dir)     need "$@"; CACHE_DIR="$2"; shift 2 ;;
        --ca-file)       need "$@"; CA_FILE="$2"; shift 2 ;;
        --ssh-user)      need "$@"; SSH_USER="$2"; shift 2 ;;
        --ssh-key)       need "$@"; SSH_KEY="$2"; shift 2 ;;
        --registry-user) need "$@"; QUAY_USER="$2"; shift 2 ;;
        --pull-secret)   need "$@"; PULL_SECRET="$2"; shift 2 ;;
        --authfile-out)  need "$@"; AUTHFILE_OUT="$2"; shift 2 ;;
        --log-level)     need "$@"; LOG_LEVEL="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)              echo "bastion-mirror-to-mirror.sh: unknown option '$1'" >&2; exit 2 ;;
        *)               POSITIONAL+=("$1"); shift ;;
    esac
done
[ "${#POSITIONAL[@]}" -eq 2 ] || { sed -n '8,12p' "${BASH_SOURCE[0]}" >&2; exit 2; }
REG_HOST="${POSITIONAL[0]}"
ISC="${POSITIONAL[1]}"
REG="${REG_HOST}:${PORT}"

case "$LOG_LEVEL" in info|debug|trace|error) ;; *) die "--log-level must be info, debug, trace or error." ;; esac
[[ "$NAMESPACE" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || die "invalid namespace '${NAMESPACE}'."

for cmd in oc-mirror jq curl openssl base64 timeout; do
    command -v "$cmd" >/dev/null || die "'$cmd' is not installed."
done

# --- pre-flight ---------------------------------------------------------------
echo "==> oc-mirror: $(command -v oc-mirror)"
oc-mirror version --output=json 2>/dev/null | jq -r '"    " + .clientVersion.gitVersion' \
    || echo "    (could not read the oc-mirror version)"

[ -f "$ISC" ] || die "imageset config not found: ${ISC}"
grep -qE '^kind: *ImageSetConfiguration' "$ISC" || die "${ISC} is not an ImageSetConfiguration."
grep -qE 'apiVersion: *mirror.openshift.io/v2alpha1' "$ISC" \
    || die "${ISC} is not v2alpha1; oc-mirror v1 configs do not work with --v2."
if grep -qE 'name: *(stable|candidate|fast|eus)-4\.' "$ISC" && grep -qE 'name: *(stable|candidate|fast|eus)-5\.' "$ISC"; then
    die "${ISC} lists a 4.x and a 5.x channel together; oc-mirror fails on that (OCPBUGS-136257). Split it into two runs."
fi

[ -f "$PULL_SECRET" ] || die "pull secret not found: ${PULL_SECRET}"
jq -e '.auths | length > 0' "$PULL_SECRET" >/dev/null 2>&1 || die "${PULL_SECRET} is not a pull secret (no .auths)."

echo "==> Checking ${REG} is reachable"
timeout 5 bash -c "exec 3<>/dev/tcp/${REG_HOST}/${PORT}" 2>/dev/null \
    || die "cannot connect to ${REG}. Check the registry security group allows the bastion on ${PORT}, and that Quay is running."

# --- registry CA --------------------------------------------------------------
# oc-mirror (Go) uses the system trust store, so the CA goes into ca-trust.
# /etc/containers/certs.d is for podman/skopeo only.
umask 077
TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

if [ -z "$CA_FILE" ]; then
    echo "==> Fetching the registry root CA over ssh (${SSH_USER}@${REG_HOST}:${QUAY_CA_PATH})"
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
    [ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
    CA_FILE="${TMPDIR_RUN}/rootCA.pem"
    # shellcheck disable=SC2029  # the path is meant to expand locally
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${REG_HOST}" "sudo cat ${QUAY_CA_PATH}" > "$CA_FILE" \
        || die "could not fetch ${QUAY_CA_PATH} from ${REG_HOST}. Copy it to the bastion and pass --ca-file."
fi
[ -s "$CA_FILE" ] || die "CA file is empty or missing: ${CA_FILE}"
openssl x509 -in "$CA_FILE" -noout >/dev/null 2>&1 || die "${CA_FILE} is not a PEM certificate."
echo "    $(openssl x509 -in "$CA_FILE" -noout -subject -enddate | paste -sd' ')"

ANCHOR="/etc/pki/ca-trust/source/anchors/mirror-registry-${REG_HOST}.pem"
if [ -f "$ANCHOR" ] && cmp -s "$CA_FILE" "$ANCHOR"; then
    echo "==> Registry CA already trusted (${ANCHOR})"
else
    echo "==> Adding the registry CA to the system trust store (sudo)"
    sudo install -m 0644 "$CA_FILE" "$ANCHOR"
    sudo update-ca-trust extract
fi
sudo mkdir -p "/etc/containers/certs.d/${REG}"
sudo install -m 0644 "$CA_FILE" "/etc/containers/certs.d/${REG}/ca.crt"

curl -fsS -o /dev/null "https://${REG}/health/instance" \
    || die "TLS to https://${REG} fails even with the CA trusted. Does the certificate's SAN include ${REG_HOST}?"

# --- credentials --------------------------------------------------------------
if [ -n "${MIRROR_PASSWORD:-}" ]; then
    QUAY_PASS="$MIRROR_PASSWORD"
else
    read -r -s -p "Password for ${QUAY_USER}@${REG}: " QUAY_PASS; echo
fi
unset MIRROR_PASSWORD
[ -n "$QUAY_PASS" ] || die "empty registry password."

echo "==> Checking the ${QUAY_USER} credentials against ${REG}"
# Credentials go to curl on stdin (-K -), not argv, so they are not visible in ps.
http_code="$(printf 'user = "%s:%s"\n' "$QUAY_USER" "$QUAY_PASS" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' "https://${REG}/v2/auth?service=${REG}&scope=repository:${NAMESPACE}/probe:pull")" || true
[ "$http_code" = "200" ] || die "login to ${REG} as ${QUAY_USER} failed (HTTP ${http_code:-none})."

MERGED="${TMPDIR_RUN}/auth.json"
printf '%s:%s' "$QUAY_USER" "$QUAY_PASS" | base64 -w0 \
    | jq --rawfile a /dev/stdin --arg reg "$REG" '.auths[$reg] = {auth: ($a | rtrimstr("\n"))}' "$PULL_SECRET" > "$MERGED"
unset QUAY_PASS
echo "    merged authfile: $(jq -r '.auths | keys | join(", ")' "$MERGED")"
if [ -n "$AUTHFILE_OUT" ]; then
    install -m 0600 "$MERGED" "$AUTHFILE_OUT"
    echo "    kept a copy at ${AUTHFILE_OUT} (mode 600)"
fi

# --- disk ---------------------------------------------------------------------
mkdir -p "$WORKSPACE"
avail_gb="$(df -BG --output=avail "$WORKSPACE" | tail -1 | tr -dc '0-9')"
echo "==> ${avail_gb} GB free under ${WORKSPACE}"
# TODO: measure m2m disk use. Observed for mirror-to-disk, 5.0.0 platform only
# (2026-11-03): 23 GB cache + 24 GB archive. m2m should write no archive (unverified).
[ "$avail_gb" -ge 60 ] || echo "    Warning: less than 60 GB free; a platform mirror may not fit."

# --- oc-mirror ----------------------------------------------------------------
ARGS=(--v2 -c "$ISC" --workspace "file://${WORKSPACE}" "docker://${REG}/${NAMESPACE}"
      --authfile "$MERGED" --log-level "$LOG_LEVEL")
[ -n "$CACHE_DIR" ] && ARGS+=(--cache-dir "$CACHE_DIR")
[ "$DRY_RUN" -eq 1 ] && ARGS+=(--dry-run)

# Strip REGISTRY_* from oc-mirror's environment (see the header).
UNSET=()
while IFS= read -r v; do UNSET+=(-u "$v"); done < <(compgen -e | grep '^REGISTRY_' || true)

# umask 077 above protects the authfile; oc-mirror itself warns unless it is 022.
umask 022

echo "==> oc-mirror ${ARGS[*]}"
start="$(date +%s)"
rc=0
env ${UNSET[@]+"${UNSET[@]}"} oc-mirror "${ARGS[@]}" || rc=$?
echo "==> oc-mirror exited ${rc} after $(( $(date +%s) - start )) s"

# --- results ------------------------------------------------------------------
WD="${WORKSPACE}/working-dir"
if [ "$DRY_RUN" -eq 1 ]; then
    for f in mapping.txt missing.txt; do
        [ -f "${WD}/dry-run/${f}" ] && printf '    %-12s %6s images  %s\n' "$f" "$(wc -l < "${WD}/dry-run/${f}")" "${WD}/dry-run/${f}"
    done
else
    echo "==> Cluster resources (apply after install, or put the IDMS/ITMS content into install-config imageDigestSources):"
    if [ -d "${WD}/cluster-resources" ]; then
        find "${WD}/cluster-resources" -maxdepth 1 -type f -printf '    %f\n' | sort
        echo "    in ${WD}/cluster-resources/"
        echo "    idms-oc-mirror.yaml / itms-oc-mirror.yaml   ImageDigestMirrorSet / ImageTagMirrorSet"
        echo "    cs-*.yaml / cc-*.yaml                       CatalogSource / ClusterCatalog (operators only)"
        echo "    signature-configmap.{json,yaml}             release signatures (openshift-config-managed)"
        echo "    updateService.yaml                          OSUS UpdateService (graph: true only)"
    else
        echo "    none found in ${WD}/cluster-resources (see the oc-mirror log under ${WD}/logs/)" >&2
    fi
fi
exit "$rc"
