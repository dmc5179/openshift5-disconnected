#!/usr/bin/env bash
#
# 35-enable-fips-host.sh - put the install host (bastion or registry node) into
#                          FIPS mode, so openshift-install-fips can install a
#                          cluster with fips: true.
#
# Usage: scripts/35-enable-fips-host.sh <bastion|registry>
#
# RHEL 9: `fips-mode-setup --enable`, reboot, verify /proc/sys/crypto/fips_enabled
# and the FIPS crypto policy. Idempotent: does nothing if FIPS is already on.
#
# RHEL 10: refuses. fips-mode-setup is removed and switching to FIPS after
# installation is unsupported; the host must be installed in FIPS mode (fips=1
# at first boot), which the stack does not do yet (AGENTS.md B-8).
#
# Rebooting the registry node restarts Quay (its systemd units come back on
# boot); the bastion is the usual choice.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
case "$TARGET" in bastion|registry) ;; *) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 2 ;; esac
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"
stack_ready
run() { if [ "$TARGET" = "bastion" ]; then bastion_ssh "$@"; else registry_ssh "$@"; fi; }

ver="$(run '. /etc/os-release; echo $VERSION_ID')"
state="$(run 'cat /proc/sys/crypto/fips_enabled')"
echo "==> ${TARGET}: RHEL ${ver}, fips_enabled=${state}"
if [ "$state" = "1" ]; then
    echo "    already in FIPS mode; policy: $(run 'update-crypto-policies --show')"
    exit 0
fi
case "$ver" in
    9*) ;;
    *) echo "Error: RHEL ${ver}: FIPS can only be enabled at installation (fips=1); fips-mode-setup is removed in RHEL 10." >&2
       exit 1 ;;
esac

echo "==> fips-mode-setup --enable (regenerates the initramfs, sets fips=1 on the kernel command line)"
run 'sudo fips-mode-setup --enable 2>&1 | tail -3'
echo "==> Rebooting ${TARGET}"
run 'sudo systemctl reboot' || true
# In FIPS mode sshd stops offering its ED25519 host key and presents ECDSA, so the
# recorded key "changes". Expected here: drop the old entry and re-accept.
host="$([ "$TARGET" = "bastion" ] && echo "$BASTION_IP" || echo "$REGISTRY_HOST")"
ssh-keygen -R "$host" -f "${HOME}/.ssh/known_hosts.${VPC_STACK_NAME}" >/dev/null 2>&1 || true
sleep 20
for _ in $(seq 1 40); do
    if s="$(run 'cat /proc/sys/crypto/fips_enabled' 2>/dev/null)"; then break; fi
    sleep 10
done
[ "${s:-}" = "1" ] || { echo "Error: ${TARGET} did not come back in FIPS mode (fips_enabled=${s:-unreachable})." >&2; exit 1; }
echo "==> ${TARGET} is in FIPS mode: $(run 'fips-mode-setup --check 2>&1 | tail -1'); policy $(run 'update-crypto-policies --show')"
if [ "$TARGET" = "registry" ]; then
    # After a reboot quay-app starts before quay-pod exists, fails once and is restarted
    # by systemd ~30 s later; Quay then needs about a minute (observed 3.5 min in total
    # on a FIPS RHEL 9 node). Wait for the health check instead of reporting a failure.
    echo "==> Waiting for Quay after the reboot (up to 10 min)"
    q="$(run 'for i in $(seq 1 60); do c=$(curl -sk -o /dev/null -w %{http_code} https://$(hostname -f):8443/health/instance); [ "$c" = 200 ] && break; sleep 10; done; echo $c')"
    [ "$q" = "200" ] || { echo "Error: Quay health is ${q} 10 min after the reboot." >&2; exit 1; }
    echo "    Quay health 200; podman: $(run 'sudo podman ps --format "{{.Names}}" | tr "\n" " "')"
else
    run 'sudo podman run --rm registry.access.redhat.com/ubi9/ubi-minimal true >/dev/null 2>&1 && echo "    podman works after the reboot" || echo "    WARNING: podman fails after the reboot (CF-22?)"'
fi
