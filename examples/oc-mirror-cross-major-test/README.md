# oc-mirror cross-major-channel test

The goal is to see what oc-mirror v2 actually does when one ImageSetConfiguration spans OCP 4.x → 5.x.

## How to run
See **RUNBOOK.md** for step-by-step prep, run, collect and cleanup commands for cases A, C and D. Correction to an earlier draft: do not pass `--workspace` with a `file://` destination; oc-mirror rejects it.

## Cases and predictions (from reading the code; not yet run)
| Case | Config | Predicted | What confirms the bug |
|---|---|---|---|
| A | `candidate-4.22` + `candidate-5.0` | Fails, or mirrors a 4.23 EC pre-release | The log shows `channel candidate-4.23` and/or `candidate-4.24`, and no use of the `candidate-5.0` 4.22.21→5.0.0 edge |
| B | `stable-4.22` + `stable-5.0` | Fails looking up `stable-4.23` (**run after GA**; `stable-5.0` is empty until then) | Error refers to `stable-4.23` |
| C | `candidate-5.0` only, min 4.22.20, max 5.0.0 | Succeeds: 4.22.20 → (4.22.21) → 5.0.0 | **Workaround** confirmed |
| D | `candidate-4.21` + `candidate-4.22` | Succeeds | Control: multi-channel works within one major |

## Why the upgrade graph doesn't save it
oc-mirror fetches the graph **per channel**. Within one channel it runs shortest-path over the real edges (`GetUpdates`). When several channels are listed, `calculate()` picks the *next channel to fetch* by building the name `prefix-MAJOR.(MINOR+1)` itself, instead of asking the graph. 4.22 → `4.23` → `4.24` never becomes `5.0`. The target channel `candidate-5.0` already contains the 4.22.x nodes and the 4.22.21→5.0.0 edge, so querying it directly would work. That is the suggested fix, and Case C is the workaround.

Cincinnati data as of 2026-11-02:
- `candidate-4.22`: max 4.22.21
- `candidate-4.23`: 4.22.x plus 4.23.0-ec.0/ec.1 only
- `candidate-4.24`: empty
- `candidate-5.0`: 51 nodes including 4.22.x, 5.0.0-rc.1..8 and 5.0.0
- `stable-5.0`: empty
- `stable-4.23` / `fast-4.23`: empty
