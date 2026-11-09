#!/usr/bin/env bash
#
# 45-post-install.sh - disconnected day-2 steps after a successful install (I-11,
#                      N-4, A2). Runs oc on the install host, which holds the
#                      kubeconfig and can reach the private API.
#
# Usage: scripts/45-post-install.sh [resources|cleanup|osus|operators|status|all]
#
#   resources  copy oc-mirror's working-dir/cluster-resources from the bastion and
#              apply IDMS/ITMS, the mirrored CatalogSource and ClusterCatalog, and
#              the release signature ConfigMaps (needed for upgrades)
#   cleanup    delete Failed pods left in the control-plane namespaces by a slow
#              bootstrap (installer-*/revision-pruner-* pods)
#   osus       install OpenShift Update Service from the mirrored catalog (OLM v0),
#              create oc-mirror's UpdateService, trust the ingress CA cluster-wide,
#              and point the CVO's upstream at the local policy engine
#   operators  install cert-manager through OLM v1 (ClusterExtension from the
#              mirrored ClusterCatalog) and lightspeed-operator through OLM v0;
#              check the console LightspeedButton stays Disabled
#   status     summary
#   all        resources, cleanup, osus, operators, status
#
# The cluster's mirror CA ConfigMap must carry the key updateservice-registry
# (generate-install-config.sh writes it with TRUST_MIRROR_FOR_IMAGESTREAMS).
# MIRROR_WORKSPACE: the bastion-mirror-to-mirror.sh workspace (default ~/oc-mirror/m2m).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-all}"
# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"
# shellcheck disable=SC1091
. "${ROOT}/secrets/aws.env"
. "${ROOT}/scripts/lib-stack.sh"
stack_ready

RDIR="ocp-install/${CLUSTER_NAME}"
MIRROR_WORKSPACE="${MIRROR_WORKSPACE:-oc-mirror/m2m}"     # relative to the bastion user's home
CR="post-install/cluster-resources"                         # relative to the install host user's home
ocx() { install_ssh "export KUBECONFIG=~/${RDIR}/auth/kubeconfig; $*"; }

# The mirrored redhat-operator-index catalog for the cluster's own version (the upgrade
# test mirrors both v4.22 and v5.0; oc-mirror names them ...-v4-22 / ...-v5-0). Falls back
# to the first redhat-operator-index object. Usage: index_name catalogsource|clustercatalog
index_name() {
    ocx "v=\$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2 | tr . -)
         all=\$(oc get $1 ${1/catalogsource/-n openshift-marketplace} -o name 2>/dev/null | sed 's|.*/||' | grep redhat-operator-index)
         echo \"\$all\" | grep -m1 -- \"-v\$v\\\$\" || echo \"\$all\" | head -1"
}

do_resources() {
    echo "==> Copying cluster-resources from the bastion (~/${MIRROR_WORKSPACE}/working-dir/cluster-resources)"
    install_ssh "rm -rf ~/${CR}; mkdir -p ~/${CR}"
    bastion_ssh "tar -C ~/${MIRROR_WORKSPACE}/working-dir/cluster-resources -czf - ." | install_ssh "tar -C ~/${CR} -xzf -"
    install_ssh "ls ~/${CR} | sed 's/^/    /'"
    echo "==> Applying IDMS/ITMS, catalogs and signature ConfigMaps (UpdateService comes later)"
    local before
    before="$(ocx "oc get mcp worker master -o jsonpath='{.items[*].spec.configuration.name}'")"
    ocx "cd ~/${CR}; for f in \$(ls | grep -vE '^updateService'); do
             case \"\$f\" in *.yaml|*.yml|*.json) oc apply -f \"\$f\" | sed 's/^/    /' ;; esac
         done"
    wait_mcp_rollout "$before"
}

# wait_mcp_rollout <pool target configs before a change>
# New IDMS/ITMS reach the nodes' registries.conf through a MachineConfig rollout
# (no reboot). Until every node has it, pulls of newly mirrored images go to the
# source registry (blocked when disconnected) and back off: on 2026-11-05 an OLM
# bundle-unpack pod pulled registry.redhat.io 1 minute after the operator IDMS was
# applied. So wait for the pools before installing anything from the mirror.
wait_mcp_rollout() {
    local before="$1" now=""
    echo "==> Waiting for the MachineConfigPools to roll out the new mirror configuration"
    for _ in $(seq 1 24); do      # up to 2 min for a new rendered config to be targeted
        now="$(ocx "oc get mcp worker master -o jsonpath='{.items[*].spec.configuration.name}'")"
        [ "$now" != "$before" ] && break
        sleep 5
    done
    if [ "$now" = "$before" ]; then
        echo "    no new rendered config (nothing to roll out)"
        return 0
    fi
    ocx "for i in \$(seq 1 90); do
             u=\$(oc get mcp worker master -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Updated\")].status}{\" \"}{end}');
             case \"\$u\" in *False*|*Unknown*|'') sleep 10 ;; *) echo '    pools updated:' \$(oc get mcp worker master --no-headers | awk '{print \$1\"=\"\$3}'); exit 0 ;; esac
         done; echo '    WARNING: MachineConfigPools still updating after 15 min'; oc get mcp"
}

do_cleanup() {
    echo "==> Deleting Failed pods in control-plane namespaces"
    ocx "for ns in \$(oc get ns -o name | sed 's|namespace/||' | grep -E '^openshift-(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)\$'); do
             oc delete pods -n \$ns --field-selector=status.phase==Failed --ignore-not-found | sed 's/^/    /'
         done"
}

wait_csv() {   # wait_csv <namespace> <name prefix>
    ocx "for i in \$(seq 1 60); do
             p=\$(oc get csv -n $1 -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{\"\\n\"}{end}' 2>/dev/null | grep '^$2' | awk '{print \$2}');
             [ \"\$p\" = Succeeded ] && { echo \"    CSV $2 Succeeded\"; exit 0; }; sleep 10; done
         echo \"    CSV $2 not Succeeded: \$p\"; oc get csv,subscription,installplan -n $1; exit 1"
}

do_osus() {
    local cs
    cs="$(index_name catalogsource)"
    [ -n "$cs" ] || { echo "Error: no mirrored redhat-operator-index CatalogSource; run '$0 resources' first." >&2; exit 1; }
    echo "==> Installing OpenShift Update Service from CatalogSource ${cs}"
    ocx "oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-update-service
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: update-service-og
  namespace: openshift-update-service
spec:
  targetNamespaces: [openshift-update-service]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cincinnati-operator
  namespace: openshift-update-service
spec:
  name: cincinnati-operator
  channel: v1
  source: ${cs}
  sourceNamespace: openshift-marketplace
EOF"
    wait_csv openshift-update-service update-service-operator
    echo "==> Creating the UpdateService from oc-mirror's updateService.yaml"
    ocx "oc apply -n openshift-update-service -f ~/${CR}/updateService.yaml | sed 's/^/    /'"
    local uri=""
    for _ in $(seq 1 60); do
        uri="$(ocx "oc get updateservice -n openshift-update-service -o jsonpath='{.items[0].status.policyEngineURI}'" 2>/dev/null || true)"
        [ -n "$uri" ] && break; sleep 10
    done
    [ -n "$uri" ] || { echo "Error: UpdateService has no policyEngineURI." >&2; ocx "oc get updateservice -n openshift-update-service -o yaml | tail -30"; exit 1; }
    echo "    policy engine: ${uri}"
    ocx "oc get pods -n openshift-update-service | sed 's/^/    /'"

    echo "==> Trusting the default ingress CA cluster-wide (the policy engine route uses it)"
    ocx "set -e; t=\$(mktemp)
         oc get cm user-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\\.crt}' > \$t 2>/dev/null || true
         ing=\$(mktemp); oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\\.crt}' > \$ing
         if grep -qF \"\$(sed -n 2p \$ing)\" \$t; then echo '    ingress CA already trusted'; else cat \$ing >> \$t; fi
         rm -f \$ing
         oc create cm user-ca-bundle -n openshift-config --from-file=ca-bundle.crt=\$t --dry-run=client -o yaml | oc apply -f - | sed 's/^/    /'
         oc patch proxy cluster --type merge -p '{\"spec\":{\"trustedCA\":{\"name\":\"user-ca-bundle\"}}}' | sed 's/^/    /'
         rm -f \$t"

    echo "==> Pointing the CVO at the local update service (channel ${OCP_CHANNEL})"
    ocx "oc patch clusterversion version --type merge -p '{\"spec\":{\"upstream\":\"${uri}/api/upgrades_info/v1/graph\",\"channel\":\"${OCP_CHANNEL}\"}}' | sed 's/^/    /'"
    ocx "for i in \$(seq 1 30); do
             s=\$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type==\"RetrievedUpdates\")].status}');
             [ \"\$s\" = True ] && break; sleep 20; done
         oc get clusterversion version -o jsonpath='{\"    RetrievedUpdates=\"}{.status.conditions[?(@.type==\"RetrievedUpdates\")].status}{\" \"}{.status.conditions[?(@.type==\"RetrievedUpdates\")].message}{\"\\n\"}'
         oc adm upgrade 2>&1 | head -15 | sed 's/^/    /'"
}

do_operators() {
    local cc cs
    cc="$(index_name clustercatalog)"
    cs="$(index_name catalogsource)"
    echo "==> cert-manager via OLM v1 (ClusterExtension from ClusterCatalog ${cc})"
    # A freshly applied ClusterCatalog takes several minutes to unpack (~10 min for the
    # filtered redhat-operator-index); a ClusterExtension created before that reports
    # "cache for catalog ... not found" and only installs on a later retry.
    ocx "for i in \$(seq 1 90); do
             s=\$(oc get clustercatalog ${cc} -o jsonpath='{.status.conditions[?(@.type==\"Serving\")].status}');
             [ \"\$s\" = True ] && { echo \"    ClusterCatalog ${cc} serving\"; break; }; sleep 10; done"
    # OLM v1 in 5.0 ignores spec.serviceAccount (deprecated), so none is created.
    ocx "oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: openshift-cert-manager-operator
spec:
  namespace: cert-manager-operator
  source:
    sourceType: Catalog
    catalog:
      packageName: openshift-cert-manager-operator
      channels: [stable-v1]
      selector:
        matchLabels:
          olm.operatorframework.io/metadata.name: ${cc}
EOF"
    ocx "for i in \$(seq 1 60); do
             s=\$(oc get clusterextension openshift-cert-manager-operator -o jsonpath='{.status.conditions[?(@.type==\"Installed\")].status}');
             [ \"\$s\" = True ] && break; sleep 10; done
         oc get clusterextension openshift-cert-manager-operator -o jsonpath='{\"    Installed=\"}{.status.conditions[?(@.type==\"Installed\")].status}{\" \"}{.status.install.bundle.name}{\" \"}{.status.conditions[?(@.type==\"Progressing\")].message}{\"\\n\"}'
         oc get pods -n cert-manager-operator 2>/dev/null | sed 's/^/    /'"

    echo "==> lightspeed-operator via OLM v0 (CatalogSource ${cs}); no OLSConfig, no LLM"
    ocx "oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-lightspeed
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-lightspeed
  namespace: openshift-lightspeed
spec:
  targetNamespaces: [openshift-lightspeed]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lightspeed-operator
  namespace: openshift-lightspeed
spec:
  name: lightspeed-operator
  channel: stable
  source: ${cs}
  sourceNamespace: openshift-marketplace
EOF"
    wait_csv openshift-lightspeed lightspeed-operator || true
    echo "==> Console after installing lightspeed-operator (A2)"
    ocx "echo \"    capabilities: \$(oc get console.operator cluster -o jsonpath='{.spec.customization.capabilities}')\"
         echo \"    console plugins: \$(oc get console.operator cluster -o jsonpath='{.spec.plugins}')\"
         echo \"    lightspeed CRDs: \$(oc get crd -o name | grep -iE 'lightspeed|olsconfig' | tr '\\n' ' ')\"
         echo \"    OLSConfig objects: \$(oc get olsconfig -A --no-headers 2>/dev/null | wc -l)\"
         oc get pods -n openshift-lightspeed 2>/dev/null | sed 's/^/    /'"
}

do_status() {
    echo "==> Status"
    ocx "oc get clusterversion; oc get co --no-headers | awk '{a+=(\$3==\"True\"); d+=(\$5==\"True\")} END {print \"    operators: \"NR\", available=\"a\", degraded=\"d}'
         oc get clustercatalog,catalogsource -A 2>/dev/null | sed 's/^/    /'
         echo \"    image pull failures: \$(oc get pods -A --no-headers | grep -cE 'ImagePull|ErrImage' || true)\""
}

case "$ACTION" in
    resources) do_resources ;;
    cleanup)   do_cleanup ;;
    osus)      do_osus ;;
    operators) do_operators ;;
    status)    do_status ;;
    all)       do_resources; do_cleanup; do_osus; do_operators; do_status ;;
    *) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
