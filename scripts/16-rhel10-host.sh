#!/usr/bin/env bash
#
# 16-rhel10-host.sh - a RHEL 10 FIPS host next to the stack, outside the
#                     CloudFormation stack (B-2, B-3, F2, B-4), either as a
#                     test host in the public subnet or as the install host in
#                     the private subnet (INSTALL_HOST=rhel10).
#
# Usage: scripts/16-rhel10-host.sh [--private|--public] create|status|ssh [cmd...]|prep|terminate
#        (the placement flag may also follow the action: create --private)
#
# Placement: --private / --public, or RHEL10_HOST_SUBNET=private|public (default public).
#   public   stack PublicSubnetId, public IP, bastion security group
#            (HelperInstanceSG: SSH from ALLOWED_SSH_CIDR only). SSH direct.
#            Tag ocp5:role=rhel10-fips-host.
#   private  stack PrivateSubnetId, no public IP, registry security group
#            (RegistryInstanceSG: SSH and 8443 from the VPC CIDR, so from the
#            bastion; egress unrestricted at the SG, but the private route table
#            sends 0.0.0.0/0 to the Squid instance, which only passes the
#            allowlist). SSH via the bastion (ProxyCommand), like the registry
#            node. Tag ocp5:role=rhel10-fips-install-host. This is the install
#            host for INSTALL_HOST=rhel10 (scripts/lib-stack.sh).
#
#   prep     (private host) no internet and no dnf repos there, so: stream the
#            bastion's rhel9 oc + kubectl into /usr/local/bin, add the mirror CA
#            (from the registry node) to the system trust, then check
#            fips_enabled=1, Quay health over TLS with that CA, an allowlisted
#            AWS endpoint, and that quay.io is blocked. Idempotent.
#
# Launches RHEL10_FIPS_AMI_ID (cluster.env; a FIPS-enabled image-mode RHEL 10
# image, since RHEL 10 can only enable FIPS at installation) with the stack key
# pair, IMDSv2 required, root volume RHEL10_HOST_DISK_GB (default 300).
#
# The instance lives in the stack's VPC but is not part of the stack:
# scripts/90-destroy-vpc.sh terminates every instance tagged
# ocp5:stack=<VPC_STACK_NAME> first, otherwise the VPC deletion fails.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLACEMENT="${RHEL10_HOST_SUBNET:-public}"
ACTION=""; ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --private) PLACEMENT=private; shift ;;
        --public)  PLACEMENT=public; shift ;;
        *) if [ -z "$ACTION" ]; then ACTION="$1"; shift; else ARGS=("$@"); break; fi ;;
    esac
done
# `ssh --private cmd` and `create --private` both work; a later --private in an
# ssh command line is passed through to the remote command.
case "$PLACEMENT" in public|private) ;; *) echo "RHEL10_HOST_SUBNET must be public or private." >&2; exit 2 ;; esac
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"

USER_NAME="${RHEL10_HOST_USER:-cloud-user}"
if [ "$PLACEMENT" = private ]; then ROLE_TAG="$RHEL10_INSTALL_ROLE"; NAME_SUFFIX="rhel10-fips-install"
else ROLE_TAG="$RHEL10_PUBLIC_ROLE"; NAME_SUFFIX="rhel10-fips"; fi

find_instance() { rhel10_host_lookup "$ROLE_TAG"; }   # "<id> <private ip> <public ip> <state>"
host_addr() {   # address used for SSH: public IP (public host), private IP (private host)
    local id priv pub
    read -r id priv pub _ <<<"$(find_instance)"
    [ -n "${id:-}" ] || return 1
    if [ "$PLACEMENT" = private ]; then echo "$priv"; else echo "$pub"; fi
}
host_ssh() {
    local addr="$1"; shift
    if [ "$PLACEMENT" = private ]; then
        ssh "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "${USER_NAME}@${addr}" "$@"
    else
        ssh "${SSH_OPTS[@]}" "${USER_NAME}@${addr}" "$@"
    fi
}
stack_sg() {
    aws cloudformation describe-stack-resource --stack-name "$VPC_STACK_NAME" \
        --logical-resource-id "$1" --query StackResourceDetail.PhysicalResourceId --output text
}

do_prep() {
    [ "$PLACEMENT" = private ] || echo "    Note: prep is meant for the private install host (--private)."
    local addr; addr="$(host_addr)" || { echo "Error: no RHEL 10 ${PLACEMENT} host; run $0 --${PLACEMENT} create." >&2; exit 1; }
    echo "==> Prep ${USER_NAME}@${addr} (${PLACEMENT})"
    echo "==> fips_enabled (FIPS from installation; no fips-mode-setup on RHEL 10)"
    local f; f="$(host_ssh "$addr" 'cat /proc/sys/crypto/fips_enabled')"
    echo "    fips_enabled=${f}, policy $(host_ssh "$addr" 'update-crypto-policies --show')"
    [ "$f" = "1" ] || { echo "Error: the RHEL 10 host is not in FIPS mode." >&2; exit 1; }

    echo "==> oc and kubectl (rhel9 ${OCP_VERSION} builds) from the bastion's /usr/local/bin -> /usr/local/bin"
    # oc and kubectl are hard links on the bastion; tar sends the data once.
    bastion_ssh 'tar -C /usr/local/bin -czf - oc kubectl' \
        | host_ssh "$addr" 'set -e; d=$(mktemp -d); tar -C "$d" -xzf -;
                            sudo install -m 755 "$d/oc" "$d/kubectl" /usr/local/bin/; rm -rf "$d"
                            echo "    $(command -v oc): $(oc version --client 2>/dev/null | head -1)"'

    echo "==> Mirror registry CA (from the registry node) -> system trust"
    registry_ssh 'sudo cat /opt/quay-root/quay-rootCA/rootCA.pem' \
        | host_ssh "$addr" 'set -e; t=$(mktemp); cat > "$t"; grep -q "BEGIN CERTIFICATE" "$t";
                            sudo install -m 644 "$t" /etc/pki/ca-trust/source/anchors/ocp5-mirror-rootCA.pem; rm -f "$t";
                            sudo update-ca-trust; echo "    anchor /etc/pki/ca-trust/source/anchors/ocp5-mirror-rootCA.pem"'

    echo "==> Reachability from the RHEL 10 host"
    host_ssh "$addr" "h=\$(curl -s -m 10 -o /dev/null -w %{http_code} https://${REGISTRY_HOST}:${MIRROR_REGISTRY_PORT}/health/instance || echo fail)
        echo \"    mirror ${REGISTRY_HOST}:${MIRROR_REGISTRY_PORT}/health/instance (system trust): \$h\"
        a=\$(curl -s -m 10 -o /dev/null -w %{http_code} https://sts.${AWS_DEFAULT_REGION}.amazonaws.com/ || echo fail)
        echo \"    AWS API sts.${AWS_DEFAULT_REGION}.amazonaws.com (allowlisted): \$a\"
        q=\$(curl -s -m 10 -o /dev/null -w %{http_code} https://quay.io/v2/ || echo blocked)
        echo \"    quay.io (must be blocked): \$q\"
        [ \"\$h\" = 200 ] || { echo 'Error: mirror registry not reachable with the CA.' >&2; exit 1; }
        [ \"\$q\" = blocked ] || { echo 'Error: quay.io is reachable; the host is not air-gapped.' >&2; exit 1; }
        [ \"\$a\" != fail ] || echo '    WARNING: the AWS API is not reachable; openshift-install will fail.'"
    echo "==> Ready: INSTALL_HOST=rhel10 (scripts/38-extract-installer.sh, 40-install-cluster.sh)"
}

case "$ACTION" in
create)
    stack_ready
    existing="$(find_instance)"
    [ -n "$existing" ] && { echo "Already exists (${PLACEMENT}): ${existing}"; exit 0; }
    : "${RHEL10_FIPS_AMI_ID:?set RHEL10_FIPS_AMI_ID in cluster.env}"
    if [ "$PLACEMENT" = private ]; then
        subnet="$(stack_output PrivateSubnetId)"; sg="$(stack_sg RegistryInstanceSG)"; pubip=(--no-associate-public-ip-address)
    else
        subnet="$(stack_output PublicSubnetId)";  sg="$(stack_sg HelperInstanceSG)";   pubip=(--associate-public-ip-address)
    fi
    root_dev="$(aws ec2 describe-images --image-ids "$RHEL10_FIPS_AMI_ID" --query 'Images[0].RootDeviceName' --output text)"
    echo "==> Launching ${RHEL10_FIPS_AMI_ID} (${RHEL10_HOST_TYPE:-m6i.2xlarge}, ${RHEL10_HOST_DISK_GB:-300} GB) in ${PLACEMENT} subnet ${subnet}, SG ${sg}"
    id="$(aws ec2 run-instances --image-id "$RHEL10_FIPS_AMI_ID" --instance-type "${RHEL10_HOST_TYPE:-m6i.2xlarge}" \
          --key-name "$EC2_KEY_NAME" --subnet-id "$subnet" --security-group-ids "$sg" "${pubip[@]}" \
          --metadata-options HttpTokens=required,HttpEndpoint=enabled \
          --block-device-mappings "DeviceName=${root_dev},Ebs={VolumeSize=${RHEL10_HOST_DISK_GB:-300},VolumeType=gp3,DeleteOnTermination=true}" \
          --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${VPC_STACK_NAME}-${NAME_SUFFIX}},{Key=ocp5:role,Value=${ROLE_TAG}},{Key=ocp5:stack,Value=${VPC_STACK_NAME}}]" \
          --query 'Instances[0].InstanceId' --output text)"
    echo "    ${id}; waiting for running and SSH"
    aws ec2 wait instance-running --instance-ids "$id"
    addr="$(host_addr)"
    # A new instance has new host keys; drop any entry left for a reused address.
    ssh-keygen -R "$addr" -f "${HOME}/.ssh/known_hosts.${VPC_STACK_NAME}" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do host_ssh "$addr" true 2>/dev/null && break; sleep 10; done
    host_ssh "$addr" 'echo "    $(. /etc/os-release; echo $PRETTY_NAME), fips_enabled=$(cat /proc/sys/crypto/fips_enabled)"'
    echo "    ssh: scripts/16-rhel10-host.sh --${PLACEMENT} ssh   (${USER_NAME}@${addr})"
    ;;
status)
    find_instance || true ;;
ssh)
    stack_ready >/dev/null
    addr="$(host_addr)" && [ -n "$addr" ] && [ "$addr" != None ] || { echo "No RHEL 10 ${PLACEMENT} host." >&2; exit 1; }
    host_ssh "$addr" ${ARGS[@]+"${ARGS[@]}"} ;;
prep)
    stack_ready >/dev/null
    do_prep ;;
terminate)
    read -r id _ _ _ <<<"$(find_instance)"
    [ -n "${id:-}" ] || { echo "No RHEL 10 ${PLACEMENT} host."; exit 0; }
    echo "==> Terminating ${id} (${PLACEMENT})"
    aws ec2 terminate-instances --instance-ids "$id" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$id"
    echo "    terminated" ;;
*) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
