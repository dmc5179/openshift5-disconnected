# shellcheck shell=bash
# lib-aws-target.sh - work out which AWS environment we are building for.
#
# Most customers run in AWS GovCloud or the ISO / ISO-B (secret / top secret)
# partitions, not commercial. Behaviour differs, notably:
#   - ISO / ISO-B: network load balancers do not support security groups. The
#     OpenShift installer (5.0, pkg/asset/manifests/aws/cluster.go) always builds
#     the API load balancer as an NLB with an "apiserver-lb" security group role
#     and has no ISO special case, so an ISO install needs a workaround.
#   - ISO / ISO-B: custom CA bundle for the AWS APIs (additionalTrustBundle),
#     no published RHCOS AMIs (platform.aws.amiID), private clusters.
#   - GovCloud: its own partition and endpoints; RHCOS AMIs are published.
#
# Usage, after secrets/aws.env is sourced:
#     . "${ROOT}/scripts/lib-aws-target.sh"
#     resolve_aws_target            # sets AWS_PARTITION, TARGET_ENV, TARGET_IS_ISO
#
# TARGET_ENV (cluster.env or environment) chooses the behaviour:
#   auto        (default) from the partition of the credentials
#   commercial | govcloud | iso | isob
#               force a behaviour. Setting iso or isob while the credentials are
#               commercial SIMULATES the ISO constraints in a commercial account.

resolve_aws_target() {
    local arn
    arn="$(aws sts get-caller-identity --query Arn --output text)" || {
        echo "Error: cannot read the caller identity; check secrets/aws.env." >&2; return 1; }
    # arn:<partition>:iam::<account>:...
    AWS_PARTITION="$(printf '%s' "$arn" | cut -d: -f2)"

    local detected
    case "$AWS_PARTITION" in
        aws)        detected="commercial" ;;
        aws-us-gov) detected="govcloud" ;;
        aws-iso)    detected="iso" ;;
        aws-iso-b)  detected="isob" ;;
        *) echo "Error: unknown AWS partition '${AWS_PARTITION}' (from ${arn})." >&2; return 1 ;;
    esac

    TARGET_ENV="${TARGET_ENV:-auto}"
    case "$TARGET_ENV" in
        auto) TARGET_ENV="$detected"; TARGET_SIMULATED=0 ;;
        commercial|govcloud|iso|isob)
            if [ "$TARGET_ENV" = "$detected" ]; then TARGET_SIMULATED=0; else TARGET_SIMULATED=1; fi ;;
        *) echo "Error: TARGET_ENV must be auto, commercial, govcloud, iso or isob (got '${TARGET_ENV}')." >&2; return 1 ;;
    esac

    case "$TARGET_ENV" in iso|isob) TARGET_IS_ISO=1 ;; *) TARGET_IS_ISO=0 ;; esac
    export AWS_PARTITION TARGET_ENV TARGET_IS_ISO TARGET_SIMULATED

    if [ "$TARGET_SIMULATED" -eq 1 ]; then
        echo "==> Target: ${TARGET_ENV} behaviour SIMULATED in partition ${AWS_PARTITION} (${detected})"
    else
        echo "==> Target: ${TARGET_ENV} (partition ${AWS_PARTITION}, detected from credentials)"
    fi
}

# latest_rhel_ami <major> [owner]: newest Red Hat Hourly2-GP3 x86_64 AMI for a
# RHEL major, preferring the highest minor release (10.2 over a newer-dated 10.0
# refresh), then the newest build date.
latest_rhel_ami() {
    local major="$1" owner="${2:-}"
    if [ -z "$owner" ]; then
        case "${AWS_PARTITION:-aws}" in
            aws)        owner="309956199498" ;;
            aws-us-gov) owner="219670896067" ;;
            *) echo "latest_rhel_ami: no Red Hat AMI owner known for partition ${AWS_PARTITION}" >&2; return 1 ;;
        esac
    fi
    aws ec2 describe-images --owners "$owner" \
        --filters "Name=name,Values=RHEL-${major}.*_HVM-*-x86_64-*-Hourly2-GP3" "Name=state,Values=available" \
        --query 'Images[].[Name,ImageId]' --output text | sort -V | tail -1 | awk '{print $2}'
}
