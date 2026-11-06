# runC vs RHCOS 10 on a standalone OCP 5.0.0 cluster: one-worker lab test (2026-11-06)

Cluster: install 5 (5.0.0, FIPS, default OSImageStream `rhel-10`, crun everywhere, no ContainerRuntimeConfig or 4.17 override MachineConfigs). Test node: worker `ip-10-0-55-41`, moved into a custom pool `runc-test` (selects the worker MachineConfigs plus role `runc-test`). Research and code references: `notes/research-runc-rhcos10.md`. Step logs: `step0.log` .. `step6.log`. All [LAB] unless tagged.

| Step (UTC) | Action | Result | Node |
|---|---|---|---|
| 0 (14:28) | Create pool `runc-test`, label the node | Pool rendered the same content as worker (`rendered-runc-test-6640ec60…` = worker hash) | no reboot |
| 1 (14:28) | ContainerRuntimeConfig `defaultRuntime: runc` on the pool (stream rhel-10) | `RenderDegraded=True`: "MachineConfigPool runc-test targets a RHEL 10 OS image where runc is not available. To unblock, migrate to crun by removing any ContainerRuntimeConfig that sets defaultRuntime to runc, and removing any MachineConfig that sets default_runtime = "runc" in CRI-O configuration under /etc/crio/crio.conf.d/". Pool `Degraded=True`; machine-config CO `Upgradeable=False` (DegradedPool), `Degraded=False`. `EvaluationConditionsDetected` still False at +90 s. | untouched (same boot ID, schedulable, state Done) |
| 2 (14:30) | Pool `spec.osImageStream.name: rhel-9` | Render OK; drain + reboot; node on **RHCOS 9.8.20261026-0**, `/usr/bin/runc` present, `default_runtime = "runc"`; pool Updated at 14:36 (~6 min). CO `Upgradeable=True`, `EvaluationConditionsDetected=True` ("runc: transition to default crun"). | 1 reboot |
| 3 (14:36) | Add a MachineConfig identical to the 4.17 override (`00-override-runc-test-generated-crio-default-container-runtime`), delete the ContainerRuntimeConfig | Same rendered config (identical content), no update. Node still on runc: `container_runtime_crio_default_runtime{runtime="runc"} 1` for 10.0.55.41 (crun on the other 4 nodes); `RuncDeprecated` (severity info) pending since 14:36:35. **`EvaluationConditionsDetected=False`** at +6 min. | no reboot |
| 4 (14:44) | Pool back to `rhel-10` with the override present | `RenderDegraded=True` (same message), CO `Upgradeable=False`; node stays on RHCOS 9.8 | untouched |
| 5 (14:46) | Delete the override MachineConfig | RenderDegraded clears immediately; cordon/drain at +20 s; node on **RHCOS 10.2.20261027-0**, runc absent, `default_runtime = "crun"`; pool Updated at 14:49 (~3.5 min); CO `Upgradeable=True` | 1 reboot |
| 6 (14:50) | Unlabel the node, delete the pool | Node back on `rendered-worker-6640ec60…` (same content), 32/32 COs healthy, all pods Running, no runc/override objects left | no reboot |

## Conclusions
1. **The 5.0 render guard works and is safe** on standalone clusters: a pool that targets RHEL 10 while its effective CRI-O default is runc gets `RenderDegraded=True` and blocks upgrades (`Upgradeable=False`), with a clear remediation message. Nodes are not drained, rebooted or broken. There is **no silent fallback to rhel-9** (unlike the hosted control plane NodePool controller).
2. **The guard catches implicit runC** (a MachineConfig shaped like the 4.17.11 override), not just ContainerRuntimeConfigs (step 4).
3. **`EvaluationConditionsDetected` misses the override case** (step 3): node on runc, alert pending, condition False. It also lags after a ContainerRuntimeConfig is created (step 1). Confirms the MCO bug draft (`jira/draft-mco-runc-eval-misses-override-mcs.md`).
4. **`RuncDeprecated` and the `container_runtime_crio_default_runtime` metric are the reliable signals**, per node.
5. **Removing the runC pin reboots the pool** [LAB + CODE]: `/etc/crio/crio.conf.d/` has no entry in the cluster's node disruption policy (live `machineconfiguration/cluster` status), so the default action (drain + reboot) applies. Step 5 combined the runtime and OS changes, so the runtime-only reboot is from the policy/code, not observed separately.
6. Mixed RHCOS 9.8 / 10.2 nodes ran for ~16 min without problems, but this is unsupported (release notes 1.3.12); test only.
