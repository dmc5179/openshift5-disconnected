# B-5: disconnected OpenShift 5 tooling with fapolicyd enforcing

Date: 2026-11-05/06 (23:45Z-00:40Z). Throwaway instances in the stack's public subnet, terminated
afterwards. Step logs (ANSI stripped, secrets redacted): `logs/rhel9-steps.log`, `logs/rhel10-steps.log`.

**Result: everything works with fapolicyd enforcing (`permissive = 0`) on RHEL 9.8 FIPS and
RHEL 10.2, given two additions to the default policy [LAB]:**

1. **One rule** for rootful podman (crun): `25-ocp-disconnected-crun.rules`
   `allow perm=open uid=0 pattern=ld_so exe=/ : all`
2. **One trust file** for the non-RPM tools: `/etc/fapolicyd/trust.d/90-ocp-disconnected`, written by
   `fapolicyd-trust-tools.sh` (path, size and SHA-256 of oc, kubectl, openshift-install-fips, oc-mirror,
   ccoctl, the AWS CLI v2 tree, mirror-registry).

Final configuration verified in service mode, with `integrity = sha256` and the STIG
"deny everything" rule present, across a reboot. Zero FANOTIFY denials from the tooling.

**Biggest open item:** `openshift-install create cluster` was not run. In 5.0 it unpacks and executes
etcd, kube-apiserver and the CAPI providers from `<install-dir>/cluster-api/` [CODE], which fapolicyd
will deny for a non-root user [INFER]. See section 6.

## Environment

| | RHEL 9 | RHEL 10 |
|---|---|---|
| Instance | i-079bf12de2c396ed6 (m6i.xlarge, 100 GB gp3, IMDSv2) | i-0f97916cefa1a8e2c (same) |
| AMI | ami-0b77fd0a4e70d9ca6 `RHEL-9.8.0_HVM-20260908-x86_64-0-Hourly2-GP3` | ami-0486ae7fed4ff6c60 `RHEL-10.2.0_HVM-20260908-x86_64-0-Hourly2-GP3` (package mode) |
| After `dnf update` | RHEL 9.8, kernel 5.14.0-687.66.1.el9_8 | RHEL 10.2, kernel 6.12.0-211.74.1.el10_2 |
| FIPS | **on** (`fips-mode-setup --enable` + reboot; fips_enabled=1, policy FIPS) | off (RHEL 10 enables FIPS only at install; the RHEL 10 FIPS image-mode AMI is a different host type, see B-3) |
| fapolicyd | 1.4.5-1.1.el9_8 | 1.4.5-1.2.el10_2 |
| podman / crun / conmon / skopeo | 5.8.2-8 / 1.27-1 / 2.2.1-2 / 1.22.2-9 | 5.8.2-12 / 1.30.1-2 / 2.2.1-2 / 1.22.2-6 |
| SELinux | enforcing, selinux-policy 38.1.75-2.el9_8.1 | enforcing, 42.1.18-4.el10_2.4 |
| mirror-registry | 2.0.12 (mirror.openshift.com `cgw/mirror-registry/latest`), Quay `quay-rhel8:v3.12.21`, `redis-6`, `ubi8/pause:8.10-5` | same |
| Tools | oc/kubectl 5.0.0 (v1.36.2), openshift-install-fips 5.0.0 (f49486a4), ccoctl 5.0.0 (rhel9 builds); oc-mirror CDN 2.0.0 (c4d52fa) and image build 5.0.0 (4b6e461, `X:strictfipsruntime`); AWS CLI 2.39.5 | same |

Default fapolicyd configuration on both (identical): `permissive = 0`, `integrity = none`,
`trust = rpmdb,file`, `watch_fs = ext2,ext3,ext4,tmpfs,xfs,vfat,iso9660,btrfs`, the 11 stock rule files.
Compiled default rules (RHEL 9; RHEL 10 identical apart from the dnf python path):

```
 1. allow perm=any uid=0 : dir=/var/tmp/
 2. allow perm=any uid=0 trust=1 : all
 3. allow perm=open exe=/usr/bin/rpm : all
 4. allow perm=open exe=/usr/bin/python3.9 comm=dnf : all
 5. deny_audit perm=any pattern=ld_so : all
 6. deny_audit perm=any all : ftype=application/x-bad-elf
 7. allow perm=open all : ftype=application/x-sharedlib trust=1
 8. deny_audit perm=open all : ftype=application/x-sharedlib
 9. allow perm=execute all : trust=1
10. allow perm=open all : ftype=%languages trust=1
11. deny_audit perm=any all : ftype=%languages
12. allow perm=any all : ftype=text/x-shellscript
13. deny_audit perm=execute all : all
14. allow perm=open all : all
```

Method: fapolicyd was enabled **before** the tools were downloaded (the customer case: a golden image
that enforces from first boot). Baseline and fixes were run with the daemon in the foreground,
`fapolicyd --debug-deny` (RHEL 9 Security hardening, 13.6), and a per-step count of `dec=deny` lines;
the final configuration was then run as the normal service. [DOC] RHEL 9:
https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html-single/security_hardening/index#assembly_blocking-and-allowing-applications-using-fapolicyd_security-hardening ;
RHEL 10: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/security_hardening/index#introduction-to-fapolicyd

## 1. Baseline denials (default rules, enforcing) [LAB]

Identical on RHEL 9 FIPS and RHEL 10 (only the libsystemd version differs).

**Non-RPM binaries run as ec2-user: all denied by rule 13** (`deny_audit perm=execute all : all`):

```
rule=13 dec=deny_audit perm=execute auid=1000 pid=2790 exe=/usr/bin/bash : path=/usr/local/bin/kubectl ftype=application/x-executable trust=0
rule=13 dec=deny_audit perm=execute auid=1000 pid=2816 exe=/usr/bin/bash : path=/home/ec2-user/dl/x/oc ftype=application/x-executable trust=0
rule=13 dec=deny_audit perm=execute auid=1000 pid=2842 exe=/usr/bin/bash : path=/usr/local/bin/openshift-install-fips ftype=application/x-executable trust=0
rule=13 dec=deny_audit perm=execute auid=1000 pid=2871 exe=/usr/bin/bash : path=/usr/local/bin/ccoctl ftype=application/x-executable trust=0
rule=13 dec=deny_audit perm=execute auid=1000 pid=2903 exe=/usr/bin/bash : path=/usr/local/bin/oc-mirror ftype=application/x-executable trust=0
rule=13 dec=deny_audit perm=execute auid=1000 pid=2975 exe=/usr/bin/bash : path=/usr/local/aws-cli/v2/dist/aws ftype=application/x-executable trust=0
```

User-visible: `bash: /usr/local/bin/oc: Operation not permitted` (exit 126). The same for oc,
`/usr/local/bin/aws`, and binaries in the home directory.

**AWS CLI installer reports success although its self-check was denied:**
`sudo ./aws/install` prints `[PYI-2937:ERROR] LOADER: failed to restart process: Operation not permitted`
and then `You can now run: /usr/local/bin/aws --version` with exit 0
(`rule=13 ... exe=/home/ec2-user/dl/aws/dist/aws : path=/home/ec2-user/dl/aws/dist/aws`). Do not trust
its exit code on fapolicyd hosts.

**Rootful podman: every `sudo podman run` fails** (rule 5, the `ld_so` pattern):

```
/usr/bin/crun: error while loading shared libraries: libsystemd.so.0: cannot open shared object file: Operation not permitted
Error: crun: ... OCI permission denied
rule=5 dec=deny_audit perm=open auid=1000 pid=3344 exe=/ : path=/usr/lib64/libsystemd.so.0.35.0 ftype=application/x-sharedlib trust=1
rule=5 dec=deny_audit perm=open auid=1000 pid=3344 exe=/ : path=/etc/ld.so.cache ftype=application/octet-stream trust=0
```

`exe=/`: crun re-executes itself from a sealed memfd copy (CVE-2019-5736 protection), so fapolicyd
cannot resolve the executable and sees the dynamic loader mapping libraries for a binary that is not
on disk, which is what the `ld_so` pattern denies [INFER from the `exe=/` subject and the rule hit].
Affects ubi9 and ubi10 images alike, and therefore **mirror-registry** (all its units are rootful
podman). mirror-registry install with only the trust file and no crun rule (RHEL 10 control run):
`level=error msg="Removing container ... from runtime after creation failed"`,
`An error occurred: exit status 126`, same rule=5 denials.

**Not affected (0 denials):** rootless podman run (ubi9-minimal); skopeo inspect and copy;
`podman pull`; anything that ran in a container once crun was allowed (in-container execution from the
overlay mount is not checked; overlay is not in `watch_fs`) [LAB, explanation INFER].

**Root bypass in the default rules:** rule 2 (`allow perm=any uid=0 trust=1 : all`, from
`21-updaters.rules`) lets any root process whose own executable is trusted (sudo, bash, cloud-init)
open or execute anything. `sudo ./mirror-registry --version` on the untrusted binary worked, and with
`integrity = sha256` `sudo oc-mirror` on a stale (re-hashed) binary still ran while ec2-user was denied
[LAB]. So user data running as root gets further than an interactive user, but the untrusted program's
own children and library loads are still checked (that is why crun fails even under sudo).

## 2. Fixes tried [LAB]

| # | Fix | RHEL 9 FIPS | RHEL 10 |
|---|---|---|---|
| A | Trust file via `fapolicyd-cli --file add <path> --trust-file 90-ocp-disconnected` + `fapolicyd-cli --update` for the CLIs, `/usr/local/aws-cli/` (7,576 files) and `mirror-registry` | All CLIs run as ec2-user, 0 denials | same |
| B | crun rule `allow perm=open uid=0 pattern=ld_so exe=/ : all` in `rules.d/25-*.rules` (before 30-patterns) | rootful podman works | works |
| C | Same with `: trust=1` object | **fails**: `/etc/ld.so.cache` (trust=0) and the container's `oci-log` (trust=0) still denied: `crun: open log file .../userdata/oci-log: Operation not permitted` | not run |
| D | `allow perm=open uid=0 pattern=ld_so exe=/usr/bin/crun : all` (the runc form from the RHEL 10 doc) | **fails**, same rule=5 denials: the subject is `exe=/`, not `/usr/bin/crun` | not run |
| - | Installing the binaries into RPM-trusted paths without an RPM | not an option: trust comes from the rpm database, not the path [DOC: 13.3 "The fapolicyd framework trusts files contained in the RPM database"]. Only a real RPM (or a bootc image layer, which is still an RPM database question) would make them RPM-trusted. Not tested. |

Red Hat documents the equivalent workaround **for runc only** [DOC RHEL 10 Security hardening 10.6,
"Running fapolicyd on a system with containers":
`allow perm=any pattern=ld_so exe=/usr/bin/runc : all` / `allow perm=any uid=0 pattern=ld_so exe=/runc : trust=1`].
RHEL 9/10 podman uses crun and runc is not installed, so that rule does nothing here. B is narrower
than the doc's rule (open only, root only) [LAB]. **Gap: no Red Hat doc covers crun.**

Trust file vs rules: Red Hat recommends trust files over rules for performance [DOC RHEL 9 13.3 note:
"Marking files as trusted using fapolicyd.trust or trust.d/ is better than writing custom fapolicyd rules
due to performance reasons"]. A directory rule (`allow perm=execute ... : dir=/usr/local/bin/`) would
avoid re-trusting on upgrades but would trust anything dropped there, so it was not used.

## 3. Tool-by-tool result with A + B (enforcing) [LAB]

| Tool / step | RHEL 9.8 FIPS | RHEL 10.2 |
|---|---|---|
| `oc version --client`, `kubectl version --client` (5.0.0 / v1.36.2) | PASS | PASS |
| `openshift-install-fips version` (also via the `openshift-install` symlink) | PASS | PASS |
| `oc adm release extract --credentials-requests --cloud=aws` (8 CRs) + `ccoctl aws create-all --dry-run` (keys, IdP, 6 role files) | PASS | PASS |
| `openshift-install-fips create manifests` (platform none, SNO, `fips: true` on RHEL 9 / `false` on RHEL 10) | PASS (`99-master-fips`, `99-worker-fips` MachineConfigs rendered) | PASS |
| oc-mirror CDN 2.0.0 `version`, m2m of ubi9 + ubi10-minimal into the local Quay | PASS (2/2, 37 s) | PASS (2/2, 22 s) |
| oc-mirror image build 5.0.0 (`oc image extract ... /usr/bin/oc-mirror.rhel9`), same m2m | PASS (50 s, ITMS written; loads `/lib64/libcrypto.so.3` + `ossl-modules/fips.so`) | PASS (19 s) |
| AWS CLI v2 `aws --version` (PyInstaller, bundled Python 3.14 `.so` files) | PASS | PASS |
| mirror-registry 2.0.12 install (`--quayRoot /opt/quay-root ...`, as root) | PASS, 0 denials, 3 min 12 s, health 200 | PASS, 0 denials, health 200 (after the `acl` fix and a clean retry, see section 6) |
| `systemctl restart quay-app` | PASS | PASS |
| Reboot (service mode, final config) | Quay health 200 at 74-75 s after boot (two reboots); FANOTIFY records during boot: 0 | 200 at 70 s; FANOTIFY during boot: 0 |
| rootful podman pull + run from the mirror, rootless run, skopeo inspect against the mirror | PASS | PASS |

The reboot restarts seen (`NRestarts=1` on quay-redis/quay-app, `no pod with name or ID quay-pod found`,
exit 125) are the known mirror-registry unit race N-9 / PROJQUAY-14321 (the test hosts did not have the
template's drop-in), not fapolicyd.

## 4. Recommended configuration

Files in this directory:

- `25-ocp-disconnected-crun.rules` -> `/etc/fapolicyd/rules.d/` (mode 644, group fapolicyd), then
  `fagenrules --load`. Must sort before `30-patterns.rules`.
- `fapolicyd-trust-tools.sh` (run as root): rebuilds `/etc/fapolicyd/trust.d/90-ocp-disconnected` from
  the tool locations and runs `fapolicyd-cli --update`. `--check` lists UNTRUSTED / STALE files.
  `MIRROR_REGISTRY_DIR=<dir>` adds `<dir>/mirror-registry`; extra paths as arguments.
- Optional hardening that was tested with it: `integrity = sha256` in `fapolicyd.conf`; STIG
  `99-deny-everything.rules` (`deny perm=any all : all`, KCS 7003854,
  https://access.redhat.com/solutions/7003854; it follows `95-allow-open.rules`, so behaviour does not
  change); an audit rule so denials are recorded (section 5).
- CloudFormation: `template-change.md` (proposal, not applied).

Order on a new host: install fapolicyd rules first, install the tools, run the trust script, then
install mirror-registry.

## 5. Maintenance and troubleshooting

- **Upgrades** [LAB]: with the default `integrity = none` a trust.d entry is matched by **path only**:
  replacing `/usr/local/bin/oc-mirror` (CDN 2.0.0 -> image 5.0.0) kept working with no re-trust, and
  `--check` reported it STALE. With `integrity = sha256` the replaced binary was denied for ec2-user
  (`rule=14 ... path=/usr/local/bin/oc-mirror ... trust=0`) until `fapolicyd-trust-tools.sh` ran again.
  Rule: **re-run the trust script after every tool upgrade** (oc-mirror is async and updates often;
  the installer and CLIs change per z-stream). [DOC 13.3 note: "Changing the content of a trusted file
  ... changes their checksum ... refresh ... by using the fapolicyd-cli --file update command"].
- **Path, not hash, identifies an entry:** the same `oc` binary in `~/dl/x/` stayed denied while
  `/usr/local/bin/oc` was trusted. Run tools from the trusted location.
- **Duplicates:** `fapolicyd-cli --file add` exits 9 ("After removing duplicates, there is nothing to add")
  when a path is already listed, e.g. the `openshift-install -> openshift-install-fips` symlink. The
  script de-duplicates and tolerates 9. Symlinks are skipped by fapolicyd-cli (it suggests the target).
- **FIPS** [LAB]: on the FIPS RHEL 9 host the trust file is SHA-256 (fapolicyd 1.4.5 always writes
  path, size, sha256) and `integrity = sha256` worked, so there is no MD5/SHA-1 dependency.
  `rpm_sha256_only = 0` (default) was left as is.
- **Locations:** `/usr/local/bin`, `/usr/local/aws-cli`, `/opt/mr` and the home directory are all on
  the root xfs and watched; nothing location-specific was needed. On image-mode RHEL 10
  (`/usr/local -> /var/usrlocal`, B-3) the same files are on `/var`; not tested here [INFER: same
  behaviour, xfs is watched].
- **Container storage** needs nothing: `/var/lib/containers` and `~/.local/share/containers` content is
  executed through overlay mounts, which are not in `watch_fs` [LAB 0 denials; INFER for the reason].
- **Seeing denials:** the FANOTIFY audit record only appears when at least one audit rule is loaded
  [DOC KCS 7052379, https://access.redhat.com/solutions/7052379]. Even then, on RHEL 9.8 (audit 3.1.5)
  `ausearch -m fanotify` / `-m FANOTIFY` returned nothing while `grep FANOTIFY /var/log/audit/audit.log`
  showed the records, and the record has no path (`resp=2 fan_type=1 fan_info=E subj_trust=2 obj_trust=0`)
  [LAB]. For paths use `systemctl stop fapolicyd; fapolicyd --debug-deny`.
- **After a foreground debug run** the service failed to start:
  `fapolicyd.service: Failed to set up special execution directory in /run: Permission denied`
  (`status=233/RUNTIME_DIRECTORY`). `rm -rf /run/fapolicyd` and start again fixed it [LAB].

## 6. Still failing / open

- **mirror-registry on RHEL 10 needs `acl`** (`setfacl`): `Failed to find required executable "setfacl"`.
  Not fapolicyd; the RHEL 10.2 AMI lacks it. Added to the template proposal.
- **mirror-registry retry after a failed install fails with Redis `WRONGPASS`**: the podman secret
  `redis_pass` from the first attempt survives (`mirror-registry uninstall` also failed, exit 126/1, and a
  manual cleanup of units, pod and `/opt/quay-root` is not enough), while `config.yaml` gets a new
  password. `podman secret rm redis_pass` before the retry fixed it [LAB]. Relevant to fapolicyd
  rollouts because the first failure is typically the missing crun rule. Candidate note for
  PROJQUAY-14321 or a new mirror-registry issue.
- The crun rule matches `exe=/` for root, i.e. any root process whose executable cannot be resolved
  (memfd). It is the narrowest working form found; ask the RHEL fapolicyd / container-tools team for a
  supported crun rule (the documented one covers runc only).
- **`openshift-install create cluster` (IPI) is expected to FAIL for a non-root user and was not run.**
  [CODE] release-5.0 `pkg/clusterapi/localcontrolplane.go:70-93` and `providers.go:83-171`: the installer
  unpacks embedded `etcd`, `kube-apiserver`, `cluster-api` and the infrastructure provider binaries into
  `<install-dir>/cluster-api/` and executes them (local control plane). They are new, untrusted files
  in a per-install directory, so for ec2-user rule 13 denies them exactly like `~/dl/x/oc` above
  [INFER from the LAB baseline]; a trust.d entry cannot be made before they exist. Options, both
  **untested**: (a) run `openshift-install` as root (rule 2 lets a trusted root subject execute anything;
  the installer itself is trusted through the trust file); (b) a rule such as
  `allow perm=execute exe=/usr/local/bin/openshift-install-fips : ftype=application/x-executable` in
  `rules.d/` (lets only the trusted installer start the binaries it unpacks; the unpacked binaries are
  Go executables, and whether they need further allows (e.g. if dynamically linked) must be checked).
  Also check the `openshift-install` symlink: fapolicyd resolves it to `openshift-install-fips`. This is
  the most important follow-up: run a real `create cluster` from a fapolicyd-enforcing host.
- Not tested: the Squid node under fapolicyd; image-mode RHEL 10 FIPS; a customer STIG image with a
  different rule set (only the KCS 7003854 STIG addition was tested); the agent ISO path
  (`openshift-install agent create image` runs `nmstatectl` and `oc` [INFER: RPM / trusted, and the
  agent path does not start the local control plane]).
- Untested assumption in the template proposal: running the AWS CLI as **root** before it is trusted
  fails (its process is an untrusted subject loading untrusted `.so` files, rules 8/13) [INFER]; the
  proposal therefore trusts it immediately after `./aws/install`.

## Reproduce

Scratch test harness (not kept): `fapolicyd --debug-deny` in the foreground plus a `step` wrapper that
counts new `dec=deny` lines per command. Final configuration as a service:

```
dnf install -y fapolicyd podman skopeo acl
install -m 644 -g fapolicyd 25-ocp-disconnected-crun.rules /etc/fapolicyd/rules.d/
sed -i 's/^integrity = .*/integrity = sha256/' /etc/fapolicyd/fapolicyd.conf
echo '-w /etc/fapolicyd/ -p wa -k fapolicyd-config' > /etc/audit/rules.d/50-fapolicyd.rules; augenrules --load
fagenrules --load; systemctl enable --now fapolicyd
# install the tools under /usr/local, extract mirror-registry to /opt/mr, then:
MIRROR_REGISTRY_DIR=/opt/mr ./fapolicyd-trust-tools.sh
/opt/mr/mirror-registry install --quayRoot /opt/quay-root --quayStorage /opt/quay-root/data --sqliteStorage /opt/quay-root/sqlite
```
