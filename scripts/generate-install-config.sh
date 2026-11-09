#!/usr/bin/env bash
#
# generate-install-config.sh - render install-config.yaml for a private,
#                              disconnected OpenShift 5 cluster in the VPC
#                              stack built by 10-deploy-vpc.sh.
#
# Usage: scripts/generate-install-config.sh [-o <output file>]
#            [--publish internal|external] [--fips on|off] [--os-image-stream rhel-9|rhel-10|none]
#
# The flags override PUBLISH, FIPS and OS_IMAGE_STREAM from cluster.env.
#   --publish internal  (default) private cluster: internal load balancers, private
#                       hosted zone, private subnets only. The disconnected default.
#   --publish external  public API and ingress load balancers on the public subnets.
#   --fips on|off       fips: true needs openshift-install-fips run on a RHEL host
#                       booted in FIPS mode, and fixes the choice for the life of
#                       the cluster.
#
# Reads cluster.env, secrets/aws.env, the VPC stack outputs, the pull secret and
# the mirror registry CA (MIRROR_CA_FILE). Starts from
# templates/install-config.yaml.aws-disconnected and patches:
#   region, subnets (InstallConfigSubnets output), zones, machineNetwork,
#   sizing, credentialsMode, fips, osImageStream, capabilities (Insights off),
#   imageDigestSources (mirror registry), additionalTrustBundle, baseDomain,
#   cluster name, pullSecret, sshKey.
#
# The installer must run from a host that can reach the mirror registry and the
# AWS APIs: inside the VPC (the registry node, or a host in the private subnet).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${ROOT}/install-config.yaml"

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)       OUTPUT_FILE="$2"; shift 2 ;;
        --publish)         OPT_PUBLISH="$2"; shift 2 ;;
        --fips)            OPT_FIPS="$2"; shift 2 ;;
        --os-image-stream) OPT_STREAM="$2"; shift 2 ;;
        -h|--help)         sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "generate-install-config.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"

# Command-line flags win over cluster.env. Accept any case and on/off/true/false.
PUBLISH="${OPT_PUBLISH:-${PUBLISH:-Internal}}"
case "${PUBLISH,,}" in
    internal) PUBLISH="Internal" ;;
    external) PUBLISH="External" ;;
    *) echo "Error: publish must be internal or external (got '${PUBLISH}')." >&2; exit 2 ;;
esac
FIPS="${OPT_FIPS:-${FIPS:-false}}"
case "${FIPS,,}" in
    on|true|yes|1)   FIPS="true" ;;
    off|false|no|0)  FIPS="false" ;;
    *) echo "Error: fips must be on or off (got '${FIPS}')." >&2; exit 2 ;;
esac
OS_IMAGE_STREAM="${OPT_STREAM:-${OS_IMAGE_STREAM:-rhel-10}}"
case "${CREDENTIALS_MODE:-Manual}" in
    Manual|Mint|Passthrough) ;;
    *) echo "Error: CREDENTIALS_MODE must be Manual, Mint or Passthrough (got '${CREDENTIALS_MODE}')." >&2; exit 2 ;;
esac

CREDS="${ROOT}/secrets/aws.env"
[ -f "$CREDS" ] || { echo "Error: credentials not found: ${CREDS}" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CREDS"
REGION="${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION must be set in secrets/aws.env}"
. "${ROOT}/scripts/lib-aws-target.sh"
resolve_aws_target

TEMPLATE="${ROOT}/templates/install-config.yaml.aws-disconnected"
[ -f "$TEMPLATE" ] || { echo "Error: missing ${TEMPLATE}" >&2; exit 1; }

for cmd in aws yq jq; do
    command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is not installed." >&2; exit 1; }
done
# Go yq v4 (mikefarah) - Fedora's yq. The Python yq takes jq syntax and fails here.
yq --version 2>&1 | grep -q 'mikefarah/yq.* v4\.' \
    || { echo "Error: needs Go yq v4 (dnf install yq). Found: $(yq --version 2>&1 | head -1)" >&2; exit 1; }

# The cluster needs the mirror registry's credentials in its pull secret.
PS_FILE="${INSTALL_PULL_SECRET_FILE:-}"
if [ ! -s "$PS_FILE" ]; then
    echo "Error: ${PS_FILE:-INSTALL_PULL_SECRET_FILE} not found. It is the Red Hat pull secret plus the mirror" >&2
    echo "       registry's credentials; create it (and the CA) with scripts/30-fetch-mirror-credentials.sh." >&2
    exit 1
fi
[ -f "$SSH_KEY_FILE" ]     || { echo "Error: ssh public key not found: ${SSH_KEY_FILE}" >&2; exit 1; }
jq -e . "$PS_FILE" >/dev/null || { echo "Error: ${PS_FILE} is not valid JSON." >&2; exit 1; }

if [ ! -s "$MIRROR_CA_FILE" ]; then
    cat >&2 <<EOF
Error: mirror registry CA not found: ${MIRROR_CA_FILE}
       A disconnected install must trust the mirror registry. Copy mirror-registry's
       root CA from the registry node (reachable only through the bastion):

         scp -o ProxyJump=ec2-user@<BastionPublicIp> \\
             ec2-user@<RegistryPrivateIp>:/opt/quay-root/quay-rootCA/rootCA.pem ${MIRROR_CA_FILE}

       The IPs are in the outputs of: scripts/10-deploy-vpc.sh
EOF
    exit 1
fi
grep -q 'BEGIN CERTIFICATE' "$MIRROR_CA_FILE" || { echo "Error: ${MIRROR_CA_FILE} is not a PEM certificate." >&2; exit 1; }

# none: leave osImageStream out (4.22 installs: the field is behind the OSStreams feature gate there).
case "$OS_IMAGE_STREAM" in rhel-9|rhel-10|none) ;; *) echo "Error: OS_IMAGE_STREAM must be rhel-9, rhel-10 or none." >&2; exit 1 ;; esac
# --- ISO / ISO-B constraints ----------------------------------------------------
if [ "$TARGET_IS_ISO" -eq 1 ]; then
    if [ "$PUBLISH" != "Internal" ]; then
        echo "Error: ${TARGET_ENV} supports private clusters only; drop --publish external." >&2; exit 1
    fi
    if [ "$TARGET_SIMULATED" -eq 0 ]; then
        [ -s "$AWS_CA_BUNDLE_FILE" ] || { echo "Error: ${TARGET_ENV} needs the AWS API CA bundle in ${AWS_CA_BUNDLE_FILE}." >&2; exit 1; }
        [ -n "$RHCOS_AMI_ID" ] || { echo "Error: ${TARGET_ENV} has no published RHCOS AMI; set RHCOS_AMI_ID in cluster.env." >&2; exit 1; }
    fi
    echo "    ${TARGET_ENV}: network load balancers have no security groups. The 5.0 installer's API NLB"
    echo "    uses one (apiserver-lb role); no IPI workaround - parked as TODO (AGENTS.md ISO-2)."
fi

if [ "$FIPS" = "true" ]; then
    echo "    FIPS is ON:"
    echo "      - run openshift-install-fips on a RHEL host booted in FIPS mode (it checks"
    echo "        /proc/sys/crypto/fips_enabled; RHEL 10 can only enable FIPS at install time)"
    echo "      - fips cannot be changed after install"
    if [ "$OS_IMAGE_STREAM" = "rhel-10" ]; then
        echo "      - rhel-10: no FIPS 140-3 certificate for RHEL 10 modules found yet; use"
        echo "        --os-image-stream rhel-9 if validated modules are required (AGENTS.md F3)"
    fi
fi
for v in "$AWS_CONTROL_PLANE_REPLICAS" "$AWS_WORKER_REPLICAS"; do
    case "$v" in ''|*[!0-9]*) echo "Error: replica counts must be integers (got '${v}')." >&2; exit 1 ;; esac
done

# --- stack outputs ------------------------------------------------------------
if ! aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" >/dev/null 2>&1; then
    echo "Error: stack '${VPC_STACK_NAME}' does not exist in ${REGION}. Run scripts/10-deploy-vpc.sh first." >&2
    exit 1
fi
stack_output() {
    aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
echo "==> Reading outputs from stack ${VPC_STACK_NAME}"
SUBNETS_YAML="$(stack_output InstallConfigSubnets)"   # private-cluster layout
PUBLIC_IDS="$(stack_output PublicSubnetIds)"
PRIVATE_IDS="$(stack_output PrivateSubnetIds)"
AZS="$(stack_output AvailabilityZones)"
REGISTRY_HOST="$(stack_output RegistryPrivateDnsName)"
STACK_CIDR="$(stack_output VpcCidr)"
for v in SUBNETS_YAML AZS REGISTRY_HOST STACK_CIDR; do
    [ -n "${!v}" ] && [ "${!v}" != "None" ] || { echo "Error: stack output for ${v} is empty." >&2; exit 1; }
done
[ "$STACK_CIDR" = "$VPC_CIDR" ] || echo "    Warning: VPC_CIDR=${VPC_CIDR} but the stack's VPC is ${STACK_CIDR}; using the stack's."
MIRROR="${REGISTRY_HOST}:${MIRROR_REGISTRY_PORT}/${MIRROR_NAMESPACE}"
echo "    region=${REGION} zones=${AZS} mirror=${MIRROR}"

# --- base domain ----------------------------------------------------------------
if [ -z "${BASE_DOMAIN}" ]; then
    echo "==> Detecting public Route 53 hosted zone"
    mapfile -t zones < <(aws route53 list-hosted-zones \
        --query 'HostedZones[?Config.PrivateZone==`false`].Name' --output text | tr '\t' '\n' | sed '/^$/d')
    case "${#zones[@]}" in
        1) BASE_DOMAIN="${zones[0]%.}" ;;
        0) echo "Error: no public hosted zone; set BASE_DOMAIN in cluster.env." >&2; exit 1 ;;
        *) echo "Error: ${#zones[@]} public zones (${zones[*]}); set BASE_DOMAIN in cluster.env." >&2; exit 1 ;;
    esac
fi

# --- render ---------------------------------------------------------------------
umask 077
cp "$TEMPLATE" "$OUTPUT_FILE"
cleanup_partial() { local rc=$?; [ "$rc" -ne 0 ] && rm -f "$OUTPUT_FILE"; return $rc; }
trap cleanup_partial EXIT

if [ "$PUBLISH" = "Internal" ]; then
    # From the template: private subnets only, each with all four roles a private
    # cluster needs. ControlPlaneExternalLB is forbidden when publish is Internal.
    SUBNETS_JSON="$(printf '%s\n' "$SUBNETS_YAML" | yq -o=json -I=0 '.platform.aws.vpc.subnets')"
else
    # External: public subnets carry the internet-facing load balancers and the
    # bootstrap node, private subnets carry the nodes and the internal API LB.
    SUBNETS_JSON="$(jq -n -c --arg pub "$PUBLIC_IDS" --arg priv "$PRIVATE_IDS" '
        ($pub  | split(",") | map({id: ., roles: [{type: "IngressControllerLB"}, {type: "ControlPlaneExternalLB"}, {type: "BootstrapNode"}]})) +
        ($priv | split(",") | map({id: ., roles: [{type: "ClusterNode"}, {type: "ControlPlaneInternalLB"}]}))')"
fi
ZONES_JSON="$(printf '%s\n' "$AZS" | jq -R -c 'split(",")')"

# Mirror mappings for the release payload. oc-mirror v2 pushes the release index
# to <ns>/openshift/release-images and the component images to <ns>/openshift/release.
# Observed for 5.0.0 (examples/oc-mirror-5.0-m2d/RESULTS.md): all 197 payload images
# come from ocp-v5.0-art-dev, none from ocp-v4.0-art-dev. The v4.0 entry is kept
# because the payload still references it for the KubeVirt boot images and the
# default ClusterImagePolicy, and 4.x -> 5.0 upgrades need it; it is harmless.
IDMS_JSON="$(jq -n -c --arg m "$MIRROR" '[
  {mirrors: ["\($m)/openshift/release-images"], source: "quay.io/openshift-release-dev/ocp-release"},
  {mirrors: ["\($m)/openshift/release"],        source: "quay.io/openshift-release-dev/ocp-v4.0-art-dev"},
  {mirrors: ["\($m)/openshift/release"],        source: "quay.io/openshift-release-dev/ocp-v5.0-art-dev"}]')"

V_REGION="$REGION" V_SUBNETS="$SUBNETS_JSON" V_ZONES="$ZONES_JSON" V_CIDR="$STACK_CIDR" \
V_CPTYPE="$AWS_CONTROL_PLANE_TYPE" V_CPREPS="$AWS_CONTROL_PLANE_REPLICAS" \
V_WKTYPE="$AWS_WORKER_TYPE" V_WKREPS="$AWS_WORKER_REPLICAS" \
V_CRED="$CREDENTIALS_MODE" V_FIPS="$FIPS" V_STREAM="$OS_IMAGE_STREAM" V_PUBLISH="$PUBLISH" \
V_IDMS="$IDMS_JSON" V_CA="$(cat "$MIRROR_CA_FILE")" \
V_DOMAIN="$BASE_DOMAIN" V_NAME="$CLUSTER_NAME" \
V_PS="$(jq -c . "$PS_FILE")" V_KEY="$(cat "$SSH_KEY_FILE")" \
yq -i '
      .platform.aws.region = strenv(V_REGION)
    | .platform.aws.vpc.subnets = env(V_SUBNETS)
    | .platform.aws.vpc.subnets style=""
    | .controlPlane.platform.aws.zones = env(V_ZONES)
    | .controlPlane.platform.aws.type = strenv(V_CPTYPE)
    | .controlPlane.replicas = env(V_CPREPS)
    | .compute[0].platform.aws.zones = env(V_ZONES)
    | .compute[0].platform.aws.type = strenv(V_WKTYPE)
    | .compute[0].replicas = env(V_WKREPS)
    | .networking.machineNetwork = [{"cidr": strenv(V_CIDR)}]
    | .credentialsMode = strenv(V_CRED)
    | .fips = env(V_FIPS)
    | .publish = strenv(V_PUBLISH)
    | .osImageStream = strenv(V_STREAM)
    | del(select(.osImageStream == "none") | .osImageStream)
    | .imageDigestSources = env(V_IDMS)
    | .imageDigestSources style=""
    | .additionalTrustBundle = strenv(V_CA)
    | .additionalTrustBundle style="literal"
    | .baseDomain = strenv(V_DOMAIN)
    | .metadata.name = strenv(V_NAME)
    | .pullSecret = strenv(V_PS)
    | .sshKey = strenv(V_KEY)' \
    "$OUTPUT_FILE"

# Insights ("Red Hat Lightspeed" health reporting) off: an explicit capability
# list = everything the 5.0 ClusterVersion API accepts on a Default feature set,
# minus Insights. Ingress, CloudCredential and CloudControllerManager are
# mandatory on AWS (installer pkg/types/validation/installconfig.go).
#
# NOT CompatibilityRequirements or ClusterAPI: they are in the installer's
# vendored vCurrent set and pass install-config validation, but the cluster's
# ClusterVersion CRD rejects them on a Default (non-TechPreview) cluster. The
# ClusterVersion object is then never created, the CVO waits forever, and the
# install stalls at bootstrap with NotReady masters (observed 2026-11-03).
# DISABLE_SAMPLES leaves out openshift-samples too: the samples operator is then
# never deployed. Otherwise it probes registry.redhat.io every 20 s for about
# 5 minutes on first start (disconnected detection) before setting itself
# Removed (observed 2026-11-04). The ImageStreams in the openshift namespace
# (cli, tools, must-gather, ...) come from the release payload, not from samples.
# A capability left out can be enabled later, never disabled.
if [ "$DISABLE_INSIGHTS" = "true" ] || [ "${DISABLE_SAMPLES:-false}" = "true" ]; then
    caps="baremetal Console marketplace Storage openshift-samples CSISnapshot NodeTuning MachineAPI Build DeploymentConfig ImageRegistry OperatorLifecycleManager OperatorLifecycleManagerV1 CloudCredential Ingress CloudControllerManager"
    [ "$DISABLE_INSIGHTS" = "true" ] || caps="$caps Insights"
    [ "${DISABLE_SAMPLES:-false}" = "true" ] && caps="$(echo "$caps" | tr ' ' '\n' | grep -vx openshift-samples | tr '\n' ' ')"
    V_CAPS="$(echo $caps | tr ' ' '\n' | jq -R . | jq -sc .)" \
        yq -i '.capabilities = {"baselineCapabilitySet": "None", "additionalEnabledCapabilities": env(V_CAPS)}' "$OUTPUT_FILE"
fi

# ISO: the AWS API CA goes into the trust bundle too; a custom RHCOS AMI when given.
if [ "$TARGET_IS_ISO" -eq 1 ] && [ -s "$AWS_CA_BUNDLE_FILE" ]; then
    V_ACA="$(cat "$AWS_CA_BUNDLE_FILE")" yq -i '.additionalTrustBundle = .additionalTrustBundle + "\n" + strenv(V_ACA)' "$OUTPUT_FILE"
fi
if [ -n "${RHCOS_AMI_ID:-}" ]; then
    # platform.aws.amiID is deprecated (installer pkg/types/aws/platform.go); use the
    # default machine pool. It must match osImageStream: nothing checks that (AGENTS.md I5).
    V_AMI="$RHCOS_AMI_ID" yq -i '.platform.aws.defaultMachinePlatform.amiID = strenv(V_AMI)' "$OUTPUT_FILE"
fi

# Block style throughout, for readability; keep the CA as a literal block.
yq -i '... style="" | .additionalTrustBundle style="literal"' "$OUTPUT_FILE"

if grep -qE '^[^#]*CHANGEME' "$OUTPUT_FILE"; then
    echo "Error: unresolved CHANGEME placeholders in ${OUTPUT_FILE}:" >&2
    grep -nE '^[^#]*CHANGEME' "$OUTPUT_FILE" >&2
    exit 1
fi

# --- day-0 manifests --------------------------------------------------------------
D0="${CLUSTER_DIR}/day0-manifests"
rm -rf "$D0"; mkdir -p "$D0"
# Console operator config (one Console object for both settings):
#   DISABLE_LIGHTSPEED: hide the OpenShift Lightspeed AI entry point from first boot.
#     Capability names per openshift/api operator/v1 types_console.go (5.0):
#     LightspeedButton, GettingStartedBanner, GuidedTour.
#   SILENCE_CONSOLE_TELEMETRY: the console-operator looks up the organization at
#     api.openshift.com/api/accounts_mgmt/v1/subscriptions every 5 minutes, even with
#     no telemetry and no cloud.openshift.com token. It skips the lookup when both
#     telemetry.console.openshift.io/ORGANIZATION_ID and .../ACCOUNT_MAIL are set
#     (console-operator release-5.0 GetOrganizationMeta; only presence is checked).
#     Placeholder values reach the console front end as telemetry metadata, so do
#     not use this on a connected cluster. Verified day 2 on 5.0.0 (2026-11-04).
if [ "${DISABLE_LIGHTSPEED:-false}" = "true" ] || [ "${SILENCE_CONSOLE_TELEMETRY:-false}" = "true" ]; then
    CF="${D0}/99-console-operator-config.yaml"
    cat > "$CF" <<'EOF'
apiVersion: operator.openshift.io/v1
kind: Console
metadata:
  name: cluster
spec:
  managementState: Managed
EOF
    if [ "${DISABLE_LIGHTSPEED:-false}" = "true" ]; then
        yq -i '.spec.customization.capabilities = [{"name": "LightspeedButton", "visibility": {"state": "Disabled"}}]' "$CF"
    fi
    if [ "${SILENCE_CONSOLE_TELEMETRY:-false}" = "true" ]; then
        V_ORG="${CONSOLE_TELEMETRY_ORG_ID:-0000000}" V_MAIL="${CONSOLE_TELEMETRY_ACCOUNT_MAIL:-disconnected@example.com}" \
            yq -i '.metadata.annotations."telemetry.console.openshift.io/ORGANIZATION_ID" = strenv(V_ORG) |
                   .metadata.annotations."telemetry.console.openshift.io/ACCOUNT_MAIL" = strenv(V_MAIL)' "$CF"
    fi
fi
if [ "${DISABLE_DEFAULT_CATALOGS:-false}" = "true" ]; then
    cat > "${D0}/99-operatorhub-disable-default-sources.yaml" <<'EOF'
# Disconnected: the default catalogs point at registry.redhat.io. Use catalogs
# mirrored with oc-mirror instead (its CatalogSource / ClusterCatalog output).
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
EOF
fi
if [ "${DISABLE_DEFAULT_CATALOGS:-false}" = "true" ]; then
    # OLM v1: disableAllDefaultSources only removes the OLM v0 CatalogSources; the
    # default ClusterCatalogs stay Available and keep pulling from registry.redhat.io
    # (observed on 5.0.0). Documented switch: spec.availabilityMode: Unavailable
    # (openshift-docs olmv1-disabling-a-default-catalog). Created day 0 here; if the
    # cluster-olm-operator resets them, fall back to `oc patch` after install.
    cat_ver="$(echo "${INSTALL_VERSION:-$OCP_VERSION}" | cut -d. -f1,2)"   # the installed release's catalogs
    for c in redhat certified community; do
        cat > "${D0}/99-olmv1-clustercatalog-openshift-${c}-operators-unavailable.yaml" <<EOF
# Disconnected: keep the default OLM v1 catalog from polling registry.redhat.io.
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  name: openshift-${c}-operators
spec:
  availabilityMode: Unavailable
  source:
    type: Image
    image:
      ref: registry.redhat.io/redhat/${c}-operator-index:v${cat_ver}
EOF
    done
fi
if [ "${TRUST_MIRROR_FOR_IMAGESTREAMS:-false}" = "true" ]; then
    # additionalTrustBundle covers node pulls, not ImageStream imports: without this,
    # imports fail x509 against the mirror and fall back to quay.io (observed 5.0.0).
    # Key format for a registry with a port: <host>..<port>.
    {
        cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-registry-ca
  namespace: openshift-config
data:
  ${REGISTRY_HOST}..${MIRROR_REGISTRY_PORT}: |
EOF
        sed 's/^/    /' "$MIRROR_CA_FILE"
        # OpenShift Update Service reads the graph-data image's registry CA from this
        # same ConfigMap, under the fixed key updateservice-registry.
        echo "  updateservice-registry: |"
        sed 's/^/    /' "$MIRROR_CA_FILE"
    } > "${D0}/99-configmap-mirror-registry-ca.yaml"
    cat > "${D0}/99-image-config-additional-trusted-ca.yaml" <<'EOF'
# Trust the mirror registry for ImageStream imports and builds.
apiVersion: config.openshift.io/v1
kind: Image
metadata:
  name: cluster
spec:
  additionalTrustedCA:
    name: mirror-registry-ca
EOF
fi
if [ "${DISABLE_UNBOUND_ANCHOR:-false}" = "true" ]; then
    # N-12: mask the daily DNSSEC root trust anchor refresh (data.iana.org, blocked when
    # disconnected). Cause not yet confirmed; masking a unit that does not exist is harmless.
    for role in master worker; do
        cat > "${D0}/99-${role}-mask-unbound-anchor-timer.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-${role}-mask-unbound-anchor-timer
  labels:
    machineconfiguration.openshift.io/role: ${role}
spec:
  config:
    ignition:
      version: 3.5.0
    systemd:
      units:
      - name: unbound-anchor.timer
        mask: true
EOF
    done
fi
for f in "$D0"/*.yaml; do yq -e '.kind' "$f" >/dev/null || { echo "Error: invalid day-0 manifest ${f}" >&2; exit 1; }; done
echo "    day-0 manifests: $(ls "$D0" | tr '\n' ' ')"

echo "    baseDomain=${BASE_DOMAIN} cluster=${CLUSTER_NAME} target=${TARGET_ENV} publish=${PUBLISH} stream=${OS_IMAGE_STREAM} fips=${FIPS} insights-disabled=${DISABLE_INSIGHTS} samples-disabled=${DISABLE_SAMPLES:-false}"
echo "==> Wrote ${OUTPUT_FILE} (mode 600: contains the pull secret)"
if [ "$CREDENTIALS_MODE" = "Manual" ]; then
    echo "    credentialsMode Manual (STS): next run scripts/20-prepare-sts.sh (ccoctl), then add its"
    echo "    manifests/ and tls/ to the install directory after 'openshift-install create manifests'."
fi
