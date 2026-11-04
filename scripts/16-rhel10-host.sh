#!/usr/bin/env bash
#
# 16-rhel10-host.sh - a RHEL 10 FIPS test host next to the bastion, outside the
#                     CloudFormation stack (B-2, B-3, F2, B-4).
#
# Usage: scripts/16-rhel10-host.sh create|status|ssh [cmd...]|terminate
#
# Launches RHEL10_FIPS_AMI_ID (cluster.env; a FIPS-enabled RHEL 10 image built
# with image builder, since RHEL 10 can only enable FIPS at installation) in the
# stack's public subnet with the bastion security group (SSH from this
# workstation only) and the stack key pair. Root volume RHEL10_HOST_DISK_GB.
#
# The instance lives in the stack's VPC but is not part of the stack:
# scripts/90-destroy-vpc.sh terminates it first, otherwise the VPC deletion
# fails. Tagged ocp5:role=rhel10-fips-host and ocp5:stack=<VPC_STACK_NAME>.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"; shift || true
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"

ROLE_TAG="rhel10-fips-host"
find_instance() {
    aws ec2 describe-instances \
        --filters "Name=tag:ocp5:role,Values=${ROLE_TAG}" "Name=tag:ocp5:stack,Values=${VPC_STACK_NAME}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[0].[InstanceId,PublicIpAddress,State.Name]' --output text | head -1
}
host_ssh() {
    local ip="$1"; shift
    ssh "${SSH_OPTS[@]}" "${RHEL10_HOST_USER:-cloud-user}@${ip}" "$@"
}

case "$ACTION" in
create)
    stack_ready
    [ -n "$(find_instance)" ] && { echo "Already exists: $(find_instance)"; exit 0; }
    : "${RHEL10_FIPS_AMI_ID:?set RHEL10_FIPS_AMI_ID in cluster.env}"
    subnet="$(stack_output PublicSubnetId)"
    sg="$(aws cloudformation describe-stack-resource --stack-name "$VPC_STACK_NAME" \
          --logical-resource-id HelperInstanceSG --query StackResourceDetail.PhysicalResourceId --output text)"
    root_dev="$(aws ec2 describe-images --image-ids "$RHEL10_FIPS_AMI_ID" --query 'Images[0].RootDeviceName' --output text)"
    echo "==> Launching ${RHEL10_FIPS_AMI_ID} (${RHEL10_HOST_TYPE:-m6i.2xlarge}, ${RHEL10_HOST_DISK_GB:-300} GB) in ${subnet}"
    id="$(aws ec2 run-instances --image-id "$RHEL10_FIPS_AMI_ID" --instance-type "${RHEL10_HOST_TYPE:-m6i.2xlarge}" \
          --key-name "$EC2_KEY_NAME" --subnet-id "$subnet" --security-group-ids "$sg" --associate-public-ip-address \
          --metadata-options HttpTokens=required,HttpEndpoint=enabled \
          --block-device-mappings "DeviceName=${root_dev},Ebs={VolumeSize=${RHEL10_HOST_DISK_GB:-300},VolumeType=gp3,DeleteOnTermination=true}" \
          --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${VPC_STACK_NAME}-rhel10-fips},{Key=ocp5:role,Value=${ROLE_TAG}},{Key=ocp5:stack,Value=${VPC_STACK_NAME}}]" \
          --query 'Instances[0].InstanceId' --output text)"
    echo "    ${id}; waiting for running and SSH"
    aws ec2 wait instance-running --instance-ids "$id"
    ip="$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
    for _ in $(seq 1 40); do host_ssh "$ip" true 2>/dev/null && break; sleep 10; done
    host_ssh "$ip" 'echo "    $(. /etc/os-release; echo $PRETTY_NAME), fips_enabled=$(cat /proc/sys/crypto/fips_enabled)"'
    echo "    ssh: scripts/16-rhel10-host.sh ssh   (${RHEL10_HOST_USER:-cloud-user}@${ip})"
    ;;
status)
    find_instance || true ;;
ssh)
    stack_ready >/dev/null
    read -r _ ip _ <<<"$(find_instance)"
    [ -n "${ip:-}" ] || { echo "No RHEL 10 host." >&2; exit 1; }
    host_ssh "$ip" "$@" ;;
terminate)
    read -r id _ _ <<<"$(find_instance)"
    [ -n "${id:-}" ] || { echo "No RHEL 10 host."; exit 0; }
    echo "==> Terminating ${id}"
    aws ec2 terminate-instances --instance-ids "$id" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$id"
    echo "    terminated" ;;
*) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
