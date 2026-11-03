# Runbook: oc-mirror cross-major channel test (cases A, C, D)

Each case is a **mirror-to-disk dry run**. No images are mirrored, but oc-mirror does pull each release *payload* image into its cache to read the component list. Run the cases **one at a time**, because each starts a local registry on port 55000. Logs are kept; working data is deleted after each case.

| Case | Config file | Channels | What it shows |
|---|---|---|---|
| A | `isc-A-cross-major-candidate.yaml` | candidate-4.22 (4.22.20–4.22.21) + candidate-5.0 (5.0.0) | **Bug reproducer**: two channels across the 4→5 boundary |
| C | `isc-C-workaround-single-channel.yaml` | candidate-5.0 only (4.22.20 → 5.0.0, shortestPath) | **Workaround**: one channel spanning the boundary |
| D | `isc-D-control-same-major.yaml` | candidate-4.21 (4.21.0) + candidate-4.22 (4.22.21) | **Control**: two channels within one major |

Facts verified from source for your local binary (oc-mirror 4.22, `release-4.22` branch):
- The buggy `calculate()` in `internal/pkg/release/core-cincinnati.go` is identical in 4.22 and 5.x. A 4.22 binary has no version gate that would refuse 5.0 channels.
- With a `file://` destination, **do not pass `--workspace`**; oc-mirror rejects that combination. The working dir is `<dest>/working-dir`.
- Dry-run output goes to `<dest>/working-dir/dry-run/mapping.txt` and `missing.txt`.
- A cross-channel failure is fatal. It surfaces as `[GetReleaseReferenceImages] error calculating cross channel upgrades: ...`.
- The debug line that shows which channel oc-mirror walks is `Getting updates for version <v> in channel <ch>`. It is printed only after that channel lookup succeeds. When a lookup **fails**, the channel appears in the error text instead (`channel "candidate-4.24": ...`). A blocked path shows up as a WARN, `No upgrade path for <v> in target channel <ch>`, at any log level.
- **Log level:** `debug` is enough. `trace` adds only one line on this code path (`previous channel ...`, not useful), plus a lot of noise. At `debug`, every Cincinnati request URL is logged (`... request updates from https://api.openshift.com/api/upgrades_info/v1/graph?...&channel=<ch>`). That is the clearest evidence of the channel walk.

---

## 0. One-time prep (run once before any case)

```bash
# --- variables used by every step ---
export TEST_SRC=/home/danclark/workspace/openshift5-disconnected/examples/oc-mirror-cross-major-test
export TEST_ROOT=$HOME/ocm-cross-major-test
mkdir -p "$TEST_ROOT/logs"

# --- 0.1 record tool version ---
oc-mirror version 2>&1 | tee "$TEST_ROOT/logs/oc-mirror-version.txt"

# --- 0.2 registry auth must cover quay.io and registry.redhat.io ---
#     oc-mirror reads ${XDG_RUNTIME_DIR}/containers/auth.json first, then ~/.docker/config.json
for f in "${XDG_RUNTIME_DIR}/containers/auth.json" "$HOME/.docker/config.json"; do
  [ -r "$f" ] && echo "$f:" && jq -r '.auths | keys[]' "$f" | grep -E 'quay.io|registry.redhat.io|cloud.openshift.com'
done

# --- 0.3 port 55000 must be free (oc-mirror local registry) ---
ss -ltnp | grep ':55000' && echo "PORT 55000 IN USE - stop it before continuing" || echo "port 55000 free"

# --- 0.4 disk space: allow ~10 GB free under $TEST_ROOT ---
df -h "$TEST_ROOT"

# --- 0.5 snapshot the Cincinnati data the test depends on (it changes over time) ---
for ch in candidate-4.21 candidate-4.22 candidate-4.23 candidate-4.24 candidate-5.0 stable-5.0; do
  curl -s -H 'Accept: application/json' \
    "https://api.openshift.com/api/upgrades_info/v1/graph?channel=${ch}&arch=amd64" \
    > "$TEST_ROOT/logs/cincinnati-${ch}.json"
  printf '%-16s nodes=%s\n' "$ch" "$(jq '.nodes|length' "$TEST_ROOT/logs/cincinnati-${ch}.json")"
done | tee "$TEST_ROOT/logs/cincinnati-summary.txt"
# Confirm the edge oc-mirror *should* use exists: expect 5.0.0 in the output
jq -r '.nodes as $n | .edges[] | select($n[.[0]].version=="4.22.21") | $n[.[1]].version' \
  "$TEST_ROOT/logs/cincinnati-candidate-5.0.json" | tee -a "$TEST_ROOT/logs/cincinnati-summary.txt"

# --- 0.6 copy the configs next to the logs so the run is self-contained ---
cp "$TEST_SRC"/isc-{A,C,D}-*.yaml "$TEST_ROOT/"
```

---

## Case A: reproducer (candidate-4.22 + candidate-5.0)

```bash
CASE=A; ISC="$TEST_ROOT/isc-A-cross-major-candidate.yaml"
# prep
rm -rf "$TEST_ROOT/case-$CASE" && mkdir -p "$TEST_ROOT/case-$CASE"/{out,cache}
# run
oc-mirror --v2 -c "$ISC" \
  --cache-dir "$TEST_ROOT/case-$CASE/cache" \
  --dry-run --log-level debug \
  "file://$TEST_ROOT/case-$CASE/out" 2>&1 | tee "$TEST_ROOT/logs/case-$CASE.log"
echo "exit=${PIPESTATUS[0]}" | tee -a "$TEST_ROOT/logs/case-$CASE.log"
```
Post-run collection and cleanup are the same for every case; see [After each case](#after-each-case-collect-then-clean).

**Bug confirmed if:** the log shows `Getting updates for version 4.22.21 in channel candidate-4.23` (and possibly `candidate-4.24`), and it either ends with `error calculating cross channel upgrades`, or `mapping.txt` contains a `4.23.0-ec` release. There will be **no** use of the candidate-5.0 4.22.21 → 5.0.0 edge.

---

## Case C: workaround (single candidate-5.0 channel)

```bash
CASE=C; ISC="$TEST_ROOT/isc-C-workaround-single-channel.yaml"
rm -rf "$TEST_ROOT/case-$CASE" && mkdir -p "$TEST_ROOT/case-$CASE"/{out,cache}
oc-mirror --v2 -c "$ISC" \
  --cache-dir "$TEST_ROOT/case-$CASE/cache" \
  --dry-run --log-level debug \
  "file://$TEST_ROOT/case-$CASE/out" 2>&1 | tee "$TEST_ROOT/logs/case-$CASE.log"
echo "exit=${PIPESTATUS[0]}" | tee -a "$TEST_ROOT/logs/case-$CASE.log"
```
**Workaround confirmed if:** exit=0, and `mapping.txt` contains the 4.22.20, (4.22.21) and 5.0.0 release images, with no 4.23 EC content.

---

## Case D: control (candidate-4.21 + candidate-4.22)

```bash
CASE=D; ISC="$TEST_ROOT/isc-D-control-same-major.yaml"
rm -rf "$TEST_ROOT/case-$CASE" && mkdir -p "$TEST_ROOT/case-$CASE"/{out,cache}
oc-mirror --v2 -c "$ISC" \
  --cache-dir "$TEST_ROOT/case-$CASE/cache" \
  --dry-run --log-level debug \
  "file://$TEST_ROOT/case-$CASE/out" 2>&1 | tee "$TEST_ROOT/logs/case-$CASE.log"
echo "exit=${PIPESTATUS[0]}" | tee -a "$TEST_ROOT/logs/case-$CASE.log"
```
**Control passes if:** exit=0, the log shows `Getting updates for version 4.21.<z> in channel candidate-4.22`, and `mapping.txt` contains 4.21.0, the path releases and 4.22.21. This proves multi-channel calculation works when `Minor++` lands on a real channel.

---

## After each case: collect, then clean

```bash
# --- collect (keep these) ---
DR="$TEST_ROOT/case-$CASE/out/working-dir/dry-run"
ls -la "$DR" 2>/dev/null | tee "$TEST_ROOT/logs/case-$CASE.dryrun-ls.txt"
cp "$DR/mapping.txt" "$TEST_ROOT/logs/case-$CASE.mapping.txt" 2>/dev/null
cp "$DR/missing.txt" "$TEST_ROOT/logs/case-$CASE.missing.txt" 2>/dev/null
# release payloads oc-mirror decided to include (one line per OCP release)
grep -oE 'ocp-release:[^ ]+|release-images:[^ ]+' "$TEST_ROOT/logs/case-$CASE.mapping.txt" 2>/dev/null | sort -u \
  | tee "$TEST_ROOT/logs/case-$CASE.releases.txt"
# quick view of the channel walk and errors
grep -nE 'request updates from|Getting updates for version|Found update|processing minimum version|cross channel|failed to get upgrade graph|channel "|No upgrade path|error|exit=' \
  "$TEST_ROOT/logs/case-$CASE.log" | tee "$TEST_ROOT/logs/case-$CASE.summary.txt"

# --- clean (removes cached payloads and working dir, keeps logs) ---
du -sh "$TEST_ROOT/case-$CASE" 2>/dev/null
rm -rf "$TEST_ROOT/case-$CASE"
ss -ltnp | grep ':55000' && echo "WARNING: something still listening on 55000" || echo "port 55000 free"
```

## When finished
Send me the path `$TEST_ROOT/logs/` (default `~/ocm-cross-major-test/logs/`). I'll read:
- `case-{A,C,D}.log`
- `.summary.txt`
- `.releases.txt`
- `.mapping.txt` / `.missing.txt`
- the `cincinnati-*.json` snapshot

Then I'll update the Jira draft with actual results.

**Full cleanup** when you're done with everything:
```bash
rm -rf "$TEST_ROOT"   # removes logs too - only after results are captured
```
Also note: if you ever ran oc-mirror without `--cache-dir`, the default cache is `$HOME/.oc-mirror/.cache`. These runs don't touch it.
