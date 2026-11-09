#!/usr/bin/env bash
#
# 20-prepare-sts.sh - set up AWS STS (short-lived credentials) for the cluster's
#                     operators with ccoctl, before the install.
#
# Usage: scripts/20-prepare-sts.sh [--dry-run] [--force-download] [--upgrade-to VERSION]
#
#   --dry-run          extract the CredentialsRequests and run ccoctl with
#                      --dry-run: write the IAM/OIDC JSON it would create into
#                      clusters/<name>/ccoctl, create nothing in AWS
#   --force-download   re-fetch bin/ccoctl and bin/oc even if present
#   --upgrade-to V     before a minor upgrade of a Manual-mode cluster: extract the
#                      CredentialsRequests of release V, and create the roles they
#                      need against the EXISTING OIDC provider (ccoctl aws
#                      create-iam-roles). Writes clusters/<name>/ccoctl-<V>/manifests
#                      (Secrets to apply with oc) and uses bin/<V>/ for the tools.
#                      Then: oc annotate cloudcredential.operator.openshift.io/cluster
#                      cloudcredential.openshift.io/upgradeable-to=<V> --overwrite
#
# Release: INSTALL_VERSION (cluster.env; default OCP_VERSION), or V with --upgrade-to.
#
# Needs install-config.yaml rendered with credentialsMode: Manual
# (scripts/generate-install-config.sh). Run it on a connected host (it reads the
# release image from quay.io); the result is copied to the install host.
#
# Steps:
#   1. fetch the release-matched ccoctl and oc (rhel9 builds) into bin/, sha256-checked
#   2. oc adm release extract --credentials-requests --included  (only the
#      requests for the capabilities enabled in install-config.yaml)
#   3. ccoctl aws create-all: IAM OIDC provider, S3 bucket with the discovery
#      documents, one IAM role per CredentialsRequest; writes manifests/ and tls/
#
# After `openshift-install create manifests --dir <install dir>`, copy
#   clusters/<name>/ccoctl/manifests/*  ->  <install dir>/manifests/
#   clusters/<name>/ccoctl/tls          ->  <install dir>/tls
# Remove the AWS resources after the cluster is destroyed:
#   bin/ccoctl aws delete --name <CCOCTL_NAME> --region <region>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")
DRY_RUN=0
FORCE_DL=0
UPGRADE_TO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY_RUN=1; shift ;;
        --force-download) FORCE_DL=1; shift ;;
        --upgrade-to)     UPGRADE_TO="$2"; shift 2 ;;
        -h|--help)        sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "20-prepare-sts.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "prepare-sts" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
REGION="${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION must be set in secrets/aws.env}"

IC="${ROOT}/install-config.yaml"
[ -f "$IC" ] || { echo "Error: ${IC} not found; run scripts/generate-install-config.sh first." >&2; exit 1; }
mode="$(yq -r '.credentialsMode' "$IC")"
[ "$mode" = "Manual" ] || { echo "Error: install-config.yaml has credentialsMode '${mode}'; STS needs Manual (CREDENTIALS_MODE in cluster.env)." >&2; exit 1; }
[ -f "$PULL_SECRET_FILE" ] || { echo "Error: pull secret not found: ${PULL_SECRET_FILE}" >&2; exit 1; }

# --- 1. release-matched tools -----------------------------------------------------
STS_VERSION="${UPGRADE_TO:-${INSTALL_VERSION:-$OCP_VERSION}}"
BIN="${ROOT}/bin${UPGRADE_TO:+/${UPGRADE_TO}}"
MIRROR="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${STS_VERSION}"
mkdir -p "$BIN"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch_tool() {   # <tarball> <binary>
    local tarball="$1" binary="$2"
    if [ "$FORCE_DL" -eq 0 ] && [ -x "${BIN}/${binary}" ] && [ -f "${BIN}/.${binary}.version" ] \
       && [ "$(cat "${BIN}/.${binary}.version")" = "$STS_VERSION" ]; then
        echo "==> ${binary} ${STS_VERSION} already in ${BIN#"${ROOT}/"}/"
        return 0
    fi
    echo "==> Downloading ${tarball}"
    [ -f "${WORK}/sha256sum.txt" ] || curl -fsSL -o "${WORK}/sha256sum.txt" "${MIRROR}/sha256sum.txt"
    curl -fSL --retry 3 -o "${WORK}/${tarball}" "${MIRROR}/${tarball}"
    local expected actual
    expected="$(awk -v f="$tarball" '$2 == f {print $1}' "${WORK}/sha256sum.txt")"
    actual="$(sha256sum "${WORK}/${tarball}" | awk '{print $1}')"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "Error: sha256 mismatch for ${tarball}" >&2; exit 1; }
    mkdir -p "${WORK}/x-${binary}"
    tar -xzf "${WORK}/${tarball}" -C "${WORK}/x-${binary}"
    install -m 0755 "${WORK}/x-${binary}/${binary}" "${BIN}/${binary}"
    echo "$STS_VERSION" > "${BIN}/.${binary}.version"
    echo "    installed bin/${binary}"
}
# RHEL 9 builds: the mirror publishes no rhel10 variants yet (AGENTS.md B-2).
fetch_tool "ccoctl-linux-rhel9-${STS_VERSION}.tar.gz" ccoctl
fetch_tool "openshift-client-linux-amd64-rhel9-${STS_VERSION}.tar.gz" oc

# --- 2. CredentialsRequests -----------------------------------------------------------
RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:${STS_VERSION}-x86_64"
CR_DIR="${CLUSTER_DIR}/credrequests${UPGRADE_TO:+-${UPGRADE_TO}}"
OUT_DIR="${CLUSTER_DIR}/ccoctl${UPGRADE_TO:+-${UPGRADE_TO}}"
rm -rf "$CR_DIR"; mkdir -p "$CR_DIR"
echo "==> Extracting CredentialsRequests from ${RELEASE_IMAGE} (enabled capabilities only)"
"${BIN}/oc" adm release extract --registry-config "$PULL_SECRET_FILE" \
    --credentials-requests --included --install-config "$IC" \
    --to "$CR_DIR" "$RELEASE_IMAGE"
echo "    $(find "$CR_DIR" -name '*.yaml' | wc -l) CredentialsRequests:"
grep -h '^  name:' "$CR_DIR"/*.yaml 2>/dev/null | awk '{print "      " $2}' | sort -u

# --- 3. ccoctl ------------------------------------------------------------------------
if [ -n "$UPGRADE_TO" ]; then
    # Upgrade: reuse the cluster's OIDC provider; create/update one role per request.
    idp="$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text | tr '\t' '\n' | grep -m1 "/${CCOCTL_NAME}-oidc" || true)"
    [ -n "$idp" ] || { echo "Error: no OIDC provider for ${CCOCTL_NAME}; was the cluster installed with this script?" >&2; exit 1; }
    ARGS=(aws create-iam-roles --name "$CCOCTL_NAME" --region "$REGION"
          --credentials-requests-dir "$CR_DIR" --identity-provider-arn "$idp" --output-dir "$OUT_DIR")
    [ "$DRY_RUN" -eq 1 ] && ARGS+=(--dry-run)
    rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
    echo "==> ccoctl ${ARGS[*]}"
    "${BIN}/ccoctl" "${ARGS[@]}"
    echo "==> Apply before upgrading to ${UPGRADE_TO}:"
    echo "    oc apply -f ${OUT_DIR}/manifests/"
    echo "    oc annotate cloudcredential.operator.openshift.io/cluster cloudcredential.openshift.io/upgradeable-to=${UPGRADE_TO} --overwrite"
    exit 0
fi
ARGS=(aws create-all --name "$CCOCTL_NAME" --region "$REGION"
      --credentials-requests-dir "$CR_DIR" --output-dir "$OUT_DIR")
[ "$CCOCTL_PRIVATE_BUCKET" = "true" ] && ARGS+=(--create-private-s3-bucket)
[ "$DRY_RUN" -eq 1 ] && ARGS+=(--dry-run)

if [ "$DRY_RUN" -eq 0 ] && aws iam list-open-id-connect-providers --output text | grep -q "${CCOCTL_NAME}-oidc"; then
    echo "Error: an OIDC provider for ${CCOCTL_NAME} already exists. Reuse ${OUT_DIR}, or remove it with:" >&2
    echo "       ${BIN}/ccoctl aws delete --name ${CCOCTL_NAME} --region ${REGION}" >&2
    exit 1
fi

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
echo "==> ccoctl ${ARGS[*]}"
"${BIN}/ccoctl" "${ARGS[@]}"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> [dry-run] nothing created in AWS. Planned resources (JSON) in ${OUT_DIR}:"
    find "$OUT_DIR" -maxdepth 1 -type f -printf '    %f\n' | sort | head -40
else
    echo "==> STS resources created. Copy into the install directory after 'create manifests':"
    echo "    ${OUT_DIR}/manifests/*  ->  <install dir>/manifests/"
    echo "    ${OUT_DIR}/tls          ->  <install dir>/tls"
    find "$OUT_DIR/manifests" -maxdepth 1 -type f -printf '    %f\n' 2>/dev/null | sort
fi
