#!/usr/bin/env bash
#
# 60-post-upgrade-tests.sh - manual tests to run after the 4.22 -> 5.0 upgrade
#                            (TEST_SCENARIO=upgrade). Read-mostly; each test says
#                            what it changes.
#
# Usage: scripts/60-post-upgrade-tests.sh [ai|vap|addnodes|all]
#
#   ai        J5: AI surface after the upgrade. Console plugins and ConsolePlugins (is
#             lightspeed-agentic-console-plugin / AI Hub there?), LightspeedButton,
#             lightspeed-operator CSV and channel/catalog, OLSConfig / AgenticOLSConfig
#             objects. Changes nothing.
#   vap       A5: the AI opt-out ValidatingAdmissionPolicy (examples/ai-opt-out-policy/
#             policy.yaml), including the 2026-11-08 kill-switch exception. Applies the
#             policy (left installed), then server-side dry runs only:
#               AgenticOLSConfig cluster, spec.suspended: true   -> expect ALLOWED
#               AgenticOLSConfig cluster, spec.suspended: false  -> expect DENIED
#               OLSConfig cluster                                 -> expect DENIED
#             Remove the policy with: oc delete -f examples/ai-opt-out-policy/policy.yaml
#   addnodes  I4: which RHCOS stream does `oc adm node-image create` build on an upgraded
#             cluster that still runs rhel-9? Builds an add-nodes ISO for a dummy host
#             (nothing joins) and reads the ISO volume ID (rhcos-9.x vs rhcos-10.x).
#             Writes ~/addnodes-test/ on the install host; the node-joiner runs as a pod
#             in the cluster (image from the mirrored payload).
#   all       ai, vap, addnodes
#
# Runs oc on the install host (INSTALL_HOST, default registry), like 45-post-install.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-all}"
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"
stack_ready
export INSTALL_HOST="${INSTALL_HOST:-registry}"

RDIR="ocp-install/${CLUSTER_NAME}"
ocx() { install_ssh "export KUBECONFIG=~/${RDIR}/auth/kubeconfig; $*"; }

do_ai() {
    echo "==> J5: AI surface after the upgrade"
    ocx 'echo "    cluster version: $(oc get clusterversion version -o jsonpath="{.status.desired.version}")"
         echo "    console capabilities: $(oc get console.operator cluster -o jsonpath="{.spec.customization.capabilities}")"
         echo "    console spec.plugins: $(oc get console.operator cluster -o jsonpath="{.spec.plugins}")"
         echo "    ConsolePlugins: $(oc get consoleplugins -o name | sed "s|.*/||" | tr "\n" " ")"
         oc get consoleplugins -o name | grep -qi lightspeed && echo "    -> a Lightspeed ConsolePlugin EXISTS (AI Hub / chat)" || echo "    -> no Lightspeed ConsolePlugin"
         echo "    lightspeed CSV: $(oc get csv -n openshift-lightspeed --no-headers 2>/dev/null | awk "{print \$1, \$NF}" | tr "\n" " ")"
         echo "    lightspeed Subscription: $(oc get subscription -n openshift-lightspeed -o jsonpath="{range .items[*]}{.spec.channel} from {.spec.source} installed={.status.installedCSV}{end}" 2>/dev/null)"
         echo "    OLSConfig / AgenticOLSConfig: $(oc get olsconfig -A --no-headers 2>/dev/null | wc -l) / $(oc get agenticolsconfig --no-headers 2>/dev/null | wc -l)"
         echo "    agentic pods: $(oc get pods -n openshift-lightspeed --no-headers 2>/dev/null | awk "{print \$1\"=\"\$3}" | tr "\n" " ")"'
}

do_vap() {
    echo "==> A5: apply the AI opt-out policy (left installed)"
    install_ssh "mkdir -p ~/ai-opt-out"
    install_scp "${ROOT}/examples/ai-opt-out-policy/policy.yaml" "ai-opt-out/policy.yaml"
    ocx 'oc apply -f ~/ai-opt-out/policy.yaml | sed "s/^/    /"; sleep 10'
    echo "==> Kill-switch exception (server-side dry runs, nothing is created)"
    ocx 'v=$(oc get crd agenticolsconfigs.agentic.openshift.io -o jsonpath="{.spec.versions[?(@.storage==true)].name}");
         for s in true false; do
             r=$(printf "apiVersion: agentic.openshift.io/%s\nkind: AgenticOLSConfig\nmetadata:\n  name: cluster\nspec:\n  suspended: %s\n" "$v" "$s" | oc apply --dry-run=server -f - 2>&1 | tail -1)
             case "$s:$r" in
                 true:*created*|true:*configured*) echo "    suspended=true : ALLOWED (expected)";;
                 false:*denied*|false:*Forbidden*|false:*ai-opt-out*) echo "    suspended=false: DENIED (expected)";;
                 *) echo "    suspended=$s : UNEXPECTED -> $r";;
             esac
         done
         r=$(oc get crd olsconfigs.ols.openshift.io -o jsonpath="{.spec.versions[?(@.storage==true)].name}" 2>/dev/null)
         if [ -n "$r" ]; then
             o=$(printf "apiVersion: ols.openshift.io/%s\nkind: OLSConfig\nmetadata:\n  name: cluster\nspec: {}\n" "$r" | oc apply --dry-run=server -f - 2>&1 | tail -1)
             case "$o" in *ai-opt-out*|*denied*|*Forbidden*) echo "    OLSConfig      : DENIED (expected)";; *) echo "    OLSConfig      : UNEXPECTED -> $o";; esac
         fi'
}

do_addnodes() {
    echo "==> I4: oc adm node-image create on this cluster"
    ocx 'echo "    osimagestream: $(oc get osimagestream cluster -o jsonpath="{.spec.defaultStream} (status {.status.defaultStream})" 2>/dev/null || echo n/a)"
         echo "    worker node OS: $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath="{.items[0].status.nodeInfo.osImage}")"
         rm -rf ~/addnodes-test; mkdir -p ~/addnodes-test; cd ~/addnodes-test
         cat > nodes-config.yaml <<EOF
hosts:
- hostname: extra-worker-test
  interfaces:
  - name: eth0
    macAddress: 00:ef:44:21:e6:a5
EOF
         timeout 1500 oc adm node-image create --dir . 2>&1 | tail -5 | sed "s/^/    /"
         iso=$(ls *.iso 2>/dev/null | head -1)
         if [ -n "$iso" ]; then
             vol=$(dd if="$iso" bs=1 skip=32808 count=32 2>/dev/null | tr -d " ")
             echo "    ISO: $iso ($(du -h "$iso" | cut -f1)), volume ID: $vol"
             case "$vol" in rhcos-10*) echo "    -> RHCOS 10 ISO";; rhcos-9*) echo "    -> RHCOS 9 ISO";; *) echo "    -> stream unknown";; esac
         else echo "    no ISO produced"; fi'
}

case "$ACTION" in
    ai) do_ai ;;
    vap) do_vap ;;
    addnodes) do_addnodes ;;
    all) do_ai; do_vap; do_addnodes ;;
    *) sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
