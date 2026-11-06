# runC vs RHCOS 10 on OpenShift 5.0: research notes (2026-11-06)

Scope: tracker rows F8, J10, DOC-13. Local, read-only research. No lab run yet.
Sources: MCO clone `/home/danclark/workspace/upstream/machine-config-operator` (blobless; `release-5.0` = `release-4.23` = 0e2557038; `release-5.1` = `main` = 250cb365b), openshift-docs `enterprise-5.0` @ b5698adc31 (2026-11-05; these modules are also live on docs.redhat.com 5.0), Jira, KCS.

## Short answers

**Q1. Implicit runC on upgraded clusters: yes, and it is common.**
Any cluster that ran a **4.17.z release at or after 4.17.11** (fresh install or upgrade; the creation code exists only on release-4.17, not 4.18+) has MCO-created MachineConfigs `00-override-{master,worker}-generated-crio-default-container-runtime`. They write `default_runtime = "runc"` to `/etc/crio/crio.conf.d/01-ctrcfg-defaultRuntime`. No 4.18+ release removes them on OCP (only OKD did). So nearly every cluster installed on 4.17 or earlier and then upgraded is still on runC today, **with no ContainerRuntimeConfig**. Clusters installed on 4.18+ use crun (spot-check 2026-11-06: our fresh 5.0.0 cluster has no `00-override-*-crio-default-container-runtime` MachineConfigs, and its nodes run crun). [CODE][JIRA][DOC][LAB]

**Q2. Standalone 5.0: MCO refuses to render. It does not pin to rhel-9 and does not break a node.**
If a pool targets a RHEL 10 stream and its merged config has runC as the effective CRI-O default, the render controller refuses to create the rendered MachineConfig. The pool goes `RenderDegraded=True`, then `Degraded=True`, and the machine-config ClusterOperator goes `Upgradeable=False` (`DegradedPool`). Nodes stay on their current config.
- The 4.22 → 5.0 upgrade is not blocked: clusters installed on 4.x keep `rhel-9` as the default stream. The block only fires when someone switches the stream.
- A fresh 5.0 install with a day-0 runC ContainerRuntimeConfig and the default `rhel-10` fails at bootstrap render.
- Unlike HCP, standalone MCO never picks rhel-9 automatically. [CODE][DOC]

**Q3. Detection is partial.**
- 4.22 and 5.0 ship the `RuncDeprecated` alert (severity info, based on a CRI-O metric). It catches both implicit and explicit runC.
- The machine-config CO condition `EvaluationConditionsDetected` (reason `runc: transition to default crun`) catches **only ContainerRuntimeConfig CRs**. It misses the 4.17 override MCs.
- There is no Upgradeable=False on 4.22 → 5.0 for runC.
- Commands are in the checklist below. [CODE]

**Q4. Real but mostly fixed crun issues.**
- An early crun graceful-shutdown bug delayed the default (OCPBUGS-41956).
- The CRI-O `allowed_annotations` lists are per runtime, so `TrySkipVolumeSELinuxLabel` silently stopped working on crun (KCS 7123294).
- crun cgroup fork hang in burst starts (OCPBUGS-85021, fixed in 4.18.32 / 4.19.14 / 4.20.0 per KCS 7135982).
- crun 1.27 idmapped-mount leak with user-namespace pods (OCPBUGS-105888 / RHEL-238820).
- Most customers are on runC by inertia (the 4.17 pin), not by choice. [JIRA][DOC]

**Q5. Docs gaps.** The upgrade path is documented in `config-container-runtime.adoc` and `mco-image-streams-updating.adoc`. Five other modules still offer runC with no RHCOS 10 caveat. The override-MC explanation ("updated from 4.17") is narrower than the code. There is no pre-check command, no mention of the alert, and the day-0 failure is undocumented. [DOC]

---

## Evidence

### Q1: how the runtime default evolved

| When | What | Ref |
|---|---|---|
| ≤ 4.17 | The MCO template `templates/*/01-*-container-runtime/_base/files/crio.yaml` has **no** `default_runtime`, so the CRI-O package default (runc) applies. | [CODE] `git grep default_runtime origin/release-4.14 -- templates` → none; release-4.17 lists `[crio.runtime.runtimes.runc]`/`crun` only |
| 2024-09 (4.18 dev) | CRI-O 1.31 switched upstream to crun. MCO forced runc (OCPBUGS-41956, 49800e413, "outstanding bug in crun that's breaking graceful shutdowns"), then set crun as the default in a19e3250d (2024-09-24). | [CODE][JIRA] |
| 4.18+ | The template writes `default_runtime = "crun"` into `/etc/crio/crio.conf.d/00-default`. Template MCs are re-rendered on every upgrade, so without anything else an upgraded cluster **would** flip to crun. | [CODE] release-4.18 … release-5.0 `templates/worker/01-worker-container-runtime/_base/files/crio.yaml:20` |
| 4.17.11 (RHBA-2025:0023) | **OCPBUGS-38292** "upgrades from 4.17 to 4.18 currently default to crun". release-4.17 PR #4715 (merge d7c30c8b0, 2024-12-18) adds `createDefaultContainerRuntimeMC()`. On every sync, and once at start-up (`forceSyncOnUpgrade`), it creates `00-override-<master\|worker>-generated-crio-default-container-runtime` with `/etc/crio/crio.conf.d/01-ctrcfg-defaultRuntime` = `default_runtime = "runc"`, plus the marker ConfigMap `openshift-machine-config-operator/crio-default-container-runtime`. It only skips a pool if a ContainerRuntimeConfig-generated MC already sets `default_runtime`. **It does not check whether the cluster was upgraded**, so fresh 4.17.11+ installs get it too. | [CODE] `origin/release-4.17:pkg/controller/container-runtime-config/container_runtime_config_controller.go:604-611,1052-1124`, `helpers.go:345-349,457-466`; [JIRA] OCPBUGS-38292 (QE verified the file on 4.17→4.18) |
| 4.18 … 5.0 | The creation code is absent (main reverted it 2024-11-22, 57e60ff6e). **Nothing deletes the MCs on OCP.** 4.22 has `migrateRuncToCrun()`, which deletes them, but it is gated by `version.IsSCOS()` (OKD only, OKD-294). It is removed on release-5.0/main (OKD-305, 17014017b). | [CODE] `origin/release-4.22:…/container_runtime_config_controller.go:727-795`; `git grep crio-default-container-runtime origin/release-5.0` → none |
| Docs/KCS confirm | "If you updated your cluster from 4.17, the runC container runtime remains unchanged as the default… two MachineConfig objects… were created". KCS 7135982: clusters installed before 4.18 "do not automatically change the container runtime as part of an upgrade". KCS 7137935: ARO, same MC names. | [DOC] `modules/config-container-runtime.adoc:21-45`; KCS 7135982, 7123294, 7137935 |

[INFER] 4.18 GA (early 2025) came after 4.17.11 (2025-01-08), so practically every 4.17 → 4.18 upgrade passed through a 4.17.z with the fix. Exceptions: clusters that upgraded to 4.18 from a 4.17.z below 4.17.11, which KCS 7123294 says ended up on crun, and clusters whose admins already deleted the MCs. Conclusion: **runC is the default on most long-lived customer clusters, not a niche ContainerRuntimeConfig case.**

Side effect [CODE]: `/etc/crio/crio.conf.d/*` is not in the default node-disruption policy (`pkg/apihelpers/apihelpers.go`) or the rebootless list (`pkg/daemon/update.go:607-645`). So deleting the override MCs or a ContainerRuntimeConfig causes a **drain and reboot** of every node in the pool, and after the reboot every pod runs on crun. The docs line "Changing the container runtime affects new workloads only. Existing workloads continue to use their existing container runtime" (`config-container-runtime.adoc:19`) is misleading for this case [INFER].

### Q2: standalone 5.0 behaviour

- **Render guard** [CODE] release-5.0 `pkg/controller/render/render_controller.go`:
  - `syncGeneratedMachineConfig` (L723-768) calls `validateNoRuncOnRHEL10FromOSImageStream` (L1025) when the pool has a stream, or `validateNoRuncOnRHEL10FromOSImageURL` (L1048) when osImageURL is overridden. The second one reads the image's stream-class label, so a custom RHEL 10 osImageURL is also caught.
  - On error, `syncFailingStatus` (L603) sets `RenderDegraded=True` with the message "MachineConfigPool <pool> targets a RHEL 10 OS image where runc is not available. To unblock, migrate to crun by removing any ContainerRuntimeConfig that sets defaultRuntime to runc, and removing any MachineConfig that sets default_runtime = "runc" in CRI-O configuration under /etc/crio/crio.conf.d/".
  - No new rendered MC is created, so the pool's nodes are not touched.
- **Detection logic** [CODE] `pkg/controller/common/helpers.go:1562` `DetectRuncInMachineConfig`: decodes every Ignition file under `/etc/crio/crio.conf.d/`, sorts them lexicographically and keeps the last `default_runtime`. `00-default` (crun) sorts before `01-ctrcfg-defaultRuntime` (runc), so **the 4.17 override MCs are caught**, the same way a ContainerRuntimeConfig is.
- **Bootstrap** [CODE] `RunBootstrap` (L972-1019) runs the same checks. So a 5.0 install with a day-0 runC ContainerRuntimeConfig manifest and the default `rhel-10` fails bootstrap render. Setting `osImageStream: rhel-9` in install-config avoids it.
- **Pool degraded → CO** [CODE] `pkg/controller/node/status.go:369` (RenderDegraded counts as Degraded); `pkg/operator/status.go:262-300` `syncUpgradeableStatus` → machine-config CO `Upgradeable=False`, reason `DegradedPool`.
- **Default stream on upgraded clusters** [CODE] `pkg/osimagestream/streams.go:30` `GetBuiltinDefaultStreamName(installVersion)` returns rhel-9 when the install version major is 4, and rhel-10 for 5+. The install version comes from the first completed ClusterVersion history entry (`clusterversion.go` `GetInstallVersion`). So 4.x → 5.0 keeps rhel-9, and runC keeps working until the admin patches `osimagestream cluster spec.defaultStream: rhel-10` or a pool's `spec.osImageStream`. The stream switch itself is accepted (`osimagestream_controller.go` `handleOSImageStreamUpdate` validates only that the stream exists). The block happens afterwards, at render time.
- **No auto-pin**: standalone MCO has no "runc → rhel-9" selection. The HCP NodePool behaviour (`modules/hcp-dual-stream-container-runtime.adoc:32-34`) is HyperShift-specific. [CODE][DOC]
- **History** [CODE][JIRA]:
  - fd486c215 (2026-04-28) + PR #5891, OCPNODE-4443 "Implement upgrade block from RHCOS 9 to RHCOS 10 when runc is in use" (merge 60b01ff35).
  - 50a508813 bootstrap path.
  - PR #6238, OCPNODE-4518 osImageURL inspection (merge 3b4a5c7d9).
  - Umbrella: OCPSTRAT-3154 "runc deprecation warning in 5.0 for cluster upgrading from 4.22" (Release Pending), docs OSDOCS-19155 (live).
  - The comment in #5891 says "TODO(OCP 5.3): Remove this guard once RHEL 9 is no longer supported".
- **Documented** [DOC] `modules/mco-image-streams-updating.adoc:28-56` shows the exact RenderDegraded/Degraded status. Wording nit: it says "the nodes in the pool will degrade and will not update". Per the code, the *pool* degrades; nodes are untouched.
- [INFER, needs lab] While a pool is RenderDegraded, any later MCO change for that pool (including z-stream upgrades) cannot render, so a z-stream upgrade would likely stall at machine-config. Recovery: revert `defaultStream` to rhel-9, or remove runC.

### Q3: detection

| Mechanism | Where | Catches implicit (override MC)? | Catches ContainerRuntimeConfig? |
|---|---|---|---|
| Alert `RuncDeprecated`: `count(container_runtime_crio_default_runtime{runtime="runc"}) > 0`, for 10m, severity **info**, runbook `machine-config-operator/RuncDeprecated.md` | `install/0000_90_machine-config_01_prometheus-rules.yaml` on release-4.22 and release-5.0 (**not** in release-4.20/4.21); OCPBUGS-84691, 138f7a5ef. The template enables the `default_runtime` CRI-O metric collector. | yes (measures what CRI-O actually runs) | yes |
| CO condition `EvaluationConditionsDetected=True`, reason `runc: transition to default crun` | `pkg/operator/status.go:349-371,398-416` (since 4.16, OCPBUGS-32138) | **no**: lists ContainerRuntimeConfigs only | yes |
| Upgradeable=False on 4.22 → 5.0 | none for runC | n/a | n/a |
| Render block | 5.0, only after a stream switch | yes | yes |
| Insights rule | none found | | |

[CODE] for all rows. [INFER] Disconnected clusters with Insights/telemetry off only get the in-cluster alert. Because it is severity info, it does not show in the console overview by default.

### Q4: why runC is still used, and known crun differences

| Issue | Status | Ref |
|---|---|---|
| Inertia: the 4.17.11+ override MCs keep upgraded clusters on runC automatically | by design | OCPBUGS-38292; KCS 7135982 |
| crun graceful-shutdown bug delayed the 4.18 default | fixed before 4.18 GA | OCPBUGS-41956 |
| `io.kubernetes.cri-o.TrySkipVolumeSELinuxLabel` (and any custom annotation) is allowed per runtime. Customers who added it only under `[crio.runtime.runtimes.runc]` lose it on crun, and pods with large PVs then time out on SELinux relabel. | config fix: add the annotation under `crun` too | KCS 7123294 |
| crun processes block in `cgroup_css_set_fork()` during bursts of 100+ containers (runC on 4.16 was fine) | fixed in OCP 4.18.32 / 4.19.14 / 4.20.0 per KCS; Jira closed Not a Bug | OCPBUGS-85021; KCS 7135982 |
| crun 1.27 (RHCOS 9.6, OCP 4.21.22+) leaks nested idmapped mounts: Tekton `hostUsers: false` + nested PVC fails relabel | fix in crun 1.27.1; RHEL backport RHEL-238820 (New) | OCPBUGS-105888 |
| Switching runtime through a ContainerRuntimeConfig did not update conmon `--root` | fixed in 4.18.0 / 4.19.0 | OCPBUGS-51132, OCPBUGS-47629 |
| Opposite direction: runc did not restore CPU affinity of burstable pods (crun fine) | Won't Do | OCPBUGS-43995 |
| runc 1.2.9 hangs on high-CPU nodes; KCS suggests crun | | KCS 7135190 |
| RHEL 8 workers + crun cgroup v1 `devices.allow` EPERM | fixed (Errata); irrelevant to 5.0 | OCPBUGS-59843 |

No open, crun-specific workload incompatibility was found that would justify staying on runC in 5.0. The remaining risk is per-runtime CRI-O config (annotations, `runtime_root`, hooks) that customers added for `runc` only. [INFER]

### Q5: docs (enterprise-5.0 @ b5698adc31; same text on docs.redhat.com 5.0)

| File | Problem |
|---|---|
| `modules/rhcos-key-features.adoc:20` | "CRI-O can use either crun or runC… For information about how to enable runC…". No RHCOS 10 caveat, although RHCOS 10 is the 5.0 default. |
| `modules/architecture-machine-roles.adoc:64-68` | Same: "how to enable runC instead of the default crun". |
| `modules/create-a-containerruntimeconfig-crd.adoc:23,72-115,229` | Example sets `defaultRuntime: "runc"`, with no deprecation note or RHCOS 10 warning. It is included in 3 assemblies, including two ocp-jobs maps. Ayato Tokubi flagged it in OSDOCS-19155 (2026-04-30); still unchanged. |
| `nodes/containers/nodes-containers-using.adoc:71-77` | "runC has some benefits… Default container runtime of CRI-O" (false since CRI-O 1.31 / OCP 4.18). "You can move between the two container runtimes as needed" (false on RHCOS 10). |
| `modules/switch-the-container-runtime-used-for-workloads-on-my-nodes-between-runc-and-crun-con.adoc` | Generic switch text, no RHCOS 10 caveat. |
| `modules/config-container-runtime.adoc:21,32` | "If you updated your cluster from 4.17" is too narrow: per the code, any cluster that *ran* 4.17.11+ (including fresh installs) has the MCs. It covers only master/worker; it should mention custom pools that inherit worker MCs and should say that deleting the MCs reboots every node. |
| `modules/mco-image-streams-updating.adoc:28` | Good coverage of the block. "nodes … will degrade" should be "the pool degrades; nodes are not changed". No pre-check command, and no mention of the `RuncDeprecated` alert or `EvaluationConditionsDetected`. |
| (missing) | A day-0 runC ContainerRuntimeConfig with a 5.0 install (default rhel-10) fails bootstrap. Standalone MCO does **not** auto-select rhel-9 (contrast HCP); this is not stated anywhere for standalone. |
| `modules/rn-ocp-release-notes-new-features.adoc:612` | Fine, but it links only to the procedure. A one-line detection command would help. |

---

## (a) Customer pre-upgrade checklist (run on 4.22 before planning the RHCOS 10 switch)

```bash
# 1. Implicit runC from 4.17.11+ (most upgraded clusters)
oc get mc -o name | grep generated-crio-default-container-runtime
oc -n openshift-machine-config-operator get cm crio-default-container-runtime   # marker; harmless if present

# 2. Explicit runC via ContainerRuntimeConfig
oc get containerruntimeconfig -o custom-columns=NAME:.metadata.name,RUNTIME:.spec.containerRuntimeConfig.defaultRuntime,POOLSEL:.spec.machineConfigPoolSelector

# 3. Hand-written MCs that set default_runtime (what the 5.0 render guard looks for)
for mc in $(oc get mc -o name | grep -v rendered-); do
  oc get "$mc" -o json | jq -r --arg mc "$mc" '.spec.config.storage.files[]? | select(.path|startswith("/etc/crio/crio.conf.d/")) | "\($mc) \(.path)"'
done   # then inspect the contents of any hit for default_runtime

# 4. What every node actually runs (authoritative)
for n in $(oc get nodes -o name); do echo "== $n"; oc debug -q "$n" -- chroot /host sh -c 'crio status config 2>/dev/null | grep -m1 default_runtime'; done

# 5. In-cluster signals (4.22+)
oc get co machine-config -o jsonpath='{.status.conditions[?(@.type=="EvaluationConditionsDetected")]}{"\n"}'   # ContainerRuntimeConfig only
#   Console > Observe > Alerting: RuncDeprecated (severity info), or PromQL:
#   count by (node) (container_runtime_crio_default_runtime{runtime="runc"})

# 6. CRI-O per-runtime customizations that will not carry over to crun
#    (allowed_annotations, runtime_root, hooks under [crio.runtime.runtimes.runc])
oc debug -q node/<node> -- chroot /host sh -c 'crio status config | sed -n "/runtimes.runc/,/^\[/p"'
```

Migration (on 4.22 or on 5.0 while still on rhel-9):
1. Test workloads on crun first, using a one-node custom MCP.
2. Delete the override MCs and/or the runC ContainerRuntimeConfigs. This triggers a rolling drain and reboot.
3. Re-run step 4 of the checklist.
4. Only then patch `osimagestream cluster spec.defaultStream: rhel-10`.

If a pool goes RenderDegraded after the switch, revert `defaultStream` (or the pool's `osImageStream`) to `rhel-9`, fix the runtime, and retry.
For new 5.0 installs: do not ship a runC ContainerRuntimeConfig as a day-0 manifest unless install-config sets `osImageStream: rhel-9`.

## (b) Proposed tickets (not filed)

1. **OSDOCS**: runC is still offered without the RHCOS 10 caveat in `rhcos-key-features.adoc`, `architecture-machine-roles.adoc`, `create-a-containerruntimeconfig-crd.adoc`, `nodes-containers-using.adoc` ("Default container runtime of CRI-O", "move between… as needed") and the switch-runtime ocp-jobs module. Also fix "nodes will degrade" in `mco-image-streams-updating.adoc`, add a detection command and the `RuncDeprecated` alert, and state that standalone clusters do not auto-select rhel-9 and that a day-0 runC ContainerRuntimeConfig fails a default 5.0 install.
2. **OSDOCS**: `config-container-runtime.adoc`: the override MCs exist on any cluster that ran 4.17.11+, not only "updated from 4.17". Mention custom pools and that deleting the MCs reboots every node in the pool.
3. **OCPBUGS (MCO)**: `cfeEvalRunc` / `EvaluationConditionsDetected` ignores the MCO-created `00-override-*-generated-crio-default-container-runtime` MCs, so it under-reports the most common runC case. Suggest reusing `DetectRuncInMachineConfig` on the rendered configs.
4. **RFE (MCO)**: an OCP equivalent of the OKD-only `migrateRuncToCrun()`, or an `Upgradeable=False` / warning on 4.22 when runC is in use, given that RHCOS 9 is removed in 5.3. Consider raising `RuncDeprecated` from info to warning in 5.x.
5. Optional **OCPBUGS/RFE (installer)**: validate a day-0 runC ContainerRuntimeConfig against `osImageStream` in install-config (fail early instead of a bootstrap render failure).

## (c) Lab test: still needed, small, on a one-worker custom MCP of the live 5.0 cluster

The code path is clear [CODE]; the lab should confirm the runtime effects. The rhel-9 images (rhel-coreos 9.8 + extensions) are already in the mirror (M5).

1. Create MCP `runc-test` (selects worker MCs + its own role, one node). Apply a ContainerRuntimeConfig `defaultRuntime: runc` to it. The cluster is a 5.0 install, so the stream is rhel-10. **Expect:** pool `RenderDegraded=True` with the documented message, `Degraded=True`; node not drained or rebooted; machine-config CO `Upgradeable=False` (DegradedPool) and `EvaluationConditionsDetected=True` (`runc: transition to default crun`); other pools unaffected.
2. Set `runc-test` `spec.osImageStream.name: rhel-9`. **Expect:** render succeeds, the node reboots into RHCOS 9.8, `crio status config` shows runc, and the `RuncDeprecated` alert fires after about 10 min. This is an unsupported mixed-stream end state; keep it short.
3. Delete the ContainerRuntimeConfig. Create an MC that mimics the 4.17 override (`00-override-runc-test-generated-crio-default-container-runtime`, file `/etc/crio/crio.conf.d/01-ctrcfg-defaultRuntime`, `default_runtime = "runc"`). **Expect:** node still on runc and the alert still firing, but `EvaluationConditionsDetected` returns to False (confirms ticket 3).
4. Switch `runc-test` back to rhel-10 while the override MC exists. **Expect:** RenderDegraded again, meaning the guard catches implicit runC.
5. Delete the override MC. **Expect:** RenderDegraded clears, drain + reboot to RHCOS 10.2, runtime crun, alert clears. Record the reboot (validates the "new workloads only" docs claim).
6. Clean up: delete the MCP after moving the node back to worker, and check 32/32 COs. Optional: check whether a z-stream render is really blocked while degraded; that needs an upgrade, so skip it.

Not lab-testable here: the real 4.17.11 → 4.18 → … → 4.22 → 5.0 path (needs a 4.17 install). The code and KCS evidence are strong enough for guidance.
