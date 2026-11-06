#!/usr/bin/env bash
#
# fapolicyd-trust-tools.sh - trust the non-RPM OpenShift disconnected tooling
#                            in fapolicyd (AGENTS.md B-5).
#
# Writes /etc/fapolicyd/trust.d/<TRUST_FILE> with one entry (path, size,
# SHA-256) per file found in the tool locations, then reloads the trust
# database. Run it as root after installing or upgrading any of the tools.
# Tested on RHEL 9.8 (FIPS) and RHEL 10.2, fapolicyd 1.4.5 (RESULTS.md).
#
# Upgrades: with the default "integrity = none" in fapolicyd.conf the entry is
# matched by PATH only, so a replaced binary keeps running (tested). With
# "integrity = sha256" (recommended, and what hardened images set) a replaced
# binary is denied until this script runs again (tested). Run it after every
# tool upgrade either way.
#
# Usage: fapolicyd-trust-tools.sh [--check] [extra paths...]
#   --check   only report files that would be denied (untrusted or stale)
#
# Covered by default (the locations the CloudFormation user data uses):
#   /usr/local/bin/{oc,kubectl,openshift-install,openshift-install-fips,oc-mirror,ccoctl}
#   /usr/local/aws-cli/            AWS CLI v2 (bundled python and .so files)
#   <MIRROR_REGISTRY_DIR>/mirror-registry   (the installer binary; default /root
#                                  and /home/ec2-user, override with the variable,
#                                  e.g. MIRROR_REGISTRY_DIR=/opt/mr)
# Directories are hashed recursively; fapolicyd-cli accepts a directory and adds
# every regular file in it.
#
# Not needed here: podman, crun, conmon, skopeo, ssh and systemd are RPM-trusted,
# and container image content (overlay) is not on a watched file system. Rootful
# podman still needs the rule in 25-ocp-disconnected-crun.rules.

set -euo pipefail

TRUST_FILE="${TRUST_FILE:-90-ocp-disconnected}"
TRUST_PATH="/etc/fapolicyd/trust.d/${TRUST_FILE}"
CHECK=0
EXTRA=()
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) EXTRA+=("$a") ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
command -v fapolicyd-cli >/dev/null || { echo "fapolicyd is not installed." >&2; exit 1; }

CANDIDATES=(
    /usr/local/bin/oc /usr/local/bin/kubectl
    /usr/local/bin/openshift-install /usr/local/bin/openshift-install-fips
    /usr/local/bin/oc-mirror /usr/local/bin/ccoctl
    /usr/local/aws-cli
)
for d in ${MIRROR_REGISTRY_DIR:-/root /home/ec2-user}; do
    CANDIDATES+=("${d}/mirror-registry")
done
CANDIDATES+=(${EXTRA[@]+"${EXTRA[@]}"})

# Resolve symlinks (openshift-install -> openshift-install-fips, aws -> v2/current/...):
# fapolicyd decides on the real file.
PATHS=()
for p in "${CANDIDATES[@]}"; do
    [ -e "$p" ] || continue
    r="$(readlink -f "$p")"
    [ -f "$r" ] || [ -d "$r" ] || continue
    PATHS+=("$r")
done
[ ${#PATHS[@]} -gt 0 ] || { echo "No tool paths found." >&2; exit 0; }
# openshift-install is a symlink to openshift-install-fips: de-duplicate, because
# fapolicyd-cli --file add exits 9 ("nothing to add") on a path it already has.
mapfile -t PATHS < <(printf '%s\n' "${PATHS[@]}" | sort -u)

if [ "$CHECK" = 1 ]; then
    # --check-path-trust is not available on every build; compare against the trust file.
    bad=0
    while IFS= read -r -d '' f; do
        sum="$(sha256sum "$f" | awk '{print $1}')"
        if ! grep -qF " ${sum}" "$TRUST_PATH" 2>/dev/null && ! grep -q "^${f} " "$TRUST_PATH" 2>/dev/null; then
            echo "UNTRUSTED  $f"; bad=1
        elif ! grep -qF "${f} $(stat -c %s "$f") ${sum}" "$TRUST_PATH"; then
            echo "STALE      $f (content changed since it was trusted)"; bad=1
        fi
    done < <(find "${PATHS[@]}" -xdev -type f -print0 2>/dev/null)
    [ "$bad" = 0 ] && echo "All tool files are trusted in ${TRUST_PATH}."
    exit "$bad"
fi

# Rebuild the file from scratch so removed or upgraded binaries leave no stale lines.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
rm -f "$TRUST_PATH"
for p in "${PATHS[@]}"; do
    rc=0
    fapolicyd-cli --file add "$p" --trust-file "$TRUST_FILE" >/dev/null 2>"$tmp" || rc=$?
    # 9 = every file already listed (for example in another trust file): not an error here.
    if [ "$rc" != 0 ] && [ "$rc" != 9 ]; then
        echo "fapolicyd-cli --file add $p failed (rc=$rc):" >&2; cat "$tmp" >&2; exit 1
    fi
done
chmod 644 "$TRUST_PATH"
restorecon "$TRUST_PATH" 2>/dev/null || true
fapolicyd-cli --update
echo "$(wc -l < "$TRUST_PATH") entries in ${TRUST_PATH}"
