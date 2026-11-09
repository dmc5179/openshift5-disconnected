# Research: Jira follow-ups (J2, J3, J5, J6, J7, A4) and AWS ISO/GovCloud (ISO-2, ISO-4, ISO-5)

Date: 2026-11-08. Local research only (no AWS, no lab). Jira read-only. Sources: Red Hat Jira (internal, **do not
quote to customers**), openshift-docs `enterprise-5.0` @ b5698adc31 (2026-11-05), installer `origin/release-5.0`
@ 8647f26b29 / `origin/main` @ 4da4f1f39d, oc-mirror `origin/release-5.0`, `origin/main` @ bb98f7ce,
cloud-credential-operator `release-5.0` (read through `gh api`), lightspeed-operator / lightspeed-agentic-operator /
mirror-gui `main` (read through `gh api`), OKP (KB 7140712, KB 7125624, KB 7142179).

Tags: [JIRA] internal Jira, [DOC] 5.0 docs source or published docs/KB, [CODE] source at the stated ref,
[LAB] earlier lab results in this repo, [INFER] my reasoning.

## Summary

| ID | Answer (1-2 lines) | Confidence | Suggested tracker status |
|---|---|---|---|
| J2 | Only the **docs** for oc-mirror v1 were removed in 5.0; the v1 **code still ships** in the 5.0 oc-mirror (`--v1`/`--v2` mandatory since 4.21). Full v1 code removal is targeted for **5.2** (OCPSTRAT-3472). v1 automation keeps running but is undocumented and deprecated: move to `--v2`, `mirror.openshift.io/v2alpha1`, `working-dir/cluster-resources/idms-*.yaml`. | High | DONE |
| J3 | "OpenShift Mirror Console" (mirror-gui): a separate podman container that wraps oc-mirror v2, announced in the oc-mirror **2.0.0** release notes; feature OCPSTRAT-2625 is Release Pending, docs (OSDOCS-20450/22874) are still in Review for **5.0.z**. Runs locally, so ISC authoring works offline with pre-synced catalogs; mirroring still needs registry access. Upstream catalog sync covers only OCP 4.16–4.22 (no 5.0) on `main`. | Medium-high | DONE (re-check docs at 5.0.z) |
| J5 | AI Hub (agentic console plugin) appears when **all** of these are true: OLS v2 bundle installed (from the **v5.0** catalog), an `OLSConfig` exists, and ClusterVersion reports a **completed** 5.x update. In disconnected clusters nothing changes until the customer mirrors `lightspeed-operator` from the v5.0 index. LightspeedButton=Disabled does **not** hide AI Hub. Our VAP blocks it, but it also blocks the **AgenticOLSConfig kill switch** (`spec.suspended: true`). | Medium (behaviour from Jira + upstream specs, not lab-tested) | IN PROGRESS (fix VAP, lab-test upgrade) |
| J6 | Gemma 4 31B on RHOAI/vLLM is the only local model in the disconnected CI (OLS-4226/OLS-3472 closed); OCPMCP-469 (MCP-server local-model validation) is still **In Progress**; legal review of Gemma 4 still listed as outstanding, no resolution found. OLS docs: self-hosted providers are RHOAI (vLLM) and RHEL AI; "Red Hat does not provide support for any specific models". | Medium | IN PROGRESS (feeds A3) |
| J7 | OCPSTRAT-3755: **Backlog, no fixVersion**; spike done (2026-10-13: 21–70 % savings for CNV/ODF/OSSM/Serverless), refinement complete, not scheduled. Nothing in 5.0/5.1. | High | DONE (watch) |
| A4 | Two delivery paths in 5.0: (1) **inside OLS 2.0**: `openshift-mcp-server` image is a related image of lightspeed-operator and is deployed by default when an OLSConfig exists (`spec.ols.introspectionEnabled`, default true); (2) **standalone**: MCP Lifecycle Operator (TP, needs RHOAI 3.6 early-release) + MCP gateway (Connectivity Link) + MCP Catalog. The 4.22 Helm-chart path is gone from the 5.0 docs. | Medium-high | DONE (lab check of introspection toggle optional) |
| ISO-4 | Docs-backed requirements: custom RHCOS AMI (no AMIs for ISO), manual install-config, `additionalTrustBundle` with the AWS API CA plus CA on the install host (`AWS_CA_BUNDLE`), private cluster, VPC endpoints `*.c2s.ic.gov` / `*.sc2s.sgov.gov`. Gaps: docs import procedure has no per-stream guidance (rhel-10 = `rhcos-10.2.*-aws.x86_64.vmdk.gz`, rhel-9 = `rhcos-9.8.*`), docs still say CAPI installs in secret regions are "not tested". OCPBUGS-78093 is **POST, fix PR unmerged** (not in 5.0.0); OCPBUGS-86038 (4.22) ASSIGNED. | High | IN PROGRESS |
| ISO-5 | ccoctl 5.0 has **no ISO support**: its partition helper maps `us-iso*` to `aws`, so the public-bucket policy gets a wrong ARN; `--create-private-s3-bucket` needs CloudFront. Fix is OCPSTRAT-3586 / CCO-851 (GovCloud committed, ISO "handled but not supported"), **Backlog, target 5.1 removed**. GovCloud: the default public-S3 issuer works (OCPBUGS-13549 fixed); ISO: use Mint/Passthrough or manual long-term credentials, or hand-built STS from `--dry-run` output (unsupported). | Medium-high | IN PROGRESS |
| ISO-2 | **Correction:** the vendored CAPA in installer 5.0 drops security groups from NLBs in `us-iso-east-1`, `us-iso-west-1`, `us-isob-east-1` (since 4.18, OCPBUGS-33311). IPI API NLB should therefore work in ISO. Remaining breakage: user-provisioned DNS (OCPBUGS-78093) and regions missing from the hard-coded list (`us-isob-west-1`, RFE-10089). | High (code), untested | Reopen as "mostly resolved"; lab not possible |

---

## J2: oc-mirror v1 docs removed in 5.0

**What was removed**
- [JIRA] OSDOCS-20578 "Remove oc-mirror v1 docs and its references" (Closed, fixVersion openshift-5.0): replaced v1
  xrefs with v2 across extensions, OLM, disconnected books. OSDOCS-20743 (docs for OCPSTRAT-3473, Closed) and
  OSDOCS-21574 (release note, Closed).
- [JIRA] OCPSTRAT-3473 "[docs only] Remove oc-mirror v1 references from OpenShift documentation" (In Progress):
  "docs-only change to stop directing customers toward v1 ahead of the full v1 code removal in 5.2
  (OCPSTRAT-3472)".
- [DOC] 5.0 release notes, `modules/rn-ocp-release-notes-new-features.adoc:543`: "The Red Hat Customer Portal no
  longer includes documentation for the oc-mirror plugin v1 because the oc-mirror plugin v1 is deprecated." Also
  (L548): oc-mirror v2 docs will be delivered outside OCP GA releases in future.
- [DOC] Deprecated/removed table (`modules/rn-ocp-release-notes-deprecated-removed-tables.adoc:168`): "oc-mirror
  plugin v1 — Deprecated / Deprecated / Deprecated" for 4.21 / 4.22 / 5.0 (not "Removed").
- [DOC] Kept: `disconnected/oc_mirror_v2/oc-mirror-migration-v1-to-v2.adoc` (migration guide).

**Is v1 still shipped and usable?**
- [CODE] Yes. `cmd/oc-mirror/main.go:28-54` in `origin/release-5.0` and `origin/main`: `--v1` or `--v2` is
  mandatory; `describe` and `init` are still v1-only ("only implemented in oc-mirror v1 ... use --v1").
- [JIRA] OCPSTRAT-3472 "Remove oc-mirror v1 from OpenShift" (In Progress): timeline 4.18 deprecated, 4.20 warnings
  (OCPSTRAT-2408), 4.21 flag mandatory, **5.2 target for full removal**.
- [JIRA] A v1-only security tracker was filed against the 5.0 oc-mirror plugin (embargoed; internal only; v1
  catalog-cache rebuild path). Another reason not to keep v1 in production pipelines. Do not cite details outside
  Red Hat.
- [INFER] v1 against 5.x content is untested by us and undocumented; supportability of v1 for 5.0 mirroring is
  doubtful even though it is "Deprecated", not "Removed".

**What v1 users must change**
- `--v1` → `--v2`; ISC `apiVersion: mirror.openshift.io/v1alpha2` → `v2alpha1`; drop `storageConfig`
  (v2 uses `--workspace file://...` / `--cache-dir`), `mirror.operators[].full`, etc. (per migration guide).
- Output: `oc-mirror-workspace/results-*/imageContentSourcePolicy.yaml` + `catalogSource-*.yaml` (ICSP) →
  `working-dir/cluster-resources/idms-oc-mirror.yaml`, `itms-oc-mirror.yaml`, `cs-*.yaml`, `cc-*.yaml`
  (ClusterCatalog), signature ConfigMap, `updateService.yaml`. Apply IDMS/ITMS instead of ICSP.
- Deletion: v1 pruning via `--continue-on-error`/automatic pruning → v2 explicit `oc-mirror delete` with a
  `DeleteImageSetConfiguration` (two-phase).
- `describe` / `init` have no v2 replacement yet (still v1-only in 5.0 code).
- 5.0-specific: get oc-mirror from the async channel (J1; `oc adm release extract` no longer provides it), and use
  the image build on FIPS hosts (OCPBUGS-136646).
- [DOC] Residual v1 content still in the 5.0 docs (ticket candidate, see end): ZTP precache
  `modules/ztp-precaching-custom-disconnected.adoc:59,120` uses `mirror.openshift.io/v1alpha2`; Agent disconnected
  procedure (DOC-4, already OSDOCS-24191).

## J3: Guided ImageSetConfiguration UI

- [JIRA] OCPSTRAT-2625 "[GA] mirror-gui — Guided ImageSetConfig generation" — fixVersion openshift-5.0, status
  **Release Pending**, labels `no_core_payload`, `ocp5-committed`. Standalone containerized web app (PatternFly,
  `localhost:3000`, podman 5.0+), image on registry.redhat.io, own release cadence, bundles oc-mirror v2, supports
  OCP 4.16+. TP was OCPSTRAT-2624. Comment 2026-03-24 (PM): UI ships with oc-mirror, **not** hosted on
  console.redhat.com, "will also enable m2m scenarios, to run in enclave scenarios". Product name per CLID-738:
  "OpenShift Mirror Console".
- [JIRA] OSDOCS-20450 / OSDOCS-22874 (docs) — status **Review**, fixVersion **openshift-5.0.z**.
- [DOC] `modules/oc-mirror-v2-release-notes-2-0-0.adoc` (Issued 27 October 2026), included in
  `disconnected/oc_mirror_v2/oc-mirror-v2-release-notes.adoc`: "Image set mirroring by using the OpenShift Mirror
  Console ... build an ImageSetConfiguration ... platform channels, Operator catalogs, Helm charts, and additional
  images, and start mirror operations"; preview/save/download/load ISC, "Synchronize Operator catalog digests",
  operation history. No procedure module yet.
- [CODE] github.com/openshift/mirror-gui `main` README: runs as a podman container wrapping oc-mirror v2
  mirror-to-disk; operator catalog metadata is pre-fetched at build time (`sync-catalogs.sh`) and bundled "for
  offline browsing". `sync-catalogs.sh:21` `OCP_VERSIONS=("4.16" ... "4.22")`: **no 5.0 catalogs** upstream.
  (The registry.redhat.io build may differ; not checked.)
- Disconnected answer [INFER from JIRA/CODE]: ISC authoring works without internet if the image already carries
  the catalog metadata; "Sync Catalogs" and mirror-to-disk need registry.redhat.io; disk-to-mirror inside the
  enclave should work because it is plain oc-mirror v2. Our customers would still need FIPS validation of the image
  (requirement 9 in OCPSTRAT-2625) before using it on a FIPS host.

## J5: AI Hub after a 4.x → 5.0 upgrade with OLS installed

**What happens**
- [JIRA] OCPSTRAT-3665 (status New, no fixVersion): "AI Hub (agentic console plugin) appears after upgrade and
  operator reconcile. Release notes warn admins to review the Technology Preview designation before enabling
  users." Acceptance: "AI Hub appears automatically and is labelled TP".
- [JIRA] OLS-4010 (Closed, ols-2.0): v2 channel head has `olm.skipRange: ">=1.0.0 <2.0.0"`; **4.16–4.22
  catalogs carry only the v1 (classic) bundle, 5.x catalogs only the v2 bundle**. OLS-4012 (Closed): e2e asserts
  v1 on 4.x has no agentic CRDs/RBAC/operands, v2 on ≥5.0 has the agentic controller, CRDs, RBAC
  (`agentic-run-approver`) and operands (**agentic console plugin**, alerts adapter, handoff ConfigMap).
- [CODE] lightspeed-operator `main` `.ai/spec/what/bundle-composition.md` (updated 2026-11-03 for the coming
  unified bundle, OLS-4007): rule 8 the lightspeed-operator owns the chat and agentic console plugin operands;
  rule 10 the agentic gate is **Enabled only if the latest ClusterVersion update is Completed and the major
  version is ≥ 5**; rule 11 "An Enabled Classic-side gate permits configured operands (including the console) and
  the handoff **without checking for AgenticOLSConfig**".
- [LAB] Install 4 (A2): lightspeed-operator 2.0.0 installed **without an OLSConfig** → no Lightspeed console
  plugin enabled, LightspeedButton stayed Disabled. So operands need an OLSConfig.
- [INFER] Net behaviour for a disconnected 4.22 cluster with OLS 1.x + OLSConfig:
  1. During the cluster upgrade nothing changes; the Subscription still points at the mirrored v4.22 catalog.
  2. When the customer mirrors `redhat-operator-index:v5.0` **including lightspeed-operator** and switches the
     CatalogSource, OLM upgrades 1.x → 2.0 via skipRange (automatic approval) and, once ClusterVersion shows the
     5.0 update Completed, the operator deploys the agentic console plugin (AI Hub).
  3. If lightspeed-operator is **not** in the 5.0 ISC, OLS stays on 1.x from a stale catalog (unsupported on 5.0,
     and may also block the update if the 1.x CSV sets `olm.maxOpenShiftVersion`; not checked).

**AgenticOLSConfig is a kill switch, not an enable switch (correction to findings §3b)**
- [JIRA] OLS-3161 (Closed): `AgenticOLSConfig` singleton `cluster`, "for the agentic system kill switch",
  `spec.suspended` (default false). OLS-3162 (Closed): "NotFound treated as suspended=false". OLS-3316: status
  condition `Suspended`.
- [CODE] lightspeed-agentic-operator `main` `.ai/spec/what/system-config.md` rule 3: "When no AgenticOLSConfig CR
  exists, the system MUST behave as if spec.suspended is false"; rule 11a: while suspended, a VAP rejects
  `AgenticRun` CREATE.
- [JIRA] OLS-4007 (In Progress, future unified bundle): "agentic layer activates only when explicitly enabled via
  AgenticOLSConfig CR creation". bundle-composition.md rule 11 (main): "Agentic workflow execution requires an
  explicit, unsuspended AgenticOLSConfig". So the semantics **flip** after 2.0 (unified bundle). For OLS 2.0.x:
  absent = runs allowed; for the unified bundle: absent = runs not allowed. [INFER] Lab-check on 2.0.0.

**What a customer who wants AI off must do**
- Before the upgrade (preferred): uninstall OLS (delete `OLSConfig`, Subscription, CSV; check
  `console.operator.openshift.io spec.plugins`), and do not include `lightspeed-operator` in the 5.0 ISC.
- If OLS must stay (classic chat only): before switching to the v5.0 catalog, create
  `AgenticOLSConfig cluster` with `spec.suspended: true` once the CRD appears (it ships with the 2.0 bundle), or
  set the Subscription to Manual approval and review the 2.0 InstallPlan first. Remove the agentic plugin from
  `spec.plugins` if it was added. `spec.ols.introspectionEnabled: false` also removes the bundled MCP server (A4).
- After the upgrade: verify `oc get consoleplugins`, `oc get console.operator cluster -o
  jsonpath='{.spec.plugins}'`, `oc get agenticolsconfig cluster -o yaml`.

**Coverage of our controls**
- `LightspeedButton: Disabled` [INFER]: hides only the chat launcher; AI Hub is a separate plugin nav section
  (OLS-3649 "AI Hub section with subnav"). Does **not** cover AI Hub. KB 7139853 already warns the setting may not
  work with the operator installed.
- `examples/ai-opt-out-policy/policy.yaml` [CODE, local]: covers it in practice: Subscription / ClusterExtension
  for lightspeed-operator denied (so a 1.x → 2.0 upgrade by Subscription edit is blocked, but an **automatic
  skipRange upgrade on an existing Subscription is not a Subscription spec change** and would not be blocked
  [INFER]); ConsolePlugin `lightspeed-agentic-console-plugin` CREATE denied; console `spec.plugins` additions
  denied; AgenticRun CREATE denied.
- **Gap:** rule `ai-opt-out-ai-resources` denies CREATE of every `agentic.openshift.io` kind, including
  `AgenticOLSConfig`. That blocks the vendor kill switch. Allow CREATE/UPDATE of `AgenticOLSConfig` when
  `object.spec.suspended == true`, or pre-create it with `suspended: true` before applying the VAP.
- [INFER] When the VAP denies the operator's ConsolePlugin creation, the OLS operator will likely report reconcile
  errors / a degraded OLSConfig status. Acceptable, but document it.

## J6: Disconnected LLM for Lightspeed (feeds A3)

- [JIRA] OCPMCP-469 "Validate MCP server tool calling with offline / local models (disconnected GA path)" —
  **In Progress**, parent OCPSTRAT-3786 (MCP Server 1.1 GA enhancements). Intended model `gemma-4-31b`; "If Gemma 4
  is blocked by legal/product approval, substitute the current Red Hat-approved local model (e.g. Granite on
  RHOAI)"; dependency "Legal/product approval ... (Gemma 4 has an outstanding company-wide review)". Last comments
  2026-10-05 ask for status; no result posted. It concerns the **MCP server**, not OLS chat.
- [JIRA] OLS side: OLS-3472 "Agentic OLS support for disconnected (air-gapped) clusters: gemma-4-31b" — Closed/Done
  (mentions PIA and CMDB productization steps). OLS-4226 "Add disconnected Agentic OLS product-e2e with Gemma 4"
  (Closed, ols-2.0): Gemma 4 on RHOAI/KServe/vLLM via the OpenAI-compatible provider, NetworkPolicy egress block.
  OLS-4228 (Closed) parameterized RHOAI/vLLM provisioning. OLS-4227 (5.0 GPU pool + disconnected CI job) still in
  Review (ols-2.1).
- [JIRA] No ticket found that records the outcome of the Gemma 4 legal review (searched `summary ~ Gemma`, last
  120 days). Treat as **open**.
- [DOC] OLS 1.0 docs (https://access.redhat.com/documentation/en-us/red_hat_openshift_lightspeed/1.0/html-single/about/index):
  SaaS providers OpenAI, Azure OpenAI, watsonx; "If you want to self-host a model, you can use Red Hat OpenShift
  AI or Red Hat Enterprise Linux AI"; "Red Hat does not provide support for any specific models". The 5.0
  `openshift_lightspeed` book is a stub (D1). [DOC] 5.0 MCP docs `modules/ai-app-mcp-server-install.adoc`: "Gemma
  4 is also available for disconnected environments. Cloud-only results do not apply to disconnected deployments."
- [LAB] Our VAP tests used an OLSConfig with provider `rhoai_vllm`.
- [DOC] KB 7142179: OLS 1.0.11 tried to download a tiktoken file from openaipublic.blob.core.windows.net in
  disconnected clusters; fixed in 1.0.12 (OLS-2920). Re-check 2.0 for similar egress during a lab run.
- [DOC] KB 7125624: the Offline Knowledge Portal (RHOKP, the 7.7 GB `rhokp-rhel9` related image in
  lightspeed-operator 2.0) requires a **Satellite Infrastructure subscription** for an access key.

**Mirroring needs for a self-hosted LLM [INFER]**
- Operators: RHOAI (and its dependencies: Service Mesh/Serverless or KServe RawDeployment, Authorino as needed),
  NVIDIA GPU Operator + NFD (certified / redhat catalogs), lightspeed-operator (brings MCP server, RHOKP,
  agentic sandbox, postgres images).
- Model weights: as OCI "modelcar" images via `additionalImages`, or copied into S3-compatible storage/PVC.
  vLLM serving runtime image from the RHOAI related images.
- GPU sizing: Gemma 4 31B in BF16 is ~62 GB of weights → one 80 GB GPU (H100/A100-80G) or FP8/quantized on
  smaller cards. Check instance availability in GovCloud/ISO (p4d/p5 are scarce there).
- Egress: the OLS e2e uses NetworkPolicy to block external access; reuse that pattern.

## J7: OCPSTRAT-3755 selective related-image mirroring

- [JIRA] OCPSTRAT-3755 "OLM/Operator Metadata: Mandatory vs Optional Classification of Related Images for Selective
  Disconnected Mirroring" — **Backlog**, fixVersions empty, labels `pixaa`, `pixaa_prioritized`, components
  oc-mirror / Operator Framework / Operator Program. Created 2026-05-26.
- Comments (read the first ~30 and last 8 of 63): spike results 2026-10-13/14: Serverless ~70 %, ODF ~38 %, OSSM
  ~33 % (up to ~92 % with version pinning), CNV ~21 % disk savings; design direction is labels on related images
  plus an oc-mirror label selector, opt-in only. 2026-10-19: "spike here is complete, refinement done and ready to
  be worked on whenever needed". 2026-07-20 (PM): plan for 5.1 was information gathering only.
- Answer: not in 5.0 or 5.1; no target release.

## A4: OpenShift MCP server in 5.0

**Path 1: bundled with OpenShift Lightspeed 2.0**
- [LAB] `examples/operator-fips-and-signatures/RESULTS.md`: lightspeed-operator 2.0.0 related images include
  `openshift-mcp-server-rhel9@sha256:a551fd58...` (server 1.0.0, Go strict FIPS) and `rhokp-rhel9` (offline
  knowledge portal). Mirroring = include `lightspeed-operator` in the ISC; no Helm needed.
- [CODE] lightspeed-operator `main` `.ai/spec/what/ocpmcp.md`: standalone operand `openshift-mcp-server`
  (Deployment, Service :8443, NetworkPolicy, TOML ConfigMap), **gated by `spec.ols.introspectionEnabled`
  (default true when absent)**; false removes all MCP resources (`MCPServerReady=NotConfigured`). No RBAC for the
  server SA; callers pass their own token (user RBAC applies). TOML denies Secrets and all
  `rbac.authorization.k8s.io` resources. Toolsets pinned to `core, config, helm, observability/metrics, kubevirt`
  (+ `netobserv` planned). Image from `registry.redhat.io/openshift-mcp/openshift-mcp-server-rhel9`.
- [CODE] same file L88: e2e asserts at least one tool with `destructiveHint=true` and `readOnlyHint=false`, so the
  OLS-managed server is **not** in read-only mode; protection comes from the user's RBAC and the denied resources.
  (spec is `main`; 2.0.0 may differ; [INFER] lab-check the ConfigMap.)

**Path 2: standalone MCP server**
- [DOC] `ai_applications/mcp_server/mcp-server-overview.adoc` + modules: install = MCP gateway (Red Hat
  Connectivity Link) → **MCP Lifecycle Operator (Technology Preview)** → deploy from the MCP Catalog in Red Hat
  OpenShift AI. `modules/ai-app-mcp-server-install-lifecycle-operator.adoc`: requires "Red Hat OpenShift AI
  v3.6.0-ae2, which is an Early Release version" (channel `beta`). Prerequisite in `ai-app-mcp-server-install.adoc`
  still says "Red Hat OpenShift AI v3.5 installed on an OpenShift Container Platform v4.22 cluster" (inconsistent).
- [DOC] No Helm-chart install in the 5.0 MCP docs (the 4.22 guide used `helm install` from charts.openshift.io).
- [DOC] Restriction options, `modules/ai-app-mcp-server-ai-safety.adoc` and `-config-reference.adoc`:
  `read_only = true`, `disable_destructive = true`, `enabled_tools` / `disabled_tools`, `toolsets`,
  `denied_resources`; OSSM toolset defaults to `read_only = true`. Uninstall: `oc delete mcpserver --all
  --all-namespaces`; remove gateway access with `oc delete mcpsr <name>` (MCPServerRegistration).
- [JIRA] OCPSTRAT-3665 says MCP tool calls are GA in 5.0; findings §3b row "MCP Lifecycle Operator ... RHOAI 3.6".

**Keeping it off**
- Do not mirror lightspeed-operator (removes Path 1) and do not mirror RHOAI / Connectivity Link (removes Path 2).
- If OLS is wanted without cluster introspection: `OLSConfig spec.ols.introspectionEnabled: false` (our VAP blocks
  OLSConfig spec changes, so do it via the break-glass group).
- [INFER] Add `mcpservers` / `mcpserverregistrations` (API groups to confirm on a cluster with RHOAI 3.6) to the
  VAP if customers want policy enforcement for Path 2.

## ISO-4: AWS ISO / ISO-B install requirements in 5.0

**Documented requirements** [DOC] (`installing/installing_aws/ipi/installing-aws-specialized-region.adoc` and
included modules, enterprise-5.0):
- Supported secret regions: `us-iso-east-1` (C2S) and `us-isob-east-1` (SC2S) only
  (`modules/installation-aws-regions.adoc:90-95`).
- No published RHCOS AMI: upload a custom AMI, write install-config by hand (installer survey does not list the
  region), set region + `platform.aws.amiID` (`modules/installation-aws-regions-with-no-ami.adoc`).
- AWS API CA: "you must also define a custom CA certificate in the `additionalTrustBundle` field ... the CA
  certificates must also be defined on the machine that runs the installation program" (trust store,
  `AWS_CA_BUNDLE`, or `ca_bundle` in the AWS config) (same module L46).
- Clusters must be private: Route 53 public zones are not available (`modules/private-clusters-default.adoc:31`).
- No public EC2/ELB/S3 endpoints: create VPC endpoints `ec2|elasticloadbalancing|s3.<region>.c2s.ic.gov` (C2S) or
  `.sc2s.sgov.gov` (SC2S), or use a proxy (+ `noProxy`) (`modules/installation-custom-aws-vpc.adoc:119-181`).
- MTU differs in SC2S/C2S; UPI CloudFormation must use CNAME instead of ALIAS records; `destroy cluster` is not
  supported in C2S (`modules/installation-uninstall-clouds.adoc:40`); Marketplace images not supported.
- [JIRA] RFE-10089: installing to SC2S "works with one small change: you set the Route53 endpoint in
  install-config.yaml" → use `platform.aws.serviceEndpoints` (field exists, `pkg/types/aws/platform.go:69-73`).

**Stale warning in the 5.0 docs** [DOC]: the assembly still says installing into a secret region with the CAPI
implementation "has not been tested" and that NLB security groups cause installs to fail ("see OCPBUGS-33311").
[JIRA] OCPBUGS-33311 "[AWS CAPI install] Failed to create C2S/SC2S cluster via Cluster API" is **Closed,
Done-Errata, fixVersion 4.18.0**. Ticket candidate.

**AMI per osImageStream** [CODE] installer `origin/release-5.0`:
- `data/data/coreos/coreos-rhel-10.json`: release `10.2.20261026-0`, artifact
  `rhcos-10.2.20261026-0-aws.x86_64.vmdk.gz`; AWS AMIs for 34 regions incl. `us-gov-east-1/west-1`, none for ISO.
- `data/data/coreos/coreos-rhel-9.json`: `9.8.20261026-0`, `rhcos-9.8.20261026-0-aws.x86_64.vmdk.gz`; same region
  coverage.
- Use `openshift-install coreos print-stream-json --stream rhel-10|rhel-9` to get the matching VMDK; gunzip before
  `import-snapshot`. The docs procedure (`modules/installation-aws-upload-custom-rhcos-ami.adoc`) has no stream
  guidance, and its `RHCOS_VERSION` example `{product-version}.0` (= 5.0.0) does not match RHCOS 10.2/9.8 version
  strings. From notes/code-review-i5-i6.md: no check that a custom AMI matches `osImageStream`, and a custom AMI
  disables MCO boot-image management. Customers must import **both** AMIs if they keep rhel-9 pools.

**CA bundle plumbing** [CODE]:
- `pkg/asset/tls/cloudprovidercabundle.go:41-50` and `pkg/asset/manifests/cloudproviderconfig.go:108-116`: when
  `additionalTrustBundle` is set **and** `IsSecretRegion()` is true, the bundle is written as
  `cloud-ca-cert.pem` and into the cloud-provider-config `ca-bundle.pem` key.
- `pkg/asset/installconfig/aws/regions.go:56-70`: `IsSecretRegion` is true only for partitions `aws-iso` and
  `aws-iso-b`. [INFER] `aws-iso-e` / `aws-iso-f` regions would not get the CA bundle wired automatically (they are
  not supported anyway).
- [INFER] The same `additionalTrustBundle` must carry the mirror-registry CA too; use
  `additionalTrustBundlePolicy: Always` if needed so proxy/CA consumers see it.

**User-provisioned DNS bug**
- [DOC] KB 7140712 (updated 31 Mar 2026): IPI with user-provisioned DNS fails in Top Secret regions with "FATAL
  unable to handle api server override: no IP address found in lbconfig"; under investigation, tracked in
  OCPBUGS-78093.
- [JIRA] OCPBUGS-78093: status **POST**, no fixVersion. Fix PRs: openshift/installer#10531 (main/5.x) and #10555
  (4.22). 2026-05-18 comment: verified on GovCloud/EUSC CI, cannot test C2S/SC2S, will hold for customer testing.
- [CODE] `gh pr view`: #10531 **OPEN** (last update 2026-09-03), #10555 **OPEN** (2026-11-01). `pkg/infrastructure/
  aws/clusterapi/ignition.go` in release-5.0, release-5.1 and release-4.22 still looks up ENIs by security group →
  **not fixed in 5.0.0**.
- [JIRA] OCPBUGS-86038 ([release-4.22] backport): ASSIGNED; plan is 5.0 → 4.22 → 4.21.
- Guidance: do not use `userProvisionedDNS: Enabled` in ISO regions on 5.0.0; use Route 53 private zones.

## ISO-5: ccoctl / STS (credentialsMode Manual) in ISO and GovCloud

- [CODE] cloud-credential-operator `release-5.0` `pkg/cmd/provisioning/aws/create_identity_provider.go`:
  - `getPartition()` L453-464 returns `aws-us-gov`, `aws-cn`, `aws-eusc`, else **`aws`** → for `us-iso-*` /
    `us-isob-*` the public-read bucket policy is written as `arn:aws:s3:::<bucket>/*` (L723-729). [INFER] The S3
    API in `aws-iso(-b)` rejects that policy (wrong partition), so `ccoctl aws create-all` fails in ISO.
  - `getDNSSuffix()` uses the SDK resolver, so the bucket URL suffix is right (`c2s.ic.gov` / `sc2s.sgov.gov`).
  - `--create-private-s3-bucket` creates a CloudFront OAI + distribution (L94-188, L540-705). CloudFront does not
    exist in GovCloud or ISO.
  - IAM OIDC provider audience is hard-coded `openshift` + `sts.amazonaws.com` (L65-70, L344). [INFER] Unverified
    for ISO partitions.
- [JIRA] OCPSTRAT-3586 "Support AWS STS in AWS GovCloud and Secret regions without requiring CloudFront" —
  **Backlog**; 2026-10-07 Target Version removed ("very unlikely ... by pencils-down" for 5.1). Scope: `--issuer-url`
  flag (as for Azure), partition-correct ARNs; `aws-us-gov` committed; `aws-iso`, `aws-iso-b`, `aws-iso-e`,
  `aws-iso-f` "handled without commercial-AWS assumptions, but are not product-supported until the partition/region
  matrix and test environment are approved"; API Gateway documented as reference pattern for hosting the issuer.
  States: "the `--issuer-url` flag on its own is not sufficient: resource creation still fails in these
  partitions until partition handling is addressed".
- [JIRA] CCO-851 (epic, New, fixVersion openshift-5.1 but Target Version cleared 2026-10-30), CCO-853
  (productization), stories CCO-854..858, CCO-860 (Gov CI); RFE-9477 (Approved). 2026-10-26 comment from a field
  team waiting on it "for GovCloud and IL5 STS deployments".
- [JIRA] GovCloud history: OCPBUGS-13549 et al. "Failed to create STS resources on AWS GovCloud regions using
  ccoctl" (Closed, partition fix) and OCPBUGS-13623 "--create-private-s3-bucket option is not supported on AWS
  GovCloud" (Closed).
- [DOC] 5.0 `modules/cco-ccoctl-creating-at-once.adoc:189-199`: describes the public-bucket default and the
  CloudFront private-bucket option; no partition caveat. The specialized-region assembly includes the STS modules
  without saying they do not work in secret regions.

**Options**
| Environment | STS with ccoctl | Notes |
|---|---|---|
| GovCloud (`aws-us-gov`) | Works with the **default public S3 issuer** (what our lab does in commercial) | Requires a publicly readable S3 bucket; many agencies forbid it by SCP. `--create-private-s3-bucket` fails (no CloudFront). Self-hosted issuer is unsupported until OCPSTRAT-3586. |
| ISO / ISO-B | **Not supported**; `create-all` expected to fail on the bucket policy ARN | Workaround (unsupported): `ccoctl aws create-all --dry-run` (generates JSON/manifests), fix `arn:aws:` → `arn:aws-iso(-b):`, create bucket/OIDC provider/roles with the AWS CLI. Whether IAM in ISO can fetch an issuer URL from a regional S3 bucket must be checked with AWS. |
| Any | `credentialsMode: Mint` (default) or `Passthrough` | Long-lived IAM user keys in `kube-system`; doc prerequisite already says long-term credentials are required in specialized regions. |
| Any | `Manual` with long-term credentials (per-component IAM users/secrets) | `modules/manually-create-identity-access-management.adoc`; operator keys rotated by hand. |

## ISO-2: NLB security groups in secret regions (quick check)

- [CODE] installer `origin/release-5.0` and `origin/main`,
  `cluster-api/providers/aws/vendor/sigs.k8s.io/cluster-api-provider-aws/v2/pkg/cloud/services/elb/loadbalancer.go`:
  L69-70 `cantAttachSGToNLBRegions = sets.New("us-iso-east-1", "us-iso-west-1", "us-isob-east-1")`; L513-516
  sets `input.SecurityGroups = nil` for NLB creation in those regions; L1971-1981 skips SG reconciliation. Same in
  `release-4.22`. Introduced with "OCPBUGS-36293 bump/vendor" (commit 5ce8d664cf).
- [CODE] CAPA `pkg/cloud/services/securitygroup/securitygroups.go:718-756`: for NLBs CAPA opens 6443 and the
  additional listener ports (22623) on the control-plane SG from the VPC CIDR, so health checks and traffic work
  without an NLB SG.
- [JIRA] OCPBUGS-33311 (Closed, 4.18.0): the original C2S/SC2S CAPI failure.
- So the installer's `apiserver-lb` SG role in `pkg/asset/manifests/aws/cluster.go` is still created, but CAPA does
  not attach it in ISO regions. Our ISO-2 note ("no ISO special case") looked only at the installer, not CAPA.
- Still broken / open:
  - User-provisioned DNS path (OCPBUGS-78093, above): `ignition.go` finds NLB ENIs by SG, which fails in ISO.
  - Hard-coded region list lacks `us-isob-west-1` (RFE-10089, Backlog, requested for a named customer) and any
    `aws-iso-e/-f` regions. [INFER] An install there would try to attach an SG to the NLB and fail.
  - Ingress: OCP default ingress on AWS uses a Classic ELB (SGs supported); an NLB ingress
    (`providerParameters.aws.type: NLB`) uses cloud-provider-aws, not CAPA; whether CCM skips NLB SGs in ISO was
    not checked.
  - No lab possible in ISO; the 5.0 docs still say it is untested.

## Customer-facing implications

- oc-mirror v1 still runs in 5.0 but is undocumented and goes away in 5.2. Pipelines must move to `--v2`, v2alpha1
  ISCs and IDMS/ITMS outputs now; `describe`/`init` have no v2 replacement.
- The OpenShift Mirror Console is optional tooling, delivered with oc-mirror 2.0.0 and documented in 5.0.z; do not
  build customer procedures on it yet (no 5.0 catalogs upstream, FIPS status unverified).
- AI off on upgraded clusters: remove OLS **before** mirroring the v5.0 operator catalog, or pre-create
  `AgenticOLSConfig cluster` with `suspended: true` and review the 2.0 InstallPlan manually. LightspeedButton
  alone is not enough. Update our VAP so it allows the kill switch.
- Disconnected Lightspeed needs a self-hosted LLM on RHOAI/vLLM with GPUs; Red Hat names Gemma 4 31B in CI and
  docs but does not support specific models, and the Gemma legal review is not visibly closed. RHOKP inside OLS
  needs a Satellite Infrastructure subscription for its access key.
- The MCP server comes in with OLS 2.0 by default (`introspectionEnabled` defaults to true) and is not read-only;
  turn it off in OLSConfig if not wanted. The standalone MCP server path depends on a TP operator and an RHOAI
  early-release build, so it is not ready for regulated customers.
- ISO/ISO-B IPI: the NLB security-group blocker is fixed in code since 4.18, so IPI is plausible in `us-iso-east-1`
  and `us-isob-east-1`, but Red Hat docs still say "not tested"; customers need custom AMIs per stream, the AWS CA
  bundle in `additionalTrustBundle` and on the install host, VPC endpoints, private Route 53, and must avoid
  user-provisioned DNS on 5.0.0. `us-isob-west-1` is not supported.
- STS: GovCloud only with a public S3 issuer bucket; ISO has no supported STS path in 5.0 (use Mint/Passthrough or
  manual long-term credentials). No fix before 5.2 at the earliest.

## New ticket candidates (summaries only, not filed)

1. **OSDOCS: stale "secret regions not tested / OCPBUGS-33311" warning** in
   `installing/installing_aws/ipi/installing-aws-specialized-region.adoc`; OCPBUGS-33311 was fixed in 4.18.0 and
   CAPA strips NLB SGs in ISO regions. Ask for a tested/supported statement for 5.0.
2. **OSDOCS: custom RHCOS AMI procedure lacks osImageStream guidance**
   (`modules/installation-aws-upload-custom-rhcos-ami.adoc`): explain rhel-10 vs rhel-9 VMDKs, `print-stream-json
   --stream`, `.vmdk.gz` decompression, version string example (`{product-version}.0` is wrong for RHCOS 10.2).
3. **OSDOCS: STS modules included in the specialized-region assembly without a secret-region caveat**; ccoctl
   cannot create resources in `aws-iso(-b)` (partition) and `--create-private-s3-bucket` needs CloudFront.
4. **OCPBUGS (CCO): ccoctl `getPartition()` maps `us-iso*`/`us-isob*` regions to `aws`** — wrong ARN in the public
   OIDC bucket policy. Overlaps CCO-858 (story under CCO-851); comment there rather than a new bug.
5. **OCPBUGS/RFE (installer/CAPA): `cantAttachSGToNLBRegions` hard-codes three regions**; `us-isob-west-1`
   (RFE-10089) and future ISO-E/F regions would break. Suggest partition-based detection. Comment on RFE-10089.
6. **OLS docs / RFE: document AI Hub behaviour on 4.x → 5.0 upgrade and the AgenticOLSConfig kill switch**, and
   whether absence means enabled (2.0) or disabled (unified bundle). Possibly a comment on OSDOCS-24192 (AI opt-out).
7. **OSDOCS: residual oc-mirror v1 content** — ZTP precache `modules/ztp-precaching-custom-disconnected.adoc`
   (`mirror.openshift.io/v1alpha2`).
8. **OSDOCS: MCP server install prerequisites inconsistent** (`ai-app-mcp-server-install.adoc` says RHOAI 3.5 on
   OCP 4.22; lifecycle-operator module requires RHOAI 3.6.0-ae2 early release).
9. Local (not Jira): amend `examples/ai-opt-out-policy/policy.yaml` to allow `AgenticOLSConfig` with
   `spec.suspended == true`; lab-test the 4.22 → 5.0 OLS upgrade (with OLSConfig) to confirm AI Hub appears and the
   VAP blocks it; check `introspectionEnabled` and the generated MCP TOML on 2.0.0.
