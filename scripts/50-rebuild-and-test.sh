#!/usr/bin/env bash
#
# 50-rebuild-and-test.sh - tear down and rebuild the whole environment, then run
#                          the end-to-end disconnected test sequence unattended.
#
# Usage: scripts/50-rebuild-and-test.sh [--from PHASE] [--only PHASE] [--yes]
#
# Phases (in order):
#   teardown     destroy the cluster (from the host that installed it), delete the
#                ccoctl STS resources, delete the stack (and non-stack instances)
#   deploy       scripts/10-deploy-vpc.sh
#   validate     template checks: IMDSv2 enforced on every host, scoped S3 access,
#                Squid allowlist and SNI log, iptables + squid survive a reboot
#   mirror       bastion mirror-to-mirror: OCP_CHANNEL with the upgrade path from
#                MIRROR_UPGRADE_FROM, graph data, MIRROR_TEST_OPERATORS
#   creds        scripts/30-fetch-mirror-credentials.sh (CA + mirror pull secret)
#   fipshost     put the install host (TEST_INSTALL_HOST) into FIPS mode
#   sts          scripts/20-prepare-sts.sh
#   config       scripts/generate-install-config.sh (FIPS, DISABLE_SAMPLES, day 0)
#   extract      scripts/38-extract-installer.sh: openshift-install-fips from the mirror
#   install      install with the extracted installer, wait for completion
#   post         scripts/45-post-install.sh all
#   audit        Squid egress summary for the run
#
# Every phase logs to logs/50-<phase>-<time>.log. Stops at the first failure;
# rerun with --from <phase> after fixing it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASES=(teardown deploy validate mirror creds fipshost sts config extract install post audit)
FROM="${PHASES[0]}"; ONLY=""; YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --yes)  YES=1; shift ;;
        *) sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 2 ;;
    esac
done

export TEST_INSTALL_HOST="${TEST_INSTALL_HOST:-registry}"
export MIRROR_UPGRADE_FROM="${MIRROR_UPGRADE_FROM:-4.22.18}"
export MIRROR_TEST_OPERATORS="${MIRROR_TEST_OPERATORS:-cincinnati-operator:v1,openshift-cert-manager-operator:stable-v1,lightspeed-operator:stable}"
mkdir -p "${ROOT}/logs"
# Start of the egress-audit window: set on a full run, kept when resuming.
if [ "$FROM" = "${PHASES[0]}" ] || [ ! -s "${ROOT}/logs/.50-run-start" ]; then date -u +%s > "${ROOT}/logs/.50-run-start"; fi

env_load() {
    # shellcheck source=../cluster.env
    . "${ROOT}/cluster.env"
    # shellcheck disable=SC1091
    . "${ROOT}/secrets/aws.env"
    . "${ROOT}/scripts/lib-stack.sh"
}
proxy_ssh() { ssh "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "ec2-user@$(stack_output ProxyPrivateIp)" "$@"; }

phase_teardown() {
    env_load
    [ "$YES" -eq 1 ] || { read -r -p "Destroy cluster ${CLUSTER_NAME} and stack ${VPC_STACK_NAME}? [y/N] " a; [ "$a" = y ]; }
    if stack_ready 2>/dev/null; then
        for h in bastion registry; do
            if INSTALL_HOST=$h install_ssh "test -e ~/ocp-install/${CLUSTER_NAME}/metadata.json" 2>/dev/null; then
                echo "==> Destroying cluster ${CLUSTER_NAME} from the ${h}"
                INSTALL_HOST=$h install_ssh "cd ~/ocp-install/${CLUSTER_NAME}; set -a; . ~/ocp-install/aws.env; set +a;
                    bin=\$(command -v openshift-install || echo ~/bin-mirror/openshift-install-fips);
                    \$bin destroy cluster --dir . --log-level=info 2>&1 | tail -3"
            fi
        done
    fi
    echo "==> Deleting ccoctl STS resources (${CCOCTL_NAME})"
    "${ROOT}/bin/ccoctl" aws delete --name "$CCOCTL_NAME" --region "$AWS_DEFAULT_REGION" 2>&1 | tail -3 || true
    "${ROOT}/scripts/90-destroy-vpc.sh" --yes
}

phase_deploy() { "${ROOT}/scripts/10-deploy-vpc.sh"; }

phase_validate() {
    env_load; stack_ready
    echo "==> IMDSv2: unauthenticated (v1) metadata calls must fail, token calls must work"
    for h in bastion registry proxy; do
        case $h in bastion) f=bastion_ssh ;; registry) f=registry_ssh ;; proxy) f=proxy_ssh ;; esac
        $f 'v1=$(curl -s -o /dev/null -w %{http_code} http://169.254.169.254/latest/meta-data/instance-id);
            t=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60");
            v2=$(curl -s -o /dev/null -w %{http_code} -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/meta-data/instance-id);
            echo "v1=$v1 v2=$v2"' | sed "s/^/    ${h}: /"
    done
    echo "==> Scoped S3: the staging bucket works, listing all buckets is denied"
    bastion_ssh "aws s3 ls s3://$(stack_output S3BucketName) >/dev/null && echo '    staging bucket: OK'; aws s3 ls >/dev/null 2>&1 && echo '    s3 ls (all buckets): ALLOWED (unexpected)' || echo '    s3 ls (all buckets): denied (expected)'"
    echo "==> Squid: allowlist, explicit-proxy ACL, SNI log"
    registry_ssh 'for u in https://quay.io/v2/ https://registry.redhat.io/v2/ https://sts.us-east-2.amazonaws.com/; do printf "    %-40s %s\n" $u "$(curl -s -m 10 -o /dev/null -w %{http_code} $u || echo blocked)"; done'
    proxy_ssh 'printf "    3128 CONNECT google.com: %s\n" "$(curl -s -m 10 -o /dev/null -w %{http_code} -x http://127.0.0.1:3128 https://www.google.com/ || echo denied)"; sudo tail -3 /var/log/squid/access.log | sed "s/^/    /"'
    echo "==> Squid node reboot: rules and service persist"
    proxy_ssh 'sudo systemctl reboot' || true
    sleep 30
    for _ in $(seq 1 30); do out="$(proxy_ssh 'echo "redirects=$(sudo iptables -t nat -S | grep -c REDIRECT) squid=$(systemctl is-active squid)"' 2>/dev/null)" && break; sleep 10; done
    echo "    after reboot: ${out:-unreachable}"
    registry_ssh 'printf "    quay.io after reboot: %s\n" "$(curl -s -m 10 -o /dev/null -w %{http_code} https://quay.io/v2/ || echo blocked)"'
}

phase_mirror() {
    env_load; stack_ready
    echo "==> ImageSetConfiguration: ${OCP_CHANNEL} ${MIRROR_UPGRADE_FROM} -> ${OCP_VERSION}, operators ${MIRROR_TEST_OPERATORS}"
    OCP_UPGRADE_FROM="$MIRROR_UPGRADE_FROM" MIRROR_OPERATORS="$MIRROR_TEST_OPERATORS" \
        "${ROOT}/scripts/generate-imageset-config.sh" -o "${ROOT}/imageset-config.yaml"
    scp -q "${SSH_OPTS[@]}" "${ROOT}/imageset-config.yaml" "${ROOT}/scripts/bastion-mirror-to-mirror.sh" "ec2-user@${BASTION_IP}:"
    # Quay init password from the registry node's install log, passed via a mode-600 file.
    registry_ssh "sudo sh -c 'cat /opt/mirror-registry-install/install.log /tmp/mirror-registry-install.log 2>/dev/null' | grep -oP 'credentials \(init, \K[^)]+' | tail -1" \
        | bastion_ssh 'umask 077; cat > ~/.mirror-pass'
    registry_ssh 'sudo cat /opt/quay-root/quay-rootCA/rootCA.pem' | bastion_ssh 'cat > ~/mirror-rootCA.pem'
    local t0; t0=$(date +%s)
    bastion_ssh "export MIRROR_PASSWORD=\$(cat ~/.mirror-pass); rm -f ~/.mirror-pass;
        ./bastion-mirror-to-mirror.sh --ca-file ~/mirror-rootCA.pem --namespace ${MIRROR_NAMESPACE} ${REGISTRY_HOST} imageset-config.yaml > m2m.out 2>&1; rc=\$?;
        tail -12 m2m.out; exit \$rc"
    echo "    mirror-to-mirror took $(( $(date +%s) - t0 )) s"
    bastion_ssh 'ls ~/oc-mirror/m2m/working-dir/cluster-resources/ | sed "s/^/    /"; du -sh ~/oc-mirror ~/.oc-mirror 2>/dev/null | sed "s/^/    /"'
}

phase_creds()    { "${ROOT}/scripts/30-fetch-mirror-credentials.sh"; }
phase_fipshost() { "${ROOT}/scripts/35-enable-fips-host.sh" "$TEST_INSTALL_HOST"; }
phase_sts()      { "${ROOT}/scripts/20-prepare-sts.sh"; }
phase_config()   { "${ROOT}/scripts/generate-install-config.sh"; yq '{"fips": .fips, "osImageStream": .osImageStream, "publish": .publish, "capabilities": .capabilities}' "${ROOT}/install-config.yaml"; }
phase_extract()  { INSTALL_HOST="$TEST_INSTALL_HOST" "${ROOT}/scripts/38-extract-installer.sh"; }
phase_install() {
    INSTALL_HOST="$TEST_INSTALL_HOST" INSTALLER_BIN='~/bin-mirror/openshift-install-fips' "${ROOT}/scripts/40-install-cluster.sh" start
    INSTALL_HOST="$TEST_INSTALL_HOST" "${ROOT}/scripts/40-install-cluster.sh" wait
}
phase_post() { INSTALL_HOST="$TEST_INSTALL_HOST" "${ROOT}/scripts/45-post-install.sh" all; }
phase_audit() {
    env_load; stack_ready
    local since; since="$(cat "${ROOT}/logs/.50-run-start" 2>/dev/null || echo 0)"
    echo "==> Squid egress since $(date -u -d @"$since" +%FT%TZ): denied CONNECTs by destination"
    proxy_ssh "sudo awk -v s=$since '\$1>s && \$4 ~ /NONE_NONE|DENIED/ {print \$8}' /var/log/squid/access.log | sort | uniq -c | sort -rn | head -20" | sed 's/^/    /'
    echo "==> Allowed destinations"
    proxy_ssh "sudo awk -v s=$since '\$1>s && \$4 ~ /TUNNEL|HIT|MISS/ {print \$8}' /var/log/squid/access.log | sed -E 's/^[^.]+\.//' | sort | uniq -c | sort -rn | head -15" | sed 's/^/    /'
}

started=0
for p in "${PHASES[@]}"; do
    [ "$p" = "$FROM" ] && started=1
    [ "$started" -eq 1 ] || continue
    [ -n "$ONLY" ] && [ "$p" != "$ONLY" ] && continue
    log="${ROOT}/logs/50-${p}-$(date -u +%Y%m%dT%H%M%SZ).log"
    echo; echo "########## $(date -u +%H:%M:%SZ) phase ${p}  (log: ${log#"${ROOT}"/})"
    t0=$(date +%s)
    # Not in an if-condition: set -e only works inside the subshell this way.
    set +e; ( set -e; "phase_${p}" ) > >(tee "$log") 2>&1; rc=$?; set -e
    sleep 1   # let tee flush
    if [ "$rc" -eq 0 ]; then
        echo "########## phase ${p} OK in $(( $(date +%s) - t0 )) s"
    else
        echo "########## phase ${p} FAILED after $(( $(date +%s) - t0 )) s; resume with: $0 --from ${p}"
        exit 1
    fi
done
echo "########## $(date -u +%H:%M:%SZ) all phases done"
