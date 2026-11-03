# shellcheck shell=bash
# lib-stack.sh - read the VPC stack outputs and reach its hosts over SSH.
#
# After cluster.env and secrets/aws.env are sourced:
#     . "${ROOT}/scripts/lib-stack.sh"
#     stack_ready                   # sets BASTION_IP, REGISTRY_HOST, ...
#     bastion_ssh  'command'        # ec2-user on the bastion
#     registry_ssh 'command'        # ec2-user on the registry node, via the bastion
#     registry_scp src... ec2-user@REGISTRY:dst   (scp through the bastion)
#
# Host keys are kept in ~/.ssh/known_hosts.<VPC_STACK_NAME>, separate from the
# user's own known_hosts, because the stack's addresses are reused.

stack_output() {
    aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

stack_ready() {
    local status
    status="$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
              --query 'Stacks[0].StackStatus' --output text 2>/dev/null)" \
        || { echo "Error: stack ${VPC_STACK_NAME} does not exist; run scripts/10-deploy-vpc.sh." >&2; return 1; }
    case "$status" in CREATE_COMPLETE|UPDATE_COMPLETE) ;; *) echo "Error: stack is ${status}." >&2; return 1 ;; esac
    BASTION_IP="$(stack_output BastionPublicIp)"
    REGISTRY_HOST="$(stack_output RegistryPrivateDnsName)"
    REGISTRY_IP="$(stack_output RegistryPrivateIp)"
    [ -f "${SSH_PRIVATE_KEY:-}" ] || { echo "Error: SSH_PRIVATE_KEY not found: ${SSH_PRIVATE_KEY:-unset}" >&2; return 1; }
    SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts.${VPC_STACK_NAME}"
              -o ConnectTimeout=15 -o BatchMode=yes -o ServerAliveInterval=30 -i "$SSH_PRIVATE_KEY")
    # -J would not pass the options above to the jump connection; ProxyCommand does.
    PROXY_OPT=(-o "ProxyCommand=ssh ${SSH_OPTS[*]} -W %h:%p ec2-user@${BASTION_IP}")
    export BASTION_IP REGISTRY_HOST REGISTRY_IP
}

bastion_ssh()  { ssh "${SSH_OPTS[@]}" "ec2-user@${BASTION_IP}" "$@"; }
registry_ssh() { ssh "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "ec2-user@${REGISTRY_HOST}" "$@"; }
registry_scp() { scp -q "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "$@"; }

# The host that runs openshift-install (INSTALL_HOST in cluster.env: registry|bastion).
install_host_name() { if [ "${INSTALL_HOST:-registry}" = "bastion" ]; then echo "$BASTION_IP"; else echo "$REGISTRY_HOST"; fi; }
install_ssh() { if [ "${INSTALL_HOST:-registry}" = "bastion" ]; then bastion_ssh "$@"; else registry_ssh "$@"; fi; }
install_scp() {   # install_scp <local files...> <remote path relative to ~>
    local dest="${*: -1}" n=$(( $# - 1 ))
    if [ "${INSTALL_HOST:-registry}" = "bastion" ]; then
        scp -q "${SSH_OPTS[@]}" "${@:1:$n}" "ec2-user@${BASTION_IP}:${dest}"
    else
        scp -q "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "${@:1:$n}" "ec2-user@${REGISTRY_HOST}:${dest}"
    fi
}
