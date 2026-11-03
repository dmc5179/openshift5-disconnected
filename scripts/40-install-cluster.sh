#!/usr/bin/env bash
#
# 40-install-cluster.sh - install OpenShift from INSIDE the disconnected VPC.
#
# Usage: scripts/40-install-cluster.sh [start|status|wait|fetch-auth]
#
#   start       (default) copy install-config.yaml, the ccoctl STS manifests and
#               AWS credentials to the install host, run
#               `openshift-install create manifests`, add the STS manifests and
#               tls/, then start `create cluster` detached (survives SSH drops)
#   status      installer process state and the last lines of its log
#   wait        poll status until the installer exits; print the result
#   fetch-auth  copy <install dir>/auth (kubeconfig, kubeadmin password) to
#               clusters/<CLUSTER_NAME>/auth here (mode 600)
#
# The install host is the mirror-registry node in the private subnet: its only
# egress is the Squid allowlist (AWS APIs), so the install runs the way it would
# in a disconnected environment. The cluster API is internal (publish: Internal),
# so the installer has to run inside the VPC anyway.
#
# Prerequisites: scripts/30-fetch-mirror-credentials.sh,
# scripts/generate-install-config.sh, scripts/20-prepare-sts.sh.
#
# Credentials: openshift-install needs IAM-user AWS credentials to create the
# infrastructure (even with credentialsMode Manual/STS); the node's instance
# role is not enough. secrets/aws.env is copied to the host (mode 600) and must
# stay there until the cluster is destroyed (`openshift-install destroy cluster`).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-start}"
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"
stack_ready

RDIR="ocp-install/${CLUSTER_NAME}"           # relative to ec2-user's home on the host
LOG_LEVEL="${LOG_LEVEL:-info}"

remote_status() {
    registry_ssh "pgrep -f 'openshift-install.*create cluster' >/dev/null && echo 'installer: RUNNING' || echo 'installer: not running';
                  [ -f ~/${RDIR}/install.exit ] && echo \"exit code: \$(cat ~/${RDIR}/install.exit)\";
                  tail -n 8 ~/${RDIR}/.openshift_install.log 2>/dev/null | sed -E 's/^time=\"([^\"]+)\" level=([a-z]+) msg=/\\1 \\2 /' | cut -c1-200"
}

case "$ACTION" in
start)
    IC="${ROOT}/install-config.yaml"
    CC="${CLUSTER_DIR}/ccoctl"
    [ -f "$IC" ] || { echo "Error: ${IC} missing; run scripts/generate-install-config.sh." >&2; exit 1; }
    if [ "$(yq -r '.credentialsMode' "$IC")" = "Manual" ]; then
        [ -d "${CC}/manifests" ] && [ -d "${CC}/tls" ] \
            || { echo "Error: credentialsMode Manual but no ccoctl output in ${CC}; run scripts/20-prepare-sts.sh." >&2; exit 1; }
    fi
    if registry_ssh "test -e ~/${RDIR}/metadata.json || pgrep -f 'openshift-install.*create cluster' >/dev/null"; then
        echo "Error: ~/${RDIR} on ${REGISTRY_HOST} already holds an install (or one is running)." >&2
        echo "       Check it with: $0 status   - destroy it before starting again." >&2
        exit 1
    fi

    echo "==> Install host: ${REGISTRY_HOST} (private subnet, via bastion ${BASTION_IP})"
    registry_ssh "openshift-install version | head -2 | sed 's/^/    /'"

    echo "==> Copying install-config, STS manifests and AWS credentials (mode 600)"
    registry_ssh "umask 077; rm -rf ~/${RDIR} ~/${RDIR}-sts; mkdir -p ~/${RDIR} ~/${RDIR}-sts"
    registry_scp "$IC" "ec2-user@${REGISTRY_HOST}:${RDIR}/install-config.yaml"
    registry_scp "${ROOT}/secrets/aws.env" "ec2-user@${REGISTRY_HOST}:ocp-install/aws.env"
    if [ -d "${CC}/manifests" ]; then
        tar -C "$CC" -czf - manifests tls | registry_ssh "umask 077; tar -C ~/${RDIR}-sts -xzf -"
    fi
    registry_ssh "chmod 600 ~/ocp-install/aws.env ~/${RDIR}/install-config.yaml; cp ~/${RDIR}/install-config.yaml ~/${RDIR}-sts/install-config.yaml.orig"

    echo "==> Raising inotify limits (the installer's local control plane needs them)"
    registry_ssh "sudo sysctl -q -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288"

    echo "==> openshift-install create manifests"
    registry_ssh "set -e; set -a; . ~/ocp-install/aws.env; set +a; cd ~/${RDIR};
                  openshift-install create manifests --dir . --log-level=${LOG_LEVEL} 2>&1 | tail -5
                  if [ -d ~/${RDIR}-sts/manifests ]; then
                      cp ~/${RDIR}-sts/manifests/* manifests/
                      cp -a ~/${RDIR}-sts/tls .
                      echo \"    added \$(ls ~/${RDIR}-sts/manifests | wc -l) STS manifests and tls/\"
                  fi"

    echo "==> Starting openshift-install create cluster (detached; 35-50 minutes)"
    registry_ssh "cd ~/${RDIR}; rm -f install.exit;
                  setsid nohup bash -c 'set -a; . ~/ocp-install/aws.env; set +a;
                      openshift-install create cluster --dir . --log-level=${LOG_LEVEL} > install.out 2>&1; echo \$? > install.exit' \
                      >/dev/null 2>&1 < /dev/null &
                  sleep 5; pgrep -f 'openshift-install.*create cluster' >/dev/null && echo '    started'"
    echo "    Follow it with: $0 status   |   $0 wait"
    ;;
status)
    remote_status
    ;;
wait)
    SECONDS=0
    while registry_ssh "pgrep -f 'openshift-install.*create cluster' >/dev/null"; do
        line="$(registry_ssh "tail -n 1 ~/${RDIR}/.openshift_install.log 2>/dev/null" | sed -E 's/^time="[^"]+" level=([a-z]+) msg=/\1 /' | cut -c1-160)"
        printf '%3d min  %s\n' $((SECONDS/60)) "$line"
        sleep 120
    done
    remote_status
    rc="$(registry_ssh "cat ~/${RDIR}/install.exit 2>/dev/null" || echo unknown)"
    [ "$rc" = "0" ] && echo "==> Install finished successfully" || { echo "==> Installer exited ${rc}" >&2; exit 1; }
    ;;
fetch-auth)
    mkdir -p "${CLUSTER_DIR}/auth"; chmod 700 "${CLUSTER_DIR}/auth"
    registry_ssh "tar -C ~/${RDIR} -czf - auth" | tar -C "${CLUSTER_DIR}" -xzf -
    chmod 600 "${CLUSTER_DIR}/auth/"*
    echo "==> ${CLUSTER_DIR}/auth (kubeconfig, kubeadmin-password). The API is internal: use it from inside the VPC."
    ;;
*) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
