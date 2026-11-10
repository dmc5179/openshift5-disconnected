# OpenShift MCP server and OLS 2.0 on a disconnected 5.0.1 cluster (A4, 2026-11-10)

Cluster: 5.0.1 (upgraded from 4.22.22), disconnected, FIPS, lightspeed-operator 2.0.0 from the mirrored v4.22
catalog, LightspeedButton Disabled, AI opt-out ValidatingAdmissionPolicy installed. All [LAB] unless tagged.

## What lightspeed-operator 2.0.0 ships
CSV `relatedImages` (all mirrored by oc-mirror as related images): lightspeed-operator, lightspeed-service-api,
lightspeed-console-plugin, lightspeed-postgresql, otelcol-lightspeed, **openshift-mcp-server**, **rhokp**
(offline knowledge portal), **lightspeed-to-dataverse-exporter**, and the agentic set (agentic operator, agentic
console plugin = AI Hub, alerts adapter, sandbox).

OLSConfig CRD (`ols.openshift.io/v1alpha1`, required: `spec.llm`, `spec.ols`):
- `spec.ols.introspectionEnabled`: "Enable introspection features (e.g. built-in OpenShift MCP server). Default: true when absent. Explicit false disables introspection."
- `spec.ols.toolsApprovalConfig.approvalType`: `never | always | tool_annotations` (default `tool_annotations`).
- `spec.ols.userDataCollection.feedbackDisabled` / `transcriptsDisabled`.
- LLM provider types include `fake_provider` (used here: no model, no LLM traffic) and `rhoai_vllm` / `rhelai_vllm`.

## Test
1. Removed the AI opt-out policy (`oc delete -f policy.yaml`). **The first create right after the delete was still
   denied**: the API server's admission-policy cache takes a few seconds, so break-glass procedures should retry.
2. Created OLSConfig `cluster` with a `fake_provider` LLM and no `introspectionEnabled` (default).
3. After 5 min: `MCPServerReady=True`, `ConsolePluginReady=True`, `AgenticConsolePluginReady=True`, `ApiReady` and
   `RHOKPReady` still progressing (the RHOKP image was still pulling through the mirror after 6 min: a large image).
   Pods: lightspeed-app-server, openshift-mcp-server, lightspeed-console-plugin, lightspeed-agentic-console-plugin,
   lightspeed-postgres-server, lightspeed-otel-collector, lightspeed-rhokp (Pending/pulling). No dataverse exporter pod.
4. **Console:** the operator added `lightspeed-console-plugin` **and `lightspeed-agentic-console-plugin` (AI Hub)** to
   `consoles.operator/cluster spec.plugins` although `LightspeedButton` stayed `Disabled`. The button setting does not
   keep AI out of the console; our policy's console rules exist to block exactly this.
5. **MCP server** (`/openshift-mcp-server --config /etc/mcp-server/config.toml`, ConfigMap `openshift-mcp-server-config`):
   `read_only = false`; `toolsets = ["core", "config", "helm", "observability/metrics", "observability/traces",
   "kubevirt", "netobserv"]`; `[[denied_resources]]` entries ("This ensures secret data never reaches the LLM");
   endpoint `https://openshift-mcp-server.openshift-lightspeed.svc:8443/mcp` (service CA). **It is not read-only by default.**
6. `introspectionEnabled: false` -> the MCP server Deployment was removed within 10 s, `MCPServerReady=False Disabled`.
7. Deleting the OLSConfig removed the OLS pods and both Lightspeed console plugins from `spec.plugins`.
8. Egress during the whole test (Squid, excluding AWS APIs): **none**.
9. Policy re-applied (10 objects).

## Customer guidance
- If OLS is installed for any reason, creating an OLSConfig turns on the MCP server (read/write toolsets) and AI Hub
  regardless of the console button. To keep the MCP server off while using OLS: `spec.ols.introspectionEnabled: false`.
- To keep the agentic layer off: `AgenticOLSConfig cluster` with `spec.suspended: true` (allowed by our policy).
- To keep everything off: don't mirror lightspeed-operator, and/or use the AI opt-out policy (blocks OLSConfig,
  AgenticOLSConfig except suspended, the Lightspeed Subscription/ClusterExtension and the console plugins).
- Disconnected sizing: the RHOKP image is large; budget mirror space and pull time if OLS is mirrored.
