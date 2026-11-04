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

# The key pair's private key must be here, or nothing can SSH to the bastion
# (and through it to the registry). For an IMPORTED RSA key, AWS's fingerprint
# is the MD5 of the DER SubjectPublicKeyInfo - not ssh-keygen's MD5, which hashes
# the OpenSSH wire format. ssh-keygen -e -m PKCS8 gives the DER without openssl.
# (AWS-generated key pairs use a SHA-1 of the private key instead; not handled.)
[ -f "${SSH_PRIVATE_KEY:-}" ] || { echo "Error: SSH_PRIVATE_KEY not found: ${SSH_PRIVATE_KEY:-unset}" >&2; exit 1; }
aws_fp="$(aws ec2 describe-key-pairs --key-names "$EC2_KEY_NAME" --query 'KeyPairs[0].KeyFingerprint' --output text)"
local_fp="$(ssh-keygen -y -P '' -f "$SSH_PRIVATE_KEY" 2>/dev/null > "${PARAMS_DIR:-/tmp}/.pub.$$" \
            && ssh-keygen -e -m PKCS8 -f "${PARAMS_DIR:-/tmp}/.pub.$$" | grep -v '^-----' | base64 -d | md5sum \
            | awk '{print $1}' | sed 's/../&:/g; s/:$//')" || true
rm -f "${PARAMS_DIR:-/tmp}/.pub.$$"
if [ "$aws_fp" != "$local_fp" ]; then
    echo "Error: key pair '${EC2_KEY_NAME}' (${aws_fp}) does not match ${SSH_PRIVATE_KEY} (${local_fp:-unreadable or passphrase-protected})." >&2
    echo "       Import the matching public key, e.g.:" >&2
    echo "         aws ec2 import-key-pair --key-name <name> --public-key-material fileb://${SSH_PRIVATE_KEY}.pub" >&2
    exit 1
fi
echo "==> Key pair ${EC2_KEY_NAME} matches ${SSH_PRIVATE_KEY}"

[ -f "$PULL_SECRET_FILE" ] || { echo "Error: pull secret not found: ${PULL_SECRET_FILE}" >&2; exit 1; }
jq -e '.auths | length > 0' "$PULL_SECRET_FILE" >/dev/null \
    || { echo "Error: ${PULL_SECRET_FILE} is not a pull secret (no .auths)." >&2; exit 1; }

# --- bastion AMI: newest Red Hat RHEL <major> for the region ---------------------
case "${BASTION_RHEL_VERSION:-9}" in 9|10) ;; *) echo "Error: BASTION_RHEL_VERSION must be 9 or 10." >&2; exit 1 ;; esac
if [ -z "${BASTION_AMI_ID:-}" ]; then
    BASTION_AMI_ID="$(latest_rhel_ami "$BASTION_RHEL_VERSION")"
    [ -n "$BASTION_AMI_ID" ] && [ "$BASTION_AMI_ID" != "None" ] \
        || { echo "Error: no RHEL ${BASTION_RHEL_VERSION} AMI found in ${REGION}; set BASTION_AMI_ID." >&2; exit 1; }
fi
BASTION_AMI_NAME="$(aws ec2 describe-images --image-ids "$BASTION_AMI_ID" --query 'Images[0].Name' --output text)"
echo "==> Bastion AMI: ${BASTION_AMI_ID} (${BASTION_AMI_NAME})"
# Squid and registry nodes: newest RHEL 9 AMI unless NODE_AMI_ID is set (CF-13). They stay on
# RHEL 9: mirror-registry on RHEL 9 is the validated path.
if [ -z "${NODE_AMI_ID:-}" ]; then
    NODE_AMI_ID="$(latest_rhel_ami "${NODE_RHEL_VERSION:-9}")"
    [ -n "$NODE_AMI_ID" ] && [ "$NODE_AMI_ID" != "None" ] \
        || { echo "Error: no RHEL ${NODE_RHEL_VERSION:-9} AMI found in ${REGION}; set NODE_AMI_ID." >&2; exit 1; }
fi
echo "==> Squid/registry AMI: ${NODE_AMI_ID} ($(aws ec2 describe-images --image-ids "$NODE_AMI_ID" --query 'Images[0].Name' --output text))"

# --- client tool builds for the bastion's RHEL version ---------------------------
# oc/kubectl and ccoctl come per RHEL build (rhel8/rhel9 today), oc-mirror from
# pub/cgw/oc-mirror/. A RHEL 10 bastion gets rhel10 builds once they exist on the
# mirror, otherwise the rhel9 ones (whether those run on RHEL 10: AGENTS.md B-2).
CLIENT_BUILD="rhel${BASTION_RHEL_VERSION}"
OCP_CLIENTS="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}"
have_url() { curl -fsSIL --max-time 20 -o /dev/null "$1"; }
if [ "$CLIENT_BUILD" = "rhel10" ] && ! have_url "${OCP_CLIENTS}/ccoctl-linux-rhel10-${OCP_VERSION}.tar.gz"; then
    echo "    Note: no rhel10 builds of oc/ccoctl for ${OCP_VERSION}; the RHEL 10 bastion gets the rhel9 builds (AGENTS.md B-2)."
    CLIENT_BUILD="rhel9"
fi
OC_MIRROR_URL="https://mirror.openshift.com/pub/cgw/oc-mirror/latest/oc-mirror-${CLIENT_BUILD}-linux-amd64.tar.gz"
for u in "${OCP_CLIENTS}/openshift-client-linux-amd64-${CLIENT_BUILD}-${OCP_VERSION}.tar.gz" \
         "${OCP_CLIENTS}/ccoctl-linux-${CLIENT_BUILD}-${OCP_VERSION}.tar.gz" \
         "${OCP_CLIENTS}/openshift-install-rhel9-amd64.tar.gz" "$OC_MIRROR_URL"; do
    have_url "$u" || { echo "Error: not found on the mirror: ${u}" >&2; exit 1; }
done
echo "==> Bastion tools: ${CLIENT_BUILD} builds of oc/kubectl, ccoctl and oc-mirror; openshift-install rhel9"

# --- SSH source ------------------------------------------------------------------
if [ -z "${ALLOWED_SSH_CIDR:-}" ]; then
    my_ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')" \
        || { echo "Error: cannot determine this machine's public IP; set ALLOWED_SSH_CIDR." >&2; exit 1; }
    ALLOWED_SSH_CIDR="${my_ip}/32"
fi

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
    --arg ami "$BASTION_AMI_ID" --arg nami "$NODE_AMI_ID" --arg ssh "$ALLOWED_SSH_CIDR" \
    --arg cb "$CLIENT_BUILD" --arg ocm "$OC_MIRROR_URL" \
    --rawfile ps "$PULL_SECRET_FILE" '
    [ {ParameterKey:"VpcCidr",               ParameterValue:$cidr},
      {ParameterKey:"AvailabilityZoneCount", ParameterValue:$azs},
      {ParameterKey:"SubnetBits",            ParameterValue:$bits},
      {ParameterKey:"KeyName",               ParameterValue:$key},
      {ParameterKey:"OpenShiftVersion",      ParameterValue:$ver},
      {ParameterKey:"NATInstanceType",       ParameterValue:$nat},
      {ParameterKey:"BastionInstanceType",   ParameterValue:$bas},
      {ParameterKey:"RegistryInstanceType",  ParameterValue:$reg},
      {ParameterKey:"BastionAmiId",          ParameterValue:$ami},
      {ParameterKey:"NodeAmiId",             ParameterValue:$nami},
      {ParameterKey:"AllowedSshCidr",        ParameterValue:$ssh},
      {ParameterKey:"ClientRhelBuild",       ParameterValue:$cb},
      {ParameterKey:"OcMirrorUrl",           ParameterValue:$ocm},
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
    existing_ami="$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='BastionImageId'].OutputValue" --output text 2>/dev/null || true)"
    if [ -n "$existing_ami" ] && [ "$existing_ami" != "None" ] && [ "$existing_ami" != "$BASTION_AMI_ID" ]; then
        echo "    Note: the existing bastion runs ${existing_ami}, not ${BASTION_AMI_ID}. The bastion's RHEL version"
        echo "    is fixed at creation; delete and recreate the stack to change it."
    fi
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
