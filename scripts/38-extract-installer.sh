#!/usr/bin/env bash
#
# 38-extract-installer.sh - extract openshift-install-fips (and oc) from the
#                           release payload in the mirror registry, on the
#                           install host, without internet access (I1, F1).
#
# Usage: INSTALL_HOST=registry|bastion|rhel10 scripts/38-extract-installer.sh
#
# Runs `oc adm release extract --command=openshift-install-fips` on the install
# host against <mirror>/<namespace>/openshift/release-images:<OCP_VERSION>-x86_64,
# with an IDMS file built from install-config.yaml imageDigestSources, so the
# payload's quay.io references resolve to the mirror. The binary lands in
# ~/bin-mirror/openshift-install-fips; use it with
#   INSTALLER_BIN='~/bin-mirror/openshift-install-fips' scripts/40-install-cluster.sh start   (quoted: ~ must expand on the install host)
# The extracted installer is pinned to the mirrored release and takes the RHCOS
# boot image references from that payload (machine-os-images), not from the
# installer binary built into the CLI tarball.
#
# Needs install-config.yaml (generate-install-config.sh) and the mirror pull
# secret (INSTALL_PULL_SECRET_FILE). Both are copied mode 600 and removed after.
# Needs `oc` on the install host's PATH. INSTALL_HOST=rhel10 (private RHEL 10
# FIPS host, home /var/home/cloud-user): run `scripts/16-rhel10-host.sh --private
# prep` first, which copies the bastion's oc there (no internet, no dnf repos).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"
stack_ready

IC="${ROOT}/install-config.yaml"
[ -f "$IC" ] || { echo "Error: ${IC} not found; run scripts/generate-install-config.sh." >&2; exit 1; }
[ -f "$INSTALL_PULL_SECRET_FILE" ] || { echo "Error: ${INSTALL_PULL_SECRET_FILE} not found; run scripts/30-fetch-mirror-credentials.sh." >&2; exit 1; }

release_mirror="$(yq -r '.imageDigestSources[] | select(.source == "quay.io/openshift-release-dev/ocp-release") | .mirrors[0]' "$IC")"
[ -n "$release_mirror" ] || { echo "Error: no ocp-release mirror in ${IC} imageDigestSources." >&2; exit 1; }
REF="${release_mirror}:${INSTALL_VERSION:-$OCP_VERSION}-x86_64"   # INSTALL_VERSION: the upgrade test installs 4.22.z

# IDMS for oc, from imageDigestSources.
IDMS="$(mktemp)"; trap 'rm -f "$IDMS"' EXIT
yq '{"apiVersion": "config.openshift.io/v1", "kind": "ImageDigestMirrorSet",
     "metadata": {"name": "install-mirrors"},
     "spec": {"imageDigestMirrors": .imageDigestSources}}' "$IC" > "$IDMS"

echo "==> Install host: ${INSTALL_HOST:-registry} ($(install_host_name))"
echo "    release in mirror: ${REF}"
install_ssh "command -v oc >/dev/null" \
    || { echo "Error: no oc on the install host's PATH (INSTALL_HOST=rhel10: scripts/16-rhel10-host.sh --private prep)." >&2; exit 1; }
install_ssh "umask 077; mkdir -p ~/bin-mirror ~/.extract-tmp"
install_scp "$INSTALL_PULL_SECRET_FILE" ".extract-tmp/auth.json"
install_scp "$IDMS" ".extract-tmp/idms.yaml"
install_scp "$MIRROR_CA_FILE" ".extract-tmp/ca.pem"

install_ssh "set -e; cd ~/.extract-tmp
    echo \"    egress check (expect blocked on a private-subnet host): quay.io \$(curl -s -m 5 -o /dev/null -w %{http_code} https://quay.io/v2/ || echo blocked)\"
    oc adm release info --idms-file idms.yaml -a auth.json --certificate-authority ca.pem '${REF}' 2>&1 | sed -n '1,6p' | sed 's/^/    /'
    for c in openshift-install-fips oc; do
        oc adm release extract --idms-file idms.yaml -a auth.json --certificate-authority ca.pem \
            --command=\$c --to ~/bin-mirror '${REF}'
    done
    ls -l ~/bin-mirror | sed 's/^/    /'
    ~/bin-mirror/openshift-install-fips version | head -3 | sed 's/^/    /'
    # go is not installed on every host (not on the RHEL 10 image): optional.
    go version -m ~/bin-mirror/openshift-install-fips 2>/dev/null | grep -E 'CGO_ENABLED|GOEXPERIMENT' | sed 's/^/    /' || true"
install_ssh "rm -rf ~/.extract-tmp"
echo "==> Use it with: INSTALL_HOST=${INSTALL_HOST:-registry} INSTALLER_BIN='~/bin-mirror/openshift-install-fips' scripts/40-install-cluster.sh start"
