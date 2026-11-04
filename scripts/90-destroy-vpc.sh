#!/usr/bin/env bash
#
# 90-destroy-vpc.sh - delete the simulated disconnected environment stack.
#
# Usage: scripts/90-destroy-vpc.sh [--yes]
#
# Empties the staging S3 bucket first (a non-empty bucket makes delete-stack
# fail), then deletes the stack and waits. Destroy any OpenShift cluster
# installed into the VPC first: its load balancers, instances and security
# groups would block the VPC deletion.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")
YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=1; shift ;;
        -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "90-destroy-vpc.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "destroy-vpc" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"

if ! aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" >/dev/null 2>&1; then
    echo "==> Stack ${VPC_STACK_NAME} does not exist; nothing to do"; exit 0
fi

if [ "$YES" -ne 1 ]; then
    read -r -p "Delete stack ${VPC_STACK_NAME} in ${AWS_DEFAULT_REGION} (bastion, registry and all mirrored content)? [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 1; }
fi

bucket="$(aws cloudformation describe-stack-resource --stack-name "$VPC_STACK_NAME" --logical-resource-id S3Bucket \
          --query 'StackResourceDetail.PhysicalResourceId' --output text 2>/dev/null || true)"
if [ -n "$bucket" ] && [ "$bucket" != "None" ] && aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "==> Emptying s3://${bucket}"
    aws s3 rm --recursive --quiet "s3://${bucket}"
fi

echo "==> Deleting stack ${VPC_STACK_NAME}"
# Instances launched into the VPC outside the stack (scripts/16-rhel10-host.sh)
# would block the VPC deletion.
extra="$(aws ec2 describe-instances --filters "Name=tag:ocp5:stack,Values=${VPC_STACK_NAME}" \
          "Name=instance-state-name,Values=pending,running,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text)"
if [ -n "$extra" ]; then
    echo "==> Terminating non-stack instances in the VPC: ${extra}"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $extra >/dev/null
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $extra
fi
aws cloudformation delete-stack --stack-name "$VPC_STACK_NAME"
aws cloudformation wait stack-delete-complete --stack-name "$VPC_STACK_NAME"
echo "==> Deleted"
