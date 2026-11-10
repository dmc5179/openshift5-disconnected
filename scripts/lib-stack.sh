# shellcheck shell=bash
# lib-stack.sh - read the VPC stack outputs and reach its hosts over SSH.
#
# After cluster.env and secrets/aws.env are sourced:
#     . "${ROOT}/scripts/lib-stack.sh"
#     stack_ready                   # sets BASTION_IP, REGISTRY_HOST, ...
#     bastion_ssh  'command'        # ec2-user on the bastion
#     registry_ssh 'command'        # ec2-user on the registry node, via the bastion
#     registry_scp src... ec2-user@REGISTRY:dst   (scp through the bastion)
#     rhel10_ssh   'command'        # cloud-user on the private RHEL 10 FIPS install
#                                   # host (scripts/16-rhel10-host.sh create --private), via the bastion
#     install_ssh / install_scp / install_host_name / install_host_ip
#                                   # whichever host INSTALL_HOST names
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
    # Live public IP: the bastion has no Elastic IP, so a stop/start (scripts/70-power.sh)
    # changes it while the stack output keeps the creation-time address.
    BASTION_IP="$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-name,Values=${VPC_STACK_NAME}" \
        "Name=tag:aws:cloudformation:logical-id,Values=HelperInstance" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)"
    case "$BASTION_IP" in ''|None) BASTION_IP="$(stack_output BastionPublicIp)" ;; esac
    REGISTRY_HOST="$(stack_output RegistryPrivateDnsName)"
    REGISTRY_IP="$(stack_output RegistryPrivateIp)"
    [ -f "${SSH_PRIVATE_KEY:-}" ] || { echo "Error: SSH_PRIVATE_KEY not found: ${SSH_PRIVATE_KEY:-unset}" >&2; return 1; }
    SSH_OPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts.${VPC_STACK_NAME}"
              -o ConnectTimeout=15 -o BatchMode=yes -o ServerAliveInterval=30 -i "$SSH_PRIVATE_KEY")
    # -J would not pass the options above to the jump connection; ProxyCommand does.
    PROXY_OPT=(-o "ProxyCommand=ssh ${SSH_OPTS[*]} -W %h:%p ec2-user@${BASTION_IP}")
    export BASTION_IP REGISTRY_HOST REGISTRY_IP
}

bastion_ssh()  { ssh "${SSH_OPTS[@]}" "ec2-user@${BASTION_IP}" "$@"; }
registry_ssh() { ssh "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "ec2-user@${REGISTRY_HOST}" "$@"; }
registry_scp() { scp -q "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "$@"; }

# RHEL 10 FIPS hosts launched next to the stack by scripts/16-rhel10-host.sh,
# found by their tags (ocp5:stack=<VPC_STACK_NAME>, ocp5:role=<role>):
#   rhel10-fips-host          public subnet, SSH from this workstation (tests)
#   rhel10-fips-install-host  private subnet, SSH via the bastion (INSTALL_HOST=rhel10)
# shellcheck disable=SC2034  # used by scripts/16-rhel10-host.sh
RHEL10_PUBLIC_ROLE="rhel10-fips-host"
RHEL10_INSTALL_ROLE="rhel10-fips-install-host"
rhel10_host_lookup() {   # rhel10_host_lookup <role>  ->  "<id> <private ip> <public ip|None> <state>" or nothing
    aws ec2 describe-instances \
        --filters "Name=tag:ocp5:role,Values=$1" "Name=tag:ocp5:stack,Values=${VPC_STACK_NAME}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,PublicIpAddress,State.Name]' \
        --output text | head -1
}
# Sets RHEL10_HOST_IP (private IP of the install host). Call it directly, not in
# $(...), so the value stays cached in the calling shell.
rhel10_host_resolve() {
    [ -n "${RHEL10_HOST_IP:-}" ] && return 0
    local id ip
    read -r id ip _ _ <<<"$(rhel10_host_lookup "$RHEL10_INSTALL_ROLE")"
    if [ -z "${id:-}" ] || [ -z "${ip:-}" ] || [ "$ip" = "None" ]; then
        echo "Error: no RHEL 10 install host (tag ocp5:role=${RHEL10_INSTALL_ROLE}); run scripts/16-rhel10-host.sh create --private." >&2
        return 1
    fi
    RHEL10_HOST_IP="$ip"
}
rhel10_ssh() { rhel10_host_resolve || return 1; ssh "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "${RHEL10_HOST_USER:-cloud-user}@${RHEL10_HOST_IP}" "$@"; }

# The host that runs openshift-install (INSTALL_HOST in cluster.env: registry|bastion|rhel10).
install_host_name() {
    case "${INSTALL_HOST:-registry}" in
        bastion) echo "$BASTION_IP" ;;
        rhel10)  rhel10_host_resolve && echo "${RHEL10_HOST_IP} (RHEL 10 FIPS, private subnet)" ;;
        *)       echo "$REGISTRY_HOST" ;;
    esac
}
# Private IP the install host's traffic reaches Squid from (empty for the bastion,
# whose egress does not go through Squid).
install_host_ip() {
    case "${INSTALL_HOST:-registry}" in
        bastion) echo "" ;;
        rhel10)  rhel10_host_resolve && echo "$RHEL10_HOST_IP" ;;
        *)       echo "$REGISTRY_IP" ;;
    esac
}
install_ssh() {
    case "${INSTALL_HOST:-registry}" in
        bastion) bastion_ssh "$@" ;;
        rhel10)  rhel10_ssh "$@" ;;
        *)       registry_ssh "$@" ;;
    esac
}
install_scp() {   # install_scp <local files...> <remote path relative to ~>
    local dest="${*: -1}" n=$(( $# - 1 ))
    case "${INSTALL_HOST:-registry}" in
        bastion) scp -q "${SSH_OPTS[@]}" "${@:1:$n}" "ec2-user@${BASTION_IP}:${dest}" ;;
        rhel10)  rhel10_host_resolve || return 1
                 scp -q "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "${@:1:$n}" "${RHEL10_HOST_USER:-cloud-user}@${RHEL10_HOST_IP}:${dest}" ;;
        *)       scp -q "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "${@:1:$n}" "ec2-user@${REGISTRY_HOST}:${dest}" ;;
    esac
}
