#!/usr/bin/env bash
#
# 70-power.sh - stop and start the lab without destroying it (keeps the stack, the
#               mirror registry content and the cluster).
#
# Usage: scripts/70-power.sh stop|start|status [cluster|stack|all]   (default: all)
#
#   cluster  the OpenShift nodes (EC2 instances tagged kubernetes.io/cluster/<infra-id>
#            in the stack's VPC)
#   stack    the bastion, the registry node (mirror-registry) and the Squid NAT node
#   all      both. stop: cluster first, then the stack. start: stack first (the nodes
#            need the registry and Squid), then the cluster.
#
# stop uses EC2 stop-instances (an ACPI shutdown, so the OS shuts down cleanly).
# start waits for the instances, waits for Quay's health on the registry node, then
# approves pending node CSRs for up to 20 minutes until every node is Ready. That
# matters for clusters younger than about 24 hours: their first kubelet certificates
# may expire while the cluster is off, and the nodes then need their new CSRs approved
# (OpenShift "graceful shutdown" docs). After a start the bastion has a new public IP;
# lib-stack.sh looks it up live. Your SSH source address must still be allowed in the
# bastion security group.
#
# Costs while stopped: EBS volumes, the S3 buckets and the cluster's load balancers and
# NAT/ELB resources still bill. Tear down with scripts/50-rebuild-and-test.sh --only teardown.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-status}"
TARGET="${2:-all}"
export INSTALL_HOST="${INSTALL_HOST:-registry}"
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"

case "$TARGET" in cluster|stack|all) ;; *) echo "Target must be cluster, stack or all." >&2; exit 2 ;; esac

vpc_id() {
    aws cloudformation describe-stack-resource --stack-name "$VPC_STACK_NAME" --logical-resource-id VPC \
        --query StackResourceDetail.PhysicalResourceId --output text
}
# Instance IDs (any state except terminated) for a target.
ids() {
    local vpc; vpc="$(vpc_id)"
    case "$1" in
        stack)
            aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-name,Values=${VPC_STACK_NAME}" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                --query 'Reservations[].Instances[].InstanceId' --output text ;;
        cluster)
            aws ec2 describe-instances --filters "Name=vpc-id,Values=${vpc}" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped" --output json \
                | jq -r '.Reservations[].Instances[] | select(any(.Tags[]?; .Key|startswith("kubernetes.io/cluster/"))) | .InstanceId' \
                | tr '\n' ' ' ;;
    esac
}
show() {
    local t="$1" list; list="$(ids "$t")"
    [ -n "${list// /}" ] || { echo "    ${t}: no instances"; return 0; }
    # shellcheck disable=SC2086
    aws ec2 describe-instances --instance-ids $list --output json \
        | jq -r --arg t "$t" '.Reservations[].Instances[] | "    \($t): \(.InstanceId) \(.State.Name) \((.Tags//[])|map(select(.Key=="Name"))|.[0].Value // "")"'
}
stop_t() {
    local t="$1" list; list="$(ids "$t")"
    [ -n "${list// /}" ] || { echo "    ${t}: nothing to stop"; return 0; }
    echo "==> Stopping ${t}: ${list}"
    # shellcheck disable=SC2086
    aws ec2 stop-instances --instance-ids $list --output text --query 'StoppingInstances[].CurrentState.Name' | sed 's/^/    /'
    # shellcheck disable=SC2086
    aws ec2 wait instance-stopped --instance-ids $list
    echo "    ${t} stopped"
}
start_t() {
    local t="$1" list; list="$(ids "$t")"
    [ -n "${list// /}" ] || { echo "    ${t}: nothing to start"; return 0; }
    echo "==> Starting ${t}: ${list}"
    # shellcheck disable=SC2086
    aws ec2 start-instances --instance-ids $list --output text --query 'StartingInstances[].CurrentState.Name' | sed 's/^/    /'
    # shellcheck disable=SC2086
    aws ec2 wait instance-running --instance-ids $list
    echo "    ${t} running"
}
wait_stack_services() {
    stack_ready >/dev/null
    echo "==> Waiting for SSH to the bastion (${BASTION_IP}) and Quay health on the registry node"
    for _ in $(seq 1 40); do bastion_ssh true 2>/dev/null && break; sleep 10; done
    registry_ssh "for i in \$(seq 1 60); do c=\$(curl -sk -o /dev/null -w %{http_code} https://\$(hostname -f):8443/health/instance); [ \"\$c\" = 200 ] && { echo '    Quay healthy'; exit 0; }; sleep 10; done; echo '    WARNING: Quay not healthy after 10 min'"
}
recover_cluster() {
    stack_ready >/dev/null
    local RDIR="ocp-install/${CLUSTER_NAME}"
    echo "==> Approving pending node CSRs until all nodes are Ready (up to 20 min)"
    install_ssh "export KUBECONFIG=~/${RDIR}/auth/kubeconfig
        for i in \$(seq 1 80); do
            p=\$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{\"\\n\"}}{{end}}{{end}}' 2>/dev/null)
            [ -n \"\$p\" ] && echo \"\$p\" | xargs oc adm certificate approve | sed 's/^/    /'
            nr=\$(oc get nodes --no-headers 2>/dev/null | awk '\$2!=\"Ready\"' | wc -l); tot=\$(oc get nodes --no-headers 2>/dev/null | wc -l)
            [ \"\$tot\" -gt 0 ] && [ \"\$nr\" -eq 0 ] && { echo \"    all \$tot nodes Ready\"; break; }
            sleep 15
        done
        oc get nodes --no-headers | sed 's/^/    /'
        oc get co --no-headers | awk '{a+=(\$3==\"True\"); d+=(\$5==\"True\")} END {print \"    operators: \"NR\", available=\"a\", degraded=\"d}'"
}

stack_ready >/dev/null || exit 1
case "$ACTION" in
    status)
        echo "==> Instances"; [ "$TARGET" = stack ] || show cluster; [ "$TARGET" = cluster ] || show stack ;;
    stop)
        [ "$TARGET" = stack ] || stop_t cluster
        [ "$TARGET" = cluster ] || stop_t stack ;;
    start)
        if [ "$TARGET" != cluster ]; then start_t stack; wait_stack_services; fi
        if [ "$TARGET" != stack ]; then start_t cluster; recover_cluster; fi ;;
    *) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
