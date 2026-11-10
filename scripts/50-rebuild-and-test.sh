#!/usr/bin/env bash
#
# 50-rebuild-and-test.sh - tear down and rebuild the whole environment, then run
#                          the end-to-end disconnected test sequence unattended.
#
# Usage: scripts/50-rebuild-and-test.sh [--from PHASE] [--only PHASE] [--yes] [--strict-egress]
#
# Phases (in order):
#   teardown     destroy the cluster (from the host that installed it), delete the
#                ccoctl STS resources, delete the stack (and non-stack instances,
#                including the RHEL 10 hosts of scripts/16-rhel10-host.sh)
#   deploy       scripts/10-deploy-vpc.sh
#   validate     template checks: IMDSv2 enforced on every host, scoped S3 access,
#                Squid allowlist and SNI log, iptables + squid survive a reboot
#   rhel10host   TEST_INSTALL_HOST=rhel10 only (otherwise skipped): launch the RHEL
#                10 FIPS image-mode install host in the PRIVATE subnet and prep it
#                (scripts/16-rhel10-host.sh --private create + prep)
#   mirror       bastion mirror-to-mirror: OCP_CHANNEL with the upgrade path from
#                MIRROR_UPGRADE_FROM, graph data, MIRROR_TEST_OPERATORS, and the
#                KubeVirt boot image when MIRROR_KUBEVIRT=true (reports which of the
#                RHCOS 9 / RHCOS 10 KubeVirt digests were copied, N-11)
#   creds        scripts/30-fetch-mirror-credentials.sh (CA + mirror pull secret)
#   fipshost     put the install host (TEST_INSTALL_HOST) into FIPS mode; for
#                rhel10 only verify fips_enabled=1 (FIPS from installation)
#   sts          scripts/20-prepare-sts.sh
#   config       scripts/generate-install-config.sh (FIPS, DISABLE_SAMPLES, day 0)
#   extract      scripts/38-extract-installer.sh: openshift-install-fips from the mirror
#   install      install with the extracted installer, wait for completion
#   post         scripts/45-post-install.sh resources, cleanup, osus (then records
#                the time the CVO points at the local OSUS), operators, status
#   checks       read-only cluster checks: node timers and the 00:00 UTC journal
#                (N-12 data.iana.org), runC pre-upgrade checklist (F8), Lightspeed /
#                AI state (A2/J5), fapolicyd denials on the install host (B-5)
#   upgrade      TEST_SCENARIO=upgrade only (otherwise skipped): AI/runC/catalog
#                snapshot, admin-acks for the admin-gates, `oc adm upgrade --to
#                OCP_VERSION` through the local OSUS, wait, then signature
#                verification (history[0].verified), operators, node OS / stream,
#                and the same snapshot after (J8, D6, J5)
#   audit        Squid egress for the run, classified by source (cluster nodes,
#                install host, registry node, other) and destination, ending with
#                EGRESS VERDICT: PASS (only known exceptions) or FAIL (unexpected: ...)
#
# Environment:
#   TEST_INSTALL_HOST      registry (default) | bastion | rhel10 - the host that
#                          extracts the installer and runs install and post
#   TEST_SCENARIO          install (default): install OCP_VERSION.
#                          upgrade: mirror MIRROR_UPGRADE_FROM -> OCP_VERSION, install
#                          MIRROR_UPGRADE_FROM (osImageStream left out: feature-gated in
#                          4.22), install lightspeed-operator etc. from the v4.22 catalog
#                          (MIRROR_UPGRADE_FROM_OPERATORS), then the upgrade phase
#   UPGRADE_TIMEOUT_MIN    upgrade phase wait (default 180)
#   MIRROR_UPGRADE_FROM    4.22.z start of the mirrored upgrade path (default 4.22.22)
#   MIRROR_TEST_OPERATORS  operators to mirror (default: OSUS, cert-manager, lightspeed)
#   MIRROR_KUBEVIRT        cluster.env (default true): kubeVirtContainer in the ISC
#   EGRESS_CVO_CUTOFF      epoch seconds; api.openshift.com from the cluster before it
#                          counts as install-time CVO. Default: logs/.50-osus-done,
#                          written by the post phase; without it, all of it counts
#   --strict-egress        make the audit phase fail when the verdict is FAIL
#
# Every phase logs to logs/50-<phase>-<time>.log; the egress verdict also goes to
# logs/50-egress-verdict-<time>.txt. Stops at the first failure; rerun with
# --from <phase> after fixing it.
#
# Examples:
#   TEST_INSTALL_HOST=rhel10 scripts/50-rebuild-and-test.sh --yes          # RHEL 10 FIPS install host
#   TEST_SCENARIO=upgrade scripts/50-rebuild-and-test.sh --yes             # 4.22.z -> 5.0 upgrade
#   FAPOLICYD_MODE=enforce-with-trust scripts/50-rebuild-and-test.sh --yes # install host under fapolicyd (B-5)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASES=(teardown deploy validate rhel10host mirror creds fipshost sts config extract install post checks upgrade audit)
FROM="${PHASES[0]}"; ONLY=""; YES=0; STRICT_EGRESS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --yes)  YES=1; shift ;;
        --strict-egress) STRICT_EGRESS=1; shift ;;
        *) sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 2 ;;
    esac
done

export TEST_INSTALL_HOST="${TEST_INSTALL_HOST:-registry}"
case "$TEST_INSTALL_HOST" in registry|bastion|rhel10) ;; *) echo "TEST_INSTALL_HOST must be registry, bastion or rhel10." >&2; exit 2 ;; esac
for p in "$FROM" ${ONLY:+"$ONLY"}; do
    [[ " ${PHASES[*]} " == *" $p "* ]] || { echo "Unknown phase '$p' (phases: ${PHASES[*]})." >&2; exit 2; }
done
export MIRROR_UPGRADE_FROM="${MIRROR_UPGRADE_FROM:-4.22.22}"
export MIRROR_TEST_OPERATORS="${MIRROR_TEST_OPERATORS:-cincinnati-operator:v1,openshift-cert-manager-operator:stable-v1,lightspeed-operator:stable}"
export TEST_SCENARIO="${TEST_SCENARIO:-install}"
case "$TEST_SCENARIO" in install|upgrade) ;; *) echo "TEST_SCENARIO must be install or upgrade." >&2; exit 2 ;; esac
if [ "$TEST_SCENARIO" = upgrade ]; then
    # Install the 4.22.z start of the mirrored path; the v4.22 catalog provides the
    # operators installed before the upgrade (OSUS, cert-manager, lightspeed for J5).
    export INSTALL_VERSION="$MIRROR_UPGRADE_FROM" OS_IMAGE_STREAM=none
    export MIRROR_OPERATORS_UPGRADE_FROM="${MIRROR_UPGRADE_FROM_OPERATORS:-$MIRROR_TEST_OPERATORS}"
fi
mkdir -p "${ROOT}/logs"
# Start of the egress-audit window: set on a full run, kept when resuming.
# Also forget the previous run's OSUS cutoff on a full run.
if { [ -z "$ONLY" ] || [ "$ONLY" = "${PHASES[0]}" ]; } && { [ "$FROM" = "${PHASES[0]}" ] || [ ! -s "${ROOT}/logs/.50-run-start" ]; }; then
    date -u +%s > "${ROOT}/logs/.50-run-start"; rm -f "${ROOT}/logs/.50-osus-done"
fi

env_load() {
    # shellcheck source=../cluster.env
    . "${ROOT}/cluster.env"
    # shellcheck disable=SC1091
    . "${ROOT}/secrets/aws.env"
    . "${ROOT}/scripts/lib-stack.sh"
}
proxy_ssh() { ssh "${SSH_OPTS[@]}" "${PROXY_OPT[@]}" "ec2-user@$(stack_output ProxyPrivateIp)" "$@"; }

phase_teardown() {
    env_load
    [ "$YES" -eq 1 ] || { read -r -p "Destroy cluster ${CLUSTER_NAME} and stack ${VPC_STACK_NAME}? [y/N] " a; [ "$a" = y ]; }
    if stack_ready 2>/dev/null; then
        # rhel10: the private RHEL 10 install host, if it exists (90-destroy-vpc.sh
        # terminates it afterwards, by its ocp5:stack tag).
        for h in bastion registry rhel10; do
            if INSTALL_HOST=$h install_ssh "test -e ~/ocp-install/${CLUSTER_NAME}/metadata.json" 2>/dev/null; then
                echo "==> Destroying cluster ${CLUSTER_NAME} from the ${h}"
                # Prefer the installer that installed it (extracted from the mirror).
                INSTALL_HOST=$h install_ssh "cd ~/ocp-install/${CLUSTER_NAME}; set -a; . ~/ocp-install/aws.env; set +a;
                    bin=~/bin-mirror/openshift-install-fips; [ -x \$bin ] || bin=\$(command -v openshift-install);
                    \$bin destroy cluster --dir . --log-level=info 2>&1 | tail -3"
            fi
        done
    fi
    echo "==> Deleting ccoctl STS resources (${CCOCTL_NAME})"
    "${ROOT}/bin/ccoctl" aws delete --name "$CCOCTL_NAME" --region "$AWS_DEFAULT_REGION" 2>&1 | tail -3 || true
    "${ROOT}/scripts/90-destroy-vpc.sh" --yes
}

phase_deploy() { "${ROOT}/scripts/10-deploy-vpc.sh"; }

phase_validate() {
    env_load; stack_ready
    echo "==> IMDSv2: unauthenticated (v1) metadata calls must fail, token calls must work"
    for h in bastion registry proxy; do
        case $h in bastion) f=bastion_ssh ;; registry) f=registry_ssh ;; proxy) f=proxy_ssh ;; esac
        $f 'v1=$(curl -s -o /dev/null -w %{http_code} http://169.254.169.254/latest/meta-data/instance-id);
            t=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60");
            v2=$(curl -s -o /dev/null -w %{http_code} -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/meta-data/instance-id);
            echo "v1=$v1 v2=$v2"' | sed "s/^/    ${h}: /"
    done
    echo "==> Scoped S3: the staging bucket works, listing all buckets is denied"
    bastion_ssh "aws s3 ls s3://$(stack_output S3BucketName) >/dev/null && echo '    staging bucket: OK'; aws s3 ls >/dev/null 2>&1 && echo '    s3 ls (all buckets): ALLOWED (unexpected)' || echo '    s3 ls (all buckets): denied (expected)'"
    echo "==> Squid: allowlist, explicit-proxy ACL, SNI log"
    registry_ssh 'for u in https://quay.io/v2/ https://registry.redhat.io/v2/ https://sts.us-east-2.amazonaws.com/; do printf "    %-40s %s\n" $u "$(curl -s -m 10 -o /dev/null -w %{http_code} $u || echo blocked)"; done'
    proxy_ssh 'printf "    3128 CONNECT google.com: %s\n" "$(curl -s -m 10 -o /dev/null -w %{http_code} -x http://127.0.0.1:3128 https://www.google.com/ || echo denied)"; sudo tail -3 /var/log/squid/access.log | sed "s/^/    /"'
    echo "==> Squid node reboot: rules and service persist"
    proxy_ssh 'sudo systemctl reboot' || true
    sleep 30
    for _ in $(seq 1 30); do out="$(proxy_ssh 'echo "redirects=$(sudo iptables -t nat -S | grep -c REDIRECT) squid=$(systemctl is-active squid)"' 2>/dev/null)" && break; sleep 10; done
    echo "    after reboot: ${out:-unreachable}"
    registry_ssh 'printf "    quay.io after reboot: %s\n" "$(curl -s -m 10 -o /dev/null -w %{http_code} https://quay.io/v2/ || echo blocked)"'

    echo "==> Egress profile ${EGRESS_PROFILE:-regional} (CF-17): allowlist and probes from the registry node"
    proxy_ssh 'sed "s/^/    allow: /" /etc/squid/whitelist.txt'
    # 000 = blocked by Squid (terminated), anything else = reached the endpoint.
    registry_ssh "for u in https://sts.${AWS_DEFAULT_REGION}.amazonaws.com/ https://ec2.${AWS_DEFAULT_REGION}.amazonaws.com/ https://iam.amazonaws.com/ https://route53.amazonaws.com/ https://sts.us-west-2.amazonaws.com/ https://s3.us-west-2.amazonaws.com/ https://d1.cloudfront.net/; do
        printf '    %-45s %s\n' \$u \"\$(curl -s -m 10 -o /dev/null -w %{http_code} \$u)\"; done"
    echo "    expected with regional: the first four answer (non-000), us-west-2 and cloudfront 000"

    echo "==> Pull secret on the bastion (CF-9, source ${PULL_SECRET_SOURCE:-ssm})"
    bastion_ssh 'f=~/pull-secret.json; printf "    %s mode=%s auths=%s\n" $f "$(stat -c %a $f)" "$(jq -r ".auths|keys|length" $f)"; ls /tmp/pull-secret.json 2>/dev/null && echo "    /tmp copy present (unexpected)" || echo "    no /tmp copy"'
    local bid; bid="$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-name,Values=${VPC_STACK_NAME}" "Name=tag:aws:cloudformation:logical-id,Values=HelperInstance" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)"
    if aws ec2 describe-instance-attribute --instance-id "$bid" --attribute userData --query UserData.Value --output text | base64 -d | grep -q '"auths"'; then
        echo "    bastion user data CONTAINS a pull secret"; [ "${PULL_SECRET_SOURCE:-ssm}" = ssm ] && { echo "Error: SSM mode but the secret is in the user data." >&2; return 1; }
    else echo "    bastion user data: no pull secret"; fi
    bastion_ssh "aws ssm get-parameters-by-path --path / --max-results 5 >/dev/null 2>&1 && echo '    SSM: other parameters readable (unexpected)' || echo '    SSM: only the pull secret parameter is readable (expected)'"

    echo "==> fapolicyd (FAPOLICYD_MODE=${FAPOLICYD_MODE:-disable}, B-5)"
    for h in bastion registry proxy; do
        case $h in bastion) f=bastion_ssh ;; registry) f=registry_ssh ;; proxy) f=proxy_ssh ;; esac
        $f 'printf "%s enabled=%s\n" "$(systemctl is-active fapolicyd 2>/dev/null)" "$(systemctl is-enabled fapolicyd 2>/dev/null)"' | sed "s/^/    ${h}: /"
    done
}

phase_rhel10host() {
    if [ "$TEST_INSTALL_HOST" != rhel10 ]; then echo "    TEST_INSTALL_HOST=${TEST_INSTALL_HOST}: no RHEL 10 install host needed"; return 0; fi
    "${ROOT}/scripts/16-rhel10-host.sh" --private create
    "${ROOT}/scripts/16-rhel10-host.sh" --private prep
}

phase_mirror() {
    env_load; stack_ready
    echo "==> ImageSetConfiguration: ${OCP_CHANNEL} ${MIRROR_UPGRADE_FROM} -> ${OCP_VERSION}, operators ${MIRROR_TEST_OPERATORS}"
    OCP_UPGRADE_FROM="$MIRROR_UPGRADE_FROM" MIRROR_OPERATORS="$MIRROR_TEST_OPERATORS" \
        MIRROR_OPERATORS_UPGRADE_FROM="${MIRROR_OPERATORS_UPGRADE_FROM:-}" \
        "${ROOT}/scripts/generate-imageset-config.sh" -o "${ROOT}/imageset-config.yaml"
    scp -q "${SSH_OPTS[@]}" "${ROOT}/imageset-config.yaml" "${ROOT}/scripts/bastion-mirror-to-mirror.sh" "ec2-user@${BASTION_IP}:"
    # Quay init password from the registry node's install log, passed via a mode-600 file.
    registry_ssh "sudo sh -c 'cat /opt/mirror-registry-install/install.log /tmp/mirror-registry-install.log 2>/dev/null' | grep -oP 'credentials \(init, \K[^)]+' | tail -1" \
        | bastion_ssh 'umask 077; cat > ~/.mirror-pass'
    registry_ssh 'sudo cat /opt/quay-root/quay-rootCA/rootCA.pem' | bastion_ssh 'cat > ~/mirror-rootCA.pem'
    local t0; t0=$(date +%s)
    bastion_ssh "export MIRROR_PASSWORD=\$(cat ~/.mirror-pass); rm -f ~/.mirror-pass;
        ./bastion-mirror-to-mirror.sh --ca-file ~/mirror-rootCA.pem --namespace ${MIRROR_NAMESPACE} ${REGISTRY_HOST} imageset-config.yaml > m2m.out 2>&1; rc=\$?;
        tail -12 m2m.out; exit \$rc"
    echo "    mirror-to-mirror took $(( $(date +%s) - t0 )) s"
    bastion_ssh 'ls ~/oc-mirror/m2m/working-dir/cluster-resources/ | sed "s/^/    /"; du -sh ~/oc-mirror ~/.oc-mirror 2>/dev/null | sed "s/^/    /"'
    [ "${MIRROR_KUBEVIRT:-false}" = true ] && kubevirt_report
    return 0
}

# N-11: which KubeVirt boot images (from the payload's coreos-bootimages ConfigMap,
# all architectures and streams) did oc-mirror copy? Expected with the bug: only
# rhel-9.8 x86_64 (b58ab403...), not rhel-10.2 x86_64 (9cf09e8e...).
kubevirt_report() {
    echo "==> KubeVirt boot images in this mirror run (kubeVirtContainer: true; N-11)"
    bastion_ssh 'bash -s' <<'REMOTE'
w=~/oc-mirror/m2m/working-dir
log=$(ls -t "$w"/logs/oc-mirror-*.log 2>/dev/null | head -1)
cm=$(ls "$w"/hold-release/ocp-release/*/release-manifests/0000_50_installer_coreos-bootimages.yaml 2>/dev/null | sort -V | tail -1)
echo "    oc-mirror log:     ${log:-none}"
echo "    coreos-bootimages: ${cm:-none}"
[ -n "$cm" ] && awk -F'"' '/"image": .*coreos-kubevirt"/{tag=$4} /"digest-ref":/ && tag!=""{print tag, $4; tag=""}' "$cm" | sort -u |
while read -r tag ref; do
    d=${ref##*@sha256:}
    if grep -q "Success copying .*@sha256:${d}" "$log" 2>/dev/null; then s=MIRRORED
    elif grep -qF "${tag}" "$log" 2>/dev/null; then s=tag-in-log
    else s=not-mirrored; fi
    case $d in b58ab403*) k=" <- x86_64 rhel-9";; 9cf09e8e*) k=" <- x86_64 rhel-10";; *) k="";; esac
    printf "    %-13s %-28s sha256:%s%s\n" "$s" "${tag##*:}" "${d:0:12}" "$k"
done
echo "    oc-mirror log lines mentioning kubevirt: $(grep -ci kubevirt "$log" 2>/dev/null || true)"
grep -i kubevirt "$log" 2>/dev/null | head -5 | cut -c1-220 | sed 's/^/      /'
REMOTE
}

phase_creds()    { "${ROOT}/scripts/30-fetch-mirror-credentials.sh"; }
phase_fipshost() {
    if [ "$TEST_INSTALL_HOST" = rhel10 ]; then
        # RHEL 10 enables FIPS only at installation (the AMI); no reboot, just verify.
        env_load; stack_ready
        local f; f="$(INSTALL_HOST=rhel10 install_ssh 'cat /proc/sys/crypto/fips_enabled')"
        echo "==> rhel10 install host: fips_enabled=${f}, policy $(INSTALL_HOST=rhel10 install_ssh 'update-crypto-policies --show')"
        [ "$f" = 1 ] || { echo "Error: the RHEL 10 install host is not in FIPS mode." >&2; return 1; }
        return 0
    fi
    "${ROOT}/scripts/35-enable-fips-host.sh" "$TEST_INSTALL_HOST"
}
phase_sts()      { "${ROOT}/scripts/20-prepare-sts.sh"; }
phase_config()   { "${ROOT}/scripts/generate-install-config.sh"; yq '{"fips": .fips, "osImageStream": .osImageStream, "publish": .publish, "capabilities": .capabilities}' "${ROOT}/install-config.yaml"; }
phase_extract()  { INSTALL_HOST="$TEST_INSTALL_HOST" "${ROOT}/scripts/38-extract-installer.sh"; }
phase_install() {
    if ! { INSTALL_HOST="$TEST_INSTALL_HOST" INSTALLER_BIN='~/bin-mirror/openshift-install-fips' "${ROOT}/scripts/40-install-cluster.sh" start &&
           INSTALL_HOST="$TEST_INSTALL_HOST" "${ROOT}/scripts/40-install-cluster.sh" wait; }; then
        fapolicyd_report
        return 1
    fi
}

# B-5: fapolicyd denials on the install host (the installer unpacks and runs etcd,
# kube-apiserver and the CAPI providers under <install-dir>/cluster-api/).
fapolicyd_report() {
    env_load; stack_ready >/dev/null
    echo "==> fapolicyd on the install host (${TEST_INSTALL_HOST})"
    INSTALL_HOST="$TEST_INSTALL_HOST" install_ssh 'if systemctl is-active -q fapolicyd 2>/dev/null; then
            echo "    fapolicyd active; denials since boot:"
            sudo journalctl -b -u fapolicyd --no-pager 2>/dev/null | grep -iE "deny|dec=deny" | tail -15 | sed "s/^/      /"
            sudo grep -h "type=FANOTIFY" /var/log/audit/audit.log 2>/dev/null | tail -5 | sed "s/^/      /"
        else echo "    fapolicyd not active"; fi' || true
}
phase_post() {
    local a
    for a in resources cleanup osus; do INSTALL_HOST="$TEST_INSTALL_HOST" "${ROOT}/scripts/45-post-install.sh" "$a"; done
    # From here the CVO asks the local OSUS; api.openshift.com from the cluster after
    # this point is unexpected in the audit.
    date -u +%s > "${ROOT}/logs/.50-osus-done"
    for a in operators status; do INSTALL_HOST="$TEST_INSTALL_HOST" "${ROOT}/scripts/45-post-install.sh" "$a"; done
}
phase_checks() {
    env_load; stack_ready
    local RDIR="ocp-install/${CLUSTER_NAME}"
    ocx() { INSTALL_HOST="$TEST_INSTALL_HOST" install_ssh "export KUBECONFIG=~/${RDIR}/auth/kubeconfig; $*"; }
    echo "==> N-12: timers and the 00:00 UTC window on one worker"
    ocx 'w=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath="{.items[0].metadata.name}");
         oc debug node/$w -q -- chroot /host bash -c "systemctl list-timers --all --no-pager | grep -iE \"anchor|unbound|NEXT\";
           systemctl cat unbound-anchor.timer 2>/dev/null | grep -E \"OnCalendar|Persistent\" || echo \"unbound-anchor.timer: not present\";
           journalctl --since \"\$(date -u +%F) 00:00:00\" --until \"\$(date -u +%F) 00:02:00\" --utc --no-pager 2>/dev/null | grep -iE \"anchor|iana|unbound|dnssec\" | head -10" 2>/dev/null' | sed 's/^/    /'
    echo "    (the journal lines only exist if the cluster has been up across 00:00 UTC)"
    echo "==> F8: runC pre-upgrade checklist (notes/research-runc-rhcos10.md section a)"
    ocx 'echo "    override MCs: $(oc get mc -o name | grep -c generated-crio-default-container-runtime)";
         echo "    ContainerRuntimeConfigs with runc: $(oc get containerruntimeconfig -o jsonpath="{range .items[*]}{.spec.containerRuntimeConfig.defaultRuntime}{\"\\n\"}{end}" 2>/dev/null | grep -c runc)";
         echo "    CO EvaluationConditionsDetected: $(oc get co machine-config -o jsonpath="{.status.conditions[?(@.type==\"EvaluationConditionsDetected\")].status} {.status.conditions[?(@.type==\"EvaluationConditionsDetected\")].reason}")";
         echo "    osimagestream default: $(oc get osimagestream cluster -o jsonpath="{.spec.defaultStream} (status {.status.defaultStream})" 2>/dev/null || echo n/a)"
         oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- curl -s localhost:9090/api/v1/query --data-urlencode "query=container_runtime_crio_default_runtime" 2>/dev/null |
           jq -r ".data.result[] | \"    runtime \(.metric.runtime) on \(.metric.instance)\"" 2>/dev/null'
    ai_snapshot
    fapolicyd_report
}

# A2 / J5: Lightspeed and AI surface on the cluster.
ai_snapshot() {
    echo "==> AI / Lightspeed state"
    ocx 'echo "    console capabilities: $(oc get console.operator cluster -o jsonpath="{.spec.customization.capabilities}")";
         echo "    console plugins: $(oc get console.operator cluster -o jsonpath="{.spec.plugins}")";
         echo "    ConsolePlugins: $(oc get consoleplugins -o name 2>/dev/null | tr "\n" " ")";
         echo "    AI CRDs: $(oc get crd -o name | grep -iE "ols|agentic|lightspeed" | sed "s|.*/||" | tr "\n" " ")";
         echo "    OLSConfig / AgenticOLSConfig objects: $(oc get olsconfig -A --no-headers 2>/dev/null | wc -l) / $(oc get agenticolsconfig -A --no-headers 2>/dev/null | wc -l)";
         echo "    lightspeed CSV: $(oc get csv -n openshift-lightspeed --no-headers 2>/dev/null | awk "{print \$1, \$NF}" | tr "\n" " ")";
         echo "    VAP ai-opt-out installed: $(oc get validatingadmissionpolicy -o name 2>/dev/null | grep -c ai-opt-out)"'
}

phase_upgrade() {
    if [ "$TEST_SCENARIO" != upgrade ]; then echo "    TEST_SCENARIO=${TEST_SCENARIO}: no upgrade test"; return 0; fi
    env_load; stack_ready
    local RDIR="ocp-install/${CLUSTER_NAME}"
    ocx() { INSTALL_HOST="$TEST_INSTALL_HOST" install_ssh "export KUBECONFIG=~/${RDIR}/auth/kubeconfig; $*"; }
    echo "==> Before: $(ocx "oc get clusterversion version -o jsonpath='{.status.desired.version} channel={.spec.channel} upstream={.spec.upstream}'")"
    ai_snapshot
    echo "==> Available updates through the local OSUS"
    ocx 'oc adm upgrade 2>&1 | head -20' | sed 's/^/    /'
    echo "==> Admin gates for this update (acknowledged automatically, listed here)"
    ocx 'oc -n openshift-config-managed get cm admin-gates -o json | jq -r ".data // {} | to_entries[] | \"    \(.key): \(.value)\""
         for k in $(oc -n openshift-config-managed get cm admin-gates -o json | jq -r ".data // {} | keys[]"); do
             oc -n openshift-config patch cm admin-acks --type merge -p "{\"data\":{\"$k\":\"true\"}}" >/dev/null && echo "    acked $k"
         done'
    if [ "$(yq -r '.credentialsMode' "${ROOT}/install-config.yaml")" = Manual ]; then
        # Manual (STS) mode: the CCO keeps Upgradeable=False for a minor upgrade until the
        # new release's CredentialsRequests have credentials and upgradeable-to is set.
        echo "==> Manual credentials for ${OCP_VERSION}: ccoctl create-iam-roles against the existing OIDC provider"
        "${ROOT}/scripts/20-prepare-sts.sh" --upgrade-to "$OCP_VERSION"
        local up="${CLUSTER_DIR}/ccoctl-${OCP_VERSION}/manifests"
        INSTALL_HOST="$TEST_INSTALL_HOST" install_ssh "rm -rf ~/sts-${OCP_VERSION}; mkdir -p ~/sts-${OCP_VERSION}"
        tar -C "$up" -czf - . | INSTALL_HOST="$TEST_INSTALL_HOST" install_ssh "tar -C ~/sts-${OCP_VERSION} -xzf -"
        ocx "oc apply -f ~/sts-${OCP_VERSION}/ | sed 's/^/    /'
             oc annotate cloudcredential.operator.openshift.io/cluster cloudcredential.openshift.io/upgradeable-to=${OCP_VERSION} --overwrite | sed 's/^/    /'"
        sleep 60
    fi
    echo "==> Upgradeable condition: $(ocx "oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type==\"Upgradeable\")].status} {.status.conditions[?(@.type==\"Upgradeable\")].message}'")"
    echo "==> oc adm upgrade --to=${OCP_VERSION}"
    ocx "oc adm upgrade --to=${OCP_VERSION}" | sed 's/^/    /'
    local t0=$SECONDS max=$(( ${UPGRADE_TIMEOUT_MIN:-180} * 60 )) st="" last=0
    while [ $((SECONDS - t0)) -lt "$max" ]; do
        st="$(ocx "oc get clusterversion version -o jsonpath='{.status.history[0].version} {.status.history[0].state} {.status.conditions[?(@.type==\"Progressing\")].message}'" 2>/dev/null || echo "api-unavailable")"
        case "$st" in "${OCP_VERSION} Completed"*) break ;; esac
        if [ $((SECONDS - last)) -ge 600 ]; then echo "    $(( (SECONDS - t0) / 60 )) min: ${st:0:200}"; last=$SECONDS; fi
        sleep 60
    done
    echo "==> After $(( (SECONDS - t0) / 60 )) min: ${st:0:200}"
    ocx 'oc get clusterversion; oc get clusterversion version -o jsonpath="{range .status.history[*]}    {.version} {.state} verified={.verified} {.completionTime}{\"\\n\"}{end}"
         oc get co --no-headers | awk "{a+=(\$3==\"True\"); d+=(\$5==\"True\")} END {print \"    operators: \"NR\", available=\"a\", degraded=\"d}"
         oc get nodes -o custom-columns=NAME:.metadata.name,OS:.status.nodeInfo.osImage,RUNTIME:.status.nodeInfo.containerRuntimeVersion --no-headers | sed "s/^/    /"
         echo "    osimagestream: $(oc get osimagestream cluster -o jsonpath="{.spec.defaultStream} (status {.status.defaultStream})" 2>/dev/null)"
         echo "    image pull failures: $(oc get pods -A --no-headers | grep -cE "ImagePull|ErrImage" || true)"'
    ai_snapshot
    case "$st" in "${OCP_VERSION} Completed"*) ;; *) echo "Error: upgrade to ${OCP_VERSION} did not complete in ${UPGRADE_TIMEOUT_MIN:-180} min." >&2; return 1 ;; esac
    ocx "oc get clusterversion version -o jsonpath='{.status.history[0].verified}'" | grep -q true \
        || { echo "Error: the ${OCP_VERSION} release was not signature-verified (history[0].verified != true)." >&2; return 1; }
    echo "    ${OCP_VERSION} release signature verified (J8)"
}

phase_audit() {
    env_load; stack_ready
    local since cutoff cutoff_note inst_ip nodes cidrs proxy_ip tmp verdict_file
    since="$(cat "${ROOT}/logs/.50-run-start" 2>/dev/null || echo 0)"
    if [ -n "${EGRESS_CVO_CUTOFF:-}" ]; then cutoff="$EGRESS_CVO_CUTOFF"; cutoff_note="EGRESS_CVO_CUTOFF"
    elif [ -s "${ROOT}/logs/.50-osus-done" ]; then cutoff="$(cat "${ROOT}/logs/.50-osus-done")"; cutoff_note="post phase (logs/.50-osus-done)"
    else cutoff=9999999999; cutoff_note="none: the CVO was not pointed at OSUS in this run"; fi
    proxy_ip="$(stack_output ProxyPrivateIp)"
    inst_ip="$(INSTALL_HOST="$TEST_INSTALL_HOST" install_host_ip 2>/dev/null || true)"
    nodes="$(INSTALL_HOST="$TEST_INSTALL_HOST" install_ssh "KUBECONFIG=~/ocp-install/${CLUSTER_NAME}/auth/kubeconfig oc get nodes \
              -o jsonpath='{range .items[*]}{.status.addresses[?(@.type==\"InternalIP\")].address}{\" \"}{end}'" 2>/dev/null || true)"
    # Private subnets: sources there that are not a known host are cluster machines
    # that are gone or not nodes (bootstrap).
    # shellcheck disable=SC2046
    cidrs="$(aws ec2 describe-subnets --subnet-ids $(stack_output PrivateSubnetIds | tr ',' ' ') \
              --query 'Subnets[].CidrBlock' --output text 2>/dev/null || true)"

    echo "==> Squid egress since $(date -u -d @"$since" +%FT%TZ)"
    echo "    install host (${TEST_INSTALL_HOST}): ${inst_ip:-n/a}   registry: ${REGISTRY_IP}   squid: ${proxy_ip}"
    echo "    cluster nodes: ${nodes:-unknown (no kubeconfig on the install host)}   private subnets: ${cidrs:-unknown}"
    if [ "$cutoff" = 9999999999 ]; then echo "    CVO -> OSUS: ${cutoff_note}"
    else echo "    CVO -> OSUS at $(date -u -d @"$cutoff" +%FT%TZ) (${cutoff_note})"; fi

    tmp="$(mktemp)"
    # Fields of the 'egress' logformat: $1 epoch, $3 client, $4 result, $7 URL (host:port), $8 SNI.
    # Rotated logs (plain or .gz) are included; zcat -f passes plain files through.
    proxy_ssh "sudo sh -c 'zcat -f /var/log/squid/access.log* 2>/dev/null' | awk -v s=$since '\$1>s && \$4 ~ /NONE_NONE|DENIED/ {print \$1, \$3, \$7, \$8}'" | sort -n > "$tmp"

    verdict_file="${ROOT}/logs/50-egress-verdict-$(date -u +%Y%m%dT%H%M%SZ).txt"
    awk -v nodes="$nodes" -v cidrs="$cidrs" -v inst="$inst_ip" -v insthost="$TEST_INSTALL_HOST" \
        -v reg="$REGISTRY_IP" -v proxy="$proxy_ip" -v cutoff="$cutoff" '
        function ip2n(ip,  a) { split(ip, a, "."); return ((a[1]*256 + a[2])*256 + a[3])*256 + a[4] }
        function incidr(ip, c,  p, m) { if (ip !~ /^[0-9.]+$/) return 0; split(c, p, "/"); m = 2^(32 - p[2]); return int(ip2n(ip)/m) == int(ip2n(p[1])/m) }
        function hms(t) { return strftime("%m-%dT%H:%M:%S", t, 1) }
        BEGIN { n = split(nodes, na, " "); for (i = 1; i <= n; i++) isnode[na[i]] = 1; nc = split(cidrs, ca, /[ \t]+/) }
        {
            ts = $1; src = $2; url = $3; sni = $4
            dst = (sni != "-" && sni != "") ? sni : url; sub(/:[0-9]+$/, "", dst)
            if (src in isnode)                         cls = "cluster-node"
            else if (inst != "" && src == inst)        cls = "install-host(" insthost ")"
            else if (src == reg)                       cls = "registry-node"
            else if (src == "127.0.0.1" || src == proxy) cls = "squid-self"
            else { cls = "other"; for (i = 1; i <= nc; i++) if (incidr(src, ca[i])) { cls = "cluster-other"; break } }
            cluster = (cls == "cluster-node" || cls == "cluster-other")
            if (dst == "172.30.0.1")                                   v = "known: kubernetes service VIP (joining workers)"
            else if (cluster && dst ~ /(^|\.)quay\.io$/)                v = "known: image-signature-import (OCPBUGS-77404)"
            else if (cluster && dst == "api.openshift.com" && ts < cutoff) v = "known: install-time CVO (before OSUS)"
            else if (cluster && dst == "data.iana.org")               v = "known (temporary, unattributed): daily 00:00 UTC, probably unbound-anchor (N-12)"
            else if (cluster)                                           v = "UNEXPECTED"
            else                                                        v = "info: host tooling/tests (not in verdict)"
            k = cls SUBSEP dst SUBSEP v
            cnt[k]++; if (!(k in first)) first[k] = ts; last[k] = ts
            if (cluster && dst ~ /(^|\.)quay\.io$/) burst[strftime("%m-%dT%H:%M", ts, 1)]++
            if (v == "UNEXPECTED") { unexp[dst " from " cls]++; nunexp++ }
            total++
        }
        END {
            printf "    %-22s %-34s %6s  %-14s %-14s %s\n", "SOURCE", "DESTINATION", "COUNT", "FIRST (UTC)", "LAST (UTC)", "CLASS"
            PROCINFO["sorted_in"] = "@ind_str_asc"
            for (k in cnt) { split(k, f, SUBSEP)
                printf "    %-22s %-34s %6d  %-14s %-14s %s\n", f[1], f[2], cnt[k], hms(first[k]), hms(last[k]), f[3] }
            if (length(burst)) {
                printf "    quay.io from the cluster by minute (expected: hourly bursts of ~22 at hh:59-hh:00, plus leader changes):\n"
                line = ""; for (m in burst) line = line sprintf(" %s=%d", m, burst[m]); print "     " line
            }
            printf "    denied CONNECTs in the window: %d\n", total
            if (nunexp == 0) print "EGRESS VERDICT: PASS (only known exceptions)"
            else { s = ""; for (u in unexp) s = s (s == "" ? "" : ", ") u " x" unexp[u]; print "EGRESS VERDICT: FAIL (unexpected: " s ")" }
        }' "$tmp" | tee "$verdict_file"
    rm -f "$tmp"
    echo "    verdict saved: ${verdict_file#"${ROOT}"/}"

    echo "==> Allowed destinations (by domain)"
    proxy_ssh "sudo sh -c 'zcat -f /var/log/squid/access.log* 2>/dev/null' | awk -v s=$since '\$1>s && \$4 ~ /TUNNEL|HIT|MISS/ {print \$8}' | sed -E 's/^[^.]+\.//' | sort | uniq -c | sort -rn | head -15" | sed 's/^/    /'
    if [ "$STRICT_EGRESS" -eq 1 ] && grep -q '^EGRESS VERDICT: FAIL' "$verdict_file"; then
        echo "--strict-egress: unexpected egress from the cluster" >&2; return 1
    fi
    return 0
}

started=0
for p in "${PHASES[@]}"; do
    [ "$p" = "$FROM" ] && started=1
    [ "$started" -eq 1 ] || continue
    [ -n "$ONLY" ] && [ "$p" != "$ONLY" ] && continue
    log="${ROOT}/logs/50-${p}-$(date -u +%Y%m%dT%H%M%SZ).log"
    echo; echo "########## $(date -u +%H:%M:%SZ) phase ${p}  (log: ${log#"${ROOT}"/})"
    t0=$(date +%s)
    # Not in an if-condition: set -e only works inside the subshell this way.
    set +e; ( set -e; "phase_${p}" ) > >(tee "$log") 2>&1; rc=$?; set -e
    sleep 1   # let tee flush
    if [ "$rc" -eq 0 ]; then
        echo "########## phase ${p} OK in $(( $(date +%s) - t0 )) s"
    else
        echo "########## phase ${p} FAILED after $(( $(date +%s) - t0 )) s; resume with: $0 --from ${p}"
        exit 1
    fi
done
echo "########## $(date -u +%H:%M:%SZ) all phases done"
