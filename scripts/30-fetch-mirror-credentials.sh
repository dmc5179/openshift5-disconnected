#!/usr/bin/env bash
#
# 30-fetch-mirror-credentials.sh - fetch the mirror registry's root CA and
#                                  credentials, and build the cluster pull secret.
#
# Usage: scripts/30-fetch-mirror-credentials.sh
#
# Reaches the registry node through the bastion (stack outputs, SSH_PRIVATE_KEY)
# and writes, mode 600, all gitignored:
#   secrets/mirror-rootCA.pem          mirror-registry root CA (MIRROR_CA_FILE)
#   secrets/pull-secret-mirror.json    INSTALL_PULL_SECRET_FILE: PULL_SECRET_FILE
#                                      plus the mirror registry's credentials, minus
#                                      cloud.openshift.com (no telemetry from a
#                                      disconnected cluster)
#
# The registry password is read from mirror-registry's install log on the node
# and never printed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"

stack_ready
REG="${REGISTRY_HOST}:${MIRROR_REGISTRY_PORT}"
umask 077

echo "==> Fetching the registry root CA from ${REGISTRY_HOST}"
registry_ssh 'sudo cat /opt/quay-root/quay-rootCA/rootCA.pem' > "${MIRROR_CA_FILE}.tmp"
grep -q 'BEGIN CERTIFICATE' "${MIRROR_CA_FILE}.tmp" || { rm -f "${MIRROR_CA_FILE}.tmp"; echo "Error: no CA on the registry node." >&2; exit 1; }
mv "${MIRROR_CA_FILE}.tmp" "$MIRROR_CA_FILE"

echo "==> Reading the registry credentials (not printed)"
# Install logs: the template's first attempt (/tmp) or a manual re-run (/opt/mirror-registry-install).
pass="$(registry_ssh "sudo sh -c 'cat /opt/mirror-registry-install/install.log /tmp/mirror-registry-install.log 2>/dev/null' | grep -oP 'credentials \(init, \K[^)]+' | tail -1")"
[ -n "$pass" ] || { echo "Error: no 'credentials (init, ...)' line in the mirror-registry install logs." >&2; exit 1; }

auth="$(printf 'init:%s' "$pass" | base64 -w0)"
unset pass
jq --arg reg "$REG" --arg a "$auth" '.auths[$reg] = {auth: $a} | del(.auths["cloud.openshift.com"])' \
    "$PULL_SECRET_FILE" > "${INSTALL_PULL_SECRET_FILE}.tmp"
mv "${INSTALL_PULL_SECRET_FILE}.tmp" "$INSTALL_PULL_SECRET_FILE"
unset auth

echo "    ${MIRROR_CA_FILE}"
echo "    ${INSTALL_PULL_SECRET_FILE}: $(jq -r '.auths | keys | join(", ")' "$INSTALL_PULL_SECRET_FILE")"
