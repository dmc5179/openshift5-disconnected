# D5: fips-rhel10-readiness.sh on real systems (2026-11-11) [LAB]

Read-only run of `fips-rhel10-readiness.sh` on:

- an RHCOS 9.8 worker and an RHCOS 9.8 control-plane node of the 5.0.1 cluster. That cluster was upgraded from 4.22.22, FIPS, and still runs `rhel-9` (RHCOS 9.8.20261102-0). Run through `oc debug node`.
- the RHEL 9.8 FIPS registry node, with `sudo`.

Full output: `output/`.

| System | FAIL | WARN | PASS | Exit |
|---|---|---|---|---|
| Worker, RHCOS 9.8 | 2 | 4 | 7 | 2 |
| Control plane, RHCOS 9.8 | 2 | 4 | 7 | 2 (145 INFO, mostly RSA 2048 cluster certs) |
| Registry node, RHEL 9.8 FIPS | 0 | 6 | 6 | 1 |

## Findings

1. **SSH host keys on RHCOS 9.8 nodes are mode 0640, group `ssh_keys`** (ecdsa and rsa). The script flags this as FAIL: RHEL 10 OpenSSH requires 0600, and the `ssh_keys` group is removed in RHEL 10.
   - The registry node's keys are 0600 (WARN for the group only).
   - **Open question:** does the stream switch to RHCOS 10 fix these permissions, given that `/etc` persists across the switch? If not, sshd on the switched nodes may refuse the host keys. SSH to nodes would then fail, while `oc debug` would keep working.
   - Verify with the rhel-9 -> rhel-10 stream switch (not run yet) or on a fresh RHCOS 10 node.
2. **The worker and control-plane nodes are otherwise clean for FIPS on RHEL 10:**
   - kernel FIPS on;
   - no custom policy modules;
   - no `fips-mode-setup` or `/etc/system-fips` references;
   - no OpenSSL 1.1-linked binaries;
   - no OpenSSL engines;
   - no legacy SSH algorithm overrides;
   - CRI-O `default_runtime = "crun"` (so the runC blocker F8 does not apply to this upgraded cluster).
3. **WARNs, all low impact:**
   - libgcrypt is not FIPS-validated on RHEL 10 (gnupg2 uses it).
   - `/etc/krb5.conf` references `/etc/pki/tls/certs/ca-bundle.crt`, the OS default.
4. **Registry-node false positive, now fixed in the script:** the HMAC-SHA1 WARN matched AWS CLI v2 `*.rst` example files. The scan now skips docs and examples.
5. **Usage fix:** `oc debug node -- chroot /host bash -s < script` passes no stdin from a non-interactive session; the output was empty. The script header now documents a base64 one-liner that works from scripts.

## Side finding: power-on after 24 h

The cluster was about 25 h old when it was powered on. `70-power.sh` reported "all Ready" from stale node status:
- heartbeats were 16 h old;
- 10 kubelet CSRs were pending;
- all aggregated APIs were down;
- `oc debug` fell back to `registry.redhat.io/rhel9/support-tools` because the image API was down.

After the CSRs were approved, the worker's kubelet serving certificate was briefly untrusted by the API server ("x509: certificate signed by unknown authority" on logs/exec). It cleared within about 10 minutes, without action. The script now waits for fresh heartbeats, no pending CSRs and all APIServices available (commit 8899f4c).
