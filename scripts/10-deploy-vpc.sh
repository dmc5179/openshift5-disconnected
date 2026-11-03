#!/usr/bin/env bash
#
# 10-deploy-vpc.sh - create (or reuse) the simulated disconnected environment:
#                    VPC, Squid egress filter, bastion and mirror registry, from
#                    cloudformation/disconnected_vpc_plus.yaml.
#
# Usage: scripts/10-deploy-vpc.sh [--dry-run] [--no-wait]
#
#   --dry-run   check credentials and inputs, print the parameters, create nothing
#   --no-wait   start the stack and return; follow it with
#               aws cloudformation wait stack-create-complete --stack-name <name>
#
# Settings come from cluster.env, AWS credentials and region from
# secrets/aws.env, the pull secret from PULL_SECRET_FILE. Everything printed is
# also written to logs/deploy-vpc-<timestamp>.log.
#
# The stack takes 20-40 minutes: the registry node waits (WaitCondition, up to
# 75 min) for the bastion to download the OpenShift tools and stage them in S3.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")
DRY_RUN=0
WAIT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --no-wait) WAIT=0; shift ;;
        -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "10-deploy-vpc.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "deploy-vpc" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

CREDS="${ROOT}/secrets/aws.env"
[ -f "$CREDS" ] || { echo "Error: credentials not found: ${CREDS} (see secrets/aws.env.example)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CREDS"
: "${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION must be set in secrets/aws.env}"
REGION="$AWS_DEFAULT_REGION"

for cmd in aws jq yq; do
    command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is not installed." >&2; exit 1; }
done

# --- pre-flight ---------------------------------------------------------------
echo "==> Checking AWS credentials (${REGION})"
aws sts get-caller-identity --output text --query 'Arn'
. "${ROOT}/scripts/lib-aws-target.sh"
resolve_aws_target
if [ "$TARGET_SIMULATED" -eq 0 ] && [ "$TARGET_ENV" != "commercial" ]; then
    echo "    Note: the template was built in commercial AWS. In ${TARGET_ENV} expect differences: RHEL AMIs"
    echo "    (RHELMap), RHUI and Squid allowlist domains, endpoint names and the ARN partition in IAM policies."
fi

[ -f "$VPC_TEMPLATE" ] || { echo "Error: template not found: ${VPC_TEMPLATE}" >&2; exit 1; }

# The template maps RHEL AMIs for a fixed list of regions only (CF-13).
if ! yq -e ".Mappings.RHELMap.\"${REGION}\"" "$VPC_TEMPLATE" >/dev/null 2>&1; then
    echo "Error: ${REGION} has no RHEL AMI in the template's RHELMap." >&2
    echo "       Mapped regions: $(yq -r '.Mappings.RHELMap | keys | join(", ")' "$VPC_TEMPLATE")" >&2
    exit 1
fi

case "$VPC_AZ_COUNT" in 1|2|3) ;; *) echo "Error: VPC_AZ_COUNT must be 1, 2 or 3 (got '${VPC_AZ_COUNT}')." >&2; exit 1 ;; esac

if ! aws ec2 describe-key-pairs --key-names "$EC2_KEY_NAME" >/dev/null 2>&1; then
    echo "Error: EC2 key pair '${EC2_KEY_NAME}' does not exist in ${REGION}." >&2
    echo "       Existing: $(aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text)" >&2
    exit 1
fi

[ -f "$PULL_SECRET_FILE" ] || { echo "Error: pull secret not found: ${PULL_SECRET_FILE}" >&2; exit 1; }
jq -e '.auths | length > 0' "$PULL_SECRET_FILE" >/dev/null \
    || { echo "Error: ${PULL_SECRET_FILE} is not a pull secret (no .auths)." >&2; exit 1; }

echo "==> Validating template"
aws cloudformation validate-template --template-body "file://${VPC_TEMPLATE}" >/dev/null

# --- parameters ---------------------------------------------------------------
# Passed as a JSON file, not "ParameterKey=...,ParameterValue=..." shorthand: the
# pull secret is JSON full of commas, which the shorthand would split.
umask 077
PARAMS_FILE="$(mktemp)"
trap 'rm -f "$PARAMS_FILE"' EXIT
jq -n \
    --arg cidr "$VPC_CIDR" --arg azs "$VPC_AZ_COUNT" --arg bits "$VPC_SUBNET_BITS" \
    --arg key "$EC2_KEY_NAME" --arg ver "$OCP_VERSION" \
    --arg nat "$PROXY_INSTANCE_TYPE" --arg bas "$BASTION_INSTANCE_TYPE" --arg reg "$REGISTRY_INSTANCE_TYPE" \
    --rawfile ps "$PULL_SECRET_FILE" '
    [ {ParameterKey:"VpcCidr",               ParameterValue:$cidr},
      {ParameterKey:"AvailabilityZoneCount", ParameterValue:$azs},
      {ParameterKey:"SubnetBits",            ParameterValue:$bits},
      {ParameterKey:"KeyName",               ParameterValue:$key},
      {ParameterKey:"OpenShiftVersion",      ParameterValue:$ver},
      {ParameterKey:"NATInstanceType",       ParameterValue:$nat},
      {ParameterKey:"BastionInstanceType",   ParameterValue:$bas},
      {ParameterKey:"RegistryInstanceType",  ParameterValue:$reg},
      {ParameterKey:"PullSecretJson",        ParameterValue:($ps | fromjson | tojson)} ]' > "$PARAMS_FILE"

echo "==> Stack ${VPC_STACK_NAME} parameters:"
jq -r '.[] | "    \(.ParameterKey) = \(if .ParameterKey=="PullSecretJson" then "<\(.ParameterValue|length) bytes, hidden>" else .ParameterValue end)"' "$PARAMS_FILE"

print_outputs() {
    echo "==> Stack outputs:"
    aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey!=`InstallConfigSubnets`].[OutputKey,OutputValue]' --output text \
        | awk -F'\t' '{printf "    %-24s %s\n", $1, $2}'
}

show_failures() {
    echo "==> Failed resources in ${VPC_STACK_NAME}:" >&2
    aws cloudformation describe-stack-events --stack-name "$VPC_STACK_NAME" \
        --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
        --output text | head -20 >&2 || true
}

# --- create or reuse ----------------------------------------------------------
if status="$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
              --query 'Stacks[0].StackStatus' --output text 2>/dev/null)"; then
    echo "==> Stack ${VPC_STACK_NAME} already exists (${status}); reusing it"
    case "$status" in
        CREATE_COMPLETE|UPDATE_COMPLETE) print_outputs; exit 0 ;;
        CREATE_IN_PROGRESS)
            [ "$DRY_RUN" -eq 1 ] && exit 0
            [ "$WAIT" -eq 1 ] || exit 0
            echo "    Waiting for it to finish" ;;
        *) show_failures
           echo "Error: stack is in ${status}. Delete it first:" >&2
           echo "       aws s3 rm --recursive s3://\$(bucket)   # the staging bucket blocks deletion (CF-12)" >&2
           echo "       aws cloudformation delete-stack --stack-name ${VPC_STACK_NAME}" >&2
           exit 1 ;;
    esac
elif [ "$DRY_RUN" -eq 1 ]; then
    echo "==> [dry-run] would create stack ${VPC_STACK_NAME} from ${VPC_TEMPLATE#"${ROOT}/"} (CAPABILITY_IAM)"
    exit 0
else
    echo "==> Creating stack ${VPC_STACK_NAME}"
    aws cloudformation create-stack \
        --stack-name "$VPC_STACK_NAME" \
        --template-body "file://${VPC_TEMPLATE}" \
        --parameters "file://${PARAMS_FILE}" \
        --capabilities CAPABILITY_IAM \
        --tags "Key=Project,Value=openshift5-disconnected" \
        --output text --query 'StackId'
    [ "$WAIT" -eq 1 ] || { echo "    Not waiting (--no-wait)."; exit 0; }
fi

echo "    Waiting for stack-create-complete (20-40 minutes)"
SECONDS=0
# `aws cloudformation wait` gives up after 60 minutes; the WaitCondition alone
# may take 75, so poll ourselves.
while :; do
    status="$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" --query 'Stacks[0].StackStatus' --output text)"
    case "$status" in
        CREATE_COMPLETE) break ;;
        CREATE_IN_PROGRESS) printf '    %3d min  %s\n' $((SECONDS/60)) "$status"; sleep 60 ;;
        *) show_failures; echo "Error: stack ended in ${status}" >&2; exit 1 ;;
    esac
done
echo "==> Stack created in $((SECONDS/60)) minutes"
print_outputs

cat <<EOF

Next:
  1. Copy the mirror-registry root CA locally (the registry is reachable only from inside the VPC):
       scp -o ProxyJump=ec2-user@<BastionPublicIp> ec2-user@<RegistryPrivateIp>:/opt/quay-root/quay-rootCA/rootCA.pem ${MIRROR_CA_FILE}
     (root-owned on the node; copy it to /tmp with sudo first if scp is refused)
  2. scripts/generate-imageset-config.sh
  3. scripts/generate-install-config.sh
EOF
