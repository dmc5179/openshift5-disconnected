# Keeping OpenShift Lightspeed and the AI features off: an admission policy for OpenShift 5.0

`policy.yaml` in this directory is a set of Kubernetes **ValidatingAdmissionPolicies** (VAP,
`admissionregistration.k8s.io/v1`) that stops anyone from turning on OpenShift Lightspeed or the
agentic AI features (OLSv2, AI Hub) on an OpenShift 5.0 cluster, **even when `lightspeed-operator` is
already installed**. VAP is built into the API server: there is no webhook, no extra operator and
nothing to mirror, so it works the same way on a disconnected cluster.

Use it as the enforcement layer on top of the day-0 opt-out (do not mirror `lightspeed-operator`, set the
console `LightspeedButton` capability to `Disabled`; see `../install-results/RESULTS.md`, installs 2 and 4).

Tested 2026-11-04 on OpenShift **5.0.0** (Kubernetes v1.36.5), AWS, FIPS, disconnected, with
`lightspeed-operator` **2.0.0** installed through OLM v0 in `openshift-lightspeed` and no `OLSConfig`.
Every result below is **[LAB]** unless tagged otherwise.

## What the cluster looked like before the policy [LAB]

- `lightspeed-operator.v2.0.0` CSV `Succeeded`; two controllers running (`lightspeed-operator-controller-manager`,
  `lightspeed-agentic-operator-controller-manager`).
- The operator installs **two API groups**, not just `OLSConfig`:
  - `ols.openshift.io/v1alpha1`: `OLSConfig` (cluster-scoped, must be named `cluster`). Its spec has an
    `agenticOLS` section, so OLSv2 can be switched on from the `OLSConfig` itself.
  - `agentic.openshift.io/v1alpha1`: `AgenticOLSConfig` (singleton `cluster`), **`AgenticRun`**,
    `AgenticRunApproval`, `Agent`, `LLMProvider`, `ApprovalPolicy`, `AnalysisResult`, `ExecutionResult`,
    `VerificationResult`, `EscalationResult`.
  So the `AgenticRun` CRD **does** exist once `lightspeed-operator` 2.0.0 is installed (on a cluster without
  the operator it does not; install 2).
- No objects of any of these kinds existed.
- The operator's CSV names the console plugins it would create: `lightspeed-console-plugin` and
  `lightspeed-agentic-console-plugin`. Neither existed; console `spec.plugins` was
  `networking-console-plugin, monitoring-plugin, cluster-update-console-plugin`.
- Without the policy, a server-side dry run of `OLSConfig`, `AgenticOLSConfig`, `AgenticRun`, a second
  `lightspeed-operator` Subscription, a `lightspeed-operator` ClusterExtension and the
  `lightspeed-console-plugin` ConsolePlugin were **all accepted** (so the test objects are valid and the
  denials below come from the policy, not from schema validation).

## What the policy blocks

| Policy | Blocks | Still allowed |
|---|---|---|
| `ai-opt-out-ai-resources` | CREATE of **any** `ols.openshift.io` or `agentic.openshift.io` object (OLSConfig, AgenticOLSConfig, AgenticRun, LLMProvider, Agent, ApprovalPolicy, ...); UPDATE that changes `.spec` of an existing one | metadata-only updates, updates while the object is being deleted (finalizers), status updates, DELETE |
| `ai-opt-out-olm-subscription` | CREATE of an OLM v0 `Subscription` with `spec.name: lightspeed-operator`; UPDATE that changes its spec (channel, approval, startingCSV, source) | Subscriptions for every other package; OLM reconciling (status, metadata) the existing Subscription; DELETE |
| `ai-opt-out-olm-clusterextension` | The same for OLM v1 `ClusterExtension` with `spec.source.catalog.packageName: lightspeed-operator` | Other packages |
| `ai-opt-out-console-operator` | Any **spec** change to `consoles.operator.openshift.io/cluster` that leaves `LightspeedButton` anything but `Disabled`, removes it, removes `capabilities`/`customization` entirely, or adds `lightspeed-console-plugin` / `lightspeed-agentic-console-plugin` to `spec.plugins` | Other spec changes that keep the button Disabled; all status and metadata writes by the console operator (the policy is skipped when `.spec` is unchanged) |
| `ai-opt-out-console-plugins` | CREATE / spec UPDATE of the `lightspeed-console-plugin` and `lightspeed-agentic-console-plugin` ConsolePlugins | Every other ConsolePlugin |

All bindings use `validationActions: [Deny]` and every policy uses `failurePolicy: Fail`.

**Break-glass:** members of the group `ai-opt-out-break-glass` bypass every rule (a `matchCondition` on
`request.userInfo.groups`). The group does not exist by default:

```bash
oc adm groups new ai-opt-out-break-glass alice     # grant
oc adm groups remove-users ai-opt-out-break-glass alice   # revoke
```

## Install and remove

```bash
oc apply -f policy.yaml
oc get validatingadmissionpolicies,validatingadmissionpolicybindings -l ai-opt-out.example.com/policy=true

# remove
oc delete -f policy.yaml
# or
oc delete validatingadmissionpolicybinding,validatingadmissionpolicy -l ai-opt-out.example.com/policy=true
```

After `oc apply`, all five policies reported `status.observedGeneration: 1` and empty `status.typeChecking`
(no CEL type warnings). [LAB]

## Test results [LAB]

Test manifests (in `tests/`): `OLSConfig` (provider `rhoai_vllm`), `AgenticOLSConfig`, `AgenticRun` in `default`,
`LLMProvider` (OpenAI), a second `lightspeed-operator` Subscription, a `lightspeed-operator`
ClusterExtension, the `lightspeed-console-plugin` ConsolePlugin, and allowed counterparts (an
`aws-load-balancer-operator` Subscription and ClusterExtension, an `example-console-plugin` ConsolePlugin).
All create tests used `oc apply --dry-run=server`, so nothing new was installed.

### Rule 1: AI custom resources (identity `system:admin`, group `system:masters`)

```text
$ oc apply --dry-run=server -f olsconfig.yaml
Error from server (Forbidden): error when creating "olsconfig.yaml": olsconfigs.ols.openshift.io "cluster" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-ai-resources' with binding 'ai-opt-out-ai-resources' denied request: AI features are disabled on this cluster by policy ai-opt-out-ai-resources: CREATE of OLSConfig (ols.openshift.io) is not allowed. Contact the platform team (break-glass group ai-opt-out-break-glass).

$ oc apply --dry-run=server -f agenticolsconfig.yaml
Error from server (Forbidden): ... agenticolsconfigs.agentic.openshift.io "cluster" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-ai-resources' ... denied request: ... CREATE of AgenticOLSConfig (agentic.openshift.io) is not allowed. ...

$ oc apply --dry-run=server -f agenticrun.yaml
Error from server (Forbidden): ... agenticruns.agentic.openshift.io "test-run" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-ai-resources' ... CREATE of AgenticRun (agentic.openshift.io) is not allowed. ...

$ oc apply --dry-run=server -f llmprovider.yaml
Error from server (Forbidden): ... llmproviders.agentic.openshift.io "test-llm" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-ai-resources' ... CREATE of LLMProvider (agentic.openshift.io) is not allowed. ...
```

`system:masters` bypasses RBAC but **not** admission: the policy applies to the most privileged identity.

### Rule 2: operator Subscriptions and ClusterExtensions

```text
$ oc apply --dry-run=server -f sub-lightspeed.yaml          # new Subscription, spec.name lightspeed-operator
Error from server (Forbidden): ... subscriptions.operators.coreos.com "lightspeed-operator-2" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-olm-subscription' with binding 'ai-opt-out-olm-subscription' denied request: AI features are disabled on this cluster by policy ai-opt-out-olm-subscription: creating or changing a Subscription for lightspeed-operator is not allowed.

$ oc apply --dry-run=server -f sub-other.yaml               # aws-load-balancer-operator
subscription.operators.coreos.com/aws-load-balancer-operator created (server dry run)

$ oc -n openshift-lightspeed patch subscription lightspeed-operator --dry-run=server --type merge -p '{"spec":{"channel":"candidate"}}'
Error from server (Forbidden): subscriptions.operators.coreos.com "lightspeed-operator" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-olm-subscription' ... denied request: ...

$ oc -n openshift-lightspeed label subscription lightspeed-operator --dry-run=server example.com/test=1
subscription.operators.coreos.com/lightspeed-operator labeled (server dry run)

$ oc apply --dry-run=server -f ce-lightspeed.yaml           # ClusterExtension, packageName lightspeed-operator
Error from server (Forbidden): ... clusterextensions.olm.operatorframework.io "lightspeed-operator" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-olm-clusterextension' with binding 'ai-opt-out-olm-clusterextension' denied request: AI features are disabled on this cluster by policy ai-opt-out-olm-clusterextension: creating or changing a ClusterExtension for lightspeed-operator is not allowed.

$ oc apply --dry-run=server -f ce-other.yaml                # aws-load-balancer-operator
clusterextension.olm.operatorframework.io/aws-load-balancer-operator created (server dry run)
```

### Rule 3: console operator configuration

As **`kube:admin`** (the kubeadmin user, logged in with `oc login -u kubeadmin`), real requests, no dry run:

```text
$ oc patch console.operator.openshift.io cluster --type merge -p '{"spec":{"customization":{"capabilities":[{"name":"LightspeedButton","visibility":{"state":"Enabled"}}]}}}'
Error from server (Forbidden): consoles.operator.openshift.io "cluster" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-console-operator' with binding 'ai-opt-out-console-operator' denied request: AI features are disabled on this cluster by policy ai-opt-out-console-operator: spec.customization.capabilities must keep LightspeedButton with visibility.state Disabled.

$ oc patch console.operator.openshift.io cluster --type json -p '[{"op":"remove","path":"/spec/customization/capabilities"}]'
Error from server (Forbidden): ... spec.customization.capabilities must keep LightspeedButton with visibility.state Disabled.

$ oc apply -f olsconfig.yaml
Error from server (Forbidden): ... CREATE of OLSConfig (ols.openshift.io) is not allowed. ...
$ oc apply -f agenticolsconfig.yaml
Error from server (Forbidden): ... CREATE of AgenticOLSConfig (agentic.openshift.io) is not allowed. ...
```

As `system:admin`, server dry runs:

| Change | Result |
|---|---|
| Replace `capabilities` with only `GettingStartedBanner: Disabled` (drops LightspeedButton) | Denied (LightspeedButton message) |
| Add `lightspeed-console-plugin` to `spec.plugins` (`json` patch `add /spec/plugins/-`) | Denied: `the Lightspeed console plugins may not be enabled in spec.plugins.` |
| Set `spec.customization.customProductName` | Allowed |
| `capabilities` = LightspeedButton Disabled + GettingStartedBanner Disabled | Allowed |

### Rule 4: ConsolePlugins

```text
$ oc apply --dry-run=server -f plugin.yaml                  # lightspeed-console-plugin
Error from server (Forbidden): ... consoleplugins.console.openshift.io "lightspeed-console-plugin" is forbidden: ValidatingAdmissionPolicy 'ai-opt-out-console-plugins' ... denied request: AI features are disabled on this cluster by policy ai-opt-out-console-plugins: the Lightspeed ConsolePlugins may not be created or changed.

$ oc apply --dry-run=server -f plugin-other.yaml            # example-console-plugin
consoleplugin.console.openshift.io/example-console-plugin created (server dry run)
```

### Break-glass

```text
$ oc apply --dry-run=server -f olsconfig.yaml --as=system:admin --as-group=system:masters --as-group=ai-opt-out-break-glass
olsconfig.ols.openshift.io/cluster created (server dry run)
$ oc apply --dry-run=server -f sub-lightspeed.yaml --as=system:admin --as-group=system:masters --as-group=ai-opt-out-break-glass
subscription.operators.coreos.com/lightspeed-operator-2 created (server dry run)
```

### Cluster health with the policy installed

The policy was applied at 11:00:23Z. To force the console operator through a full reconcile, its pod was
deleted at 11:01:29Z (`oc -n openshift-console-operator delete pod -l name=console-operator`).

| Check (11:03:31Z) | Result |
|---|---|
| `oc get co` | 32/32 Available, not Progressing, not Degraded |
| `console` cluster operator | Available True, Progressing False, Degraded False |
| `consoles.operator.openshift.io/cluster` | `generation 5`, `observedGeneration 5`, LightspeedButton still Disabled; the new console-operator pod is Running with 0 restarts and logs no `forbidden`/`denied` lines; console deployment 2/2 |
| OLM | `olm` and `operator-lifecycle-manager` operators healthy; `lightspeed-operator.v2.0.0` CSV still `Succeeded`, its Subscription `AtLatestKnown` |
| API server audit log (all 3 control-plane nodes), HTTP 403 responses mentioning `ai-opt-out` | 12 from `system:admin` and 4 from `kube:admin` (exactly the test requests), **none from any service account or controller** |

The policy was **left installed** on the lab cluster.

## Caveats

- **A cluster-admin can delete the policy.** VAP stops accidental or casual enablement and leaves a clear
  error message, but anyone who can delete `validatingadmissionpolicies` can remove it. Pair it with:
  - RBAC: keep `validatingadmissionpolicies` and `validatingadmissionpolicybindings` (and `system:masters`
    certificates) out of day-to-day admin roles; use a narrower admin role instead of `cluster-admin`.
  - GitOps (Argo CD with self-heal) or an **ACM `Policy`/`ConfigurationPolicy`** (`musthave`, `enforce`) that
    re-creates the policy objects, and alerts when they change.
  - Audit: denied requests and break-glass use appear in the API server audit log.
- **It does not remove what is already there.** Existing `lightspeed-operator` installs keep running (the
  policy blocks new configuration, not the operator). To be fully opted out, uninstall the operator
  (delete the Subscription and CSV) and do not mirror it. Existing `OLSConfig`/`AgenticOLSConfig` objects
  can be deleted at any time; the policy allows DELETE and finalizer removal.
- **Upgrade from 4.x:** OLS AI Hub appears automatically on a 4.x -> 5.0 upgrade when OLS is already
  installed [JIRA, OCPSTRAT-3665]. Apply this policy **before** the upgrade, and remove the operator or its
  `OLSConfig` first if AI must be off.
- **Package and plugin names are hard-coded** from `lightspeed-operator` 2.0.0 (`lightspeed-operator`,
  `lightspeed-console-plugin`, `lightspeed-agentic-console-plugin`). Re-check them on every new operator
  version. Rule 1 matches the whole `ols.openshift.io` and `agentic.openshift.io` groups, so new kinds in
  those groups are covered automatically.
- **Not covered by this policy:**
  - Installing the operator by other routes: a hand-made `ClusterServiceVersion`, a Helm chart, or plain
    manifests (OLM v0 InstallPlans for the *existing* Subscription are also not matched). Not mirroring
    `lightspeed-operator` is still the primary control in a disconnected cluster.
  - The OpenShift MCP server (Helm chart from charts.openshift.io) and any third-party AI assistant or
    model-serving stack (OpenShift AI, vLLM). Block these with their own rules or by not mirroring them.
  - The **CVO `agenticrun-lifecycle-controller`** in the payload: it is inactive until the `AgenticRun`
    CRD exists. With `lightspeed-operator` 2.0.0 installed the CRD does exist; Rule 1 blocks creating
    `AgenticRun` objects, so the controller has nothing to act on, but the controller itself is part of the
    release payload and cannot be removed.
  - The payload `cluster-update-console-plugin` ("Cluster Updates", enabled by default) is left alone. The
    AI upgrade advisor is Technology Preview and connected-only in 5.0 [JIRA]; in this disconnected lab no AI
    content was observed in it, but that was not tested.
  - Egress to an LLM: use network policy / egress firewall as a second layer.

## Files

- `policy.yaml`: the five `ValidatingAdmissionPolicy` + `ValidatingAdmissionPolicyBinding` pairs, commented.
- `tests/`: the manifests used above. Use them only with `--dry-run=server`; the "other" ones are the
  allowed controls.

## Change 2026-11-08: allow the AgenticOLSConfig kill switch (not yet lab-tested)
Research (notes/research-jira-iso-followups.md, J5) found that `AgenticOLSConfig` (singleton `cluster`) is the
**kill switch** for the agentic system: `spec.suspended: true` stops it, and a missing object counts as
`suspended: false` (OLS-3161, OLS-3162, OLS-3316). Rule 1 denied every CREATE, which would also stop an admin
from turning the kill switch on. Rule 1 now allows CREATE/UPDATE of `AgenticOLSConfig` when `spec.suspended`
is `true`; everything else is unchanged. To test at the next rebuild (lightspeed-operator 2.0 installed):
create `AgenticOLSConfig cluster` with `spec.suspended: true` (expect allowed) and with `false` (expect denied),
and `oc apply --dry-run=server -f policy.yaml` for the CEL compile check. Upstream notes the semantics may
flip after OLS 2.0 ("explicit, unsuspended AgenticOLSConfig" required); recheck on newer bundles.
