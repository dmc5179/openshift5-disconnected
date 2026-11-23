# Read-only runC check on a 4.22 cluster (2026-11-22) [LAB, read-only]

Dan's RHOAI MaaS cluster, used with his approval for read-only checks only. AWS us-east-2, **OCP 4.22.18, fresh install** (ClusterVersion history: 4.22.18 only). 7 nodes on RHCOS 9.8.20261006-0, CRI-O 1.35.9. Nothing on the cluster was changed: no debug pods, only `oc get` and one `oc exec` Prometheus query.

| Check | Result |
|---|---|
| `oc get mc \| grep generated-crio-default-container-runtime` | none |
| ContainerRuntimeConfigs | none |
| Marker ConfigMap `openshift-machine-config-operator/crio-default-container-runtime` | NotFound |
| `container_runtime_crio_default_runtime` | 7/7 nodes `runtime=crun` |
| `RuncDeprecated` alert | rule present (`count(container_runtime_crio_default_runtime{runtime="runc"}) > 0`, for 10m, severity info), not firing |
| machine-config CO | `EvaluationConditionsDetected=False`, `Upgradeable=True` |

**Reading:** a cluster installed fresh on 4.18+ (here 4.22.18) has no override MachineConfigs and no marker ConfigMap, and runs crun everywhere. That matches the code: the MCs are created only by a 4.17.11+ controller (OSDOCS-24640). So it's a negative control for that ticket; a cluster with 4.17 history would be the positive case.

The detection commands proposed in OSDOCS-24639/24640 work as written on 4.22. They return empty or crun here.
