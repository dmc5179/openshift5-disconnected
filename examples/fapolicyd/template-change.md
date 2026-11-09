# Proposed CloudFormation change: fapolicyd enforcing with trust (B-5)

**Status: APPLIED 2026-11-08** to `cloudformation/disconnected_vpc_plus.yaml` (default `disable`; set `FAPOLICYD_MODE=enforce-with-trust` in cluster.env, passed by `scripts/10-deploy-vpc.sh`). Originally a proposal generated
2026-11-06 against the template at commit 5257abc. Lab evidence: `RESULTS.md` in this directory.

## What it does

- New parameter **`FapolicydMode`**: `enforce-with-trust` | `disable` (**default `disable`**, today's
  behaviour, until `openshift-install create cluster` has been validated under fapolicyd; see below).
  - `disable` = today's behaviour (stop, disable, mask if installed).
  - `enforce-with-trust` = install fapolicyd if missing (the stock RHEL AMIs do not ship it;
    customer golden images do), then:
    1. `/etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules` with
       `allow perm=open uid=0 pattern=ld_so exe=/ : all` (rootful podman/crun; mirror-registry fails
       without it, tested);
    2. `integrity = sha256` (trust then really is hash-based; works in FIPS mode, tested);
    3. one audit rule (`-w /etc/fapolicyd/ -p wa`) so FANOTIFY denial records are written
       (KCS 7052379, https://access.redhat.com/solutions/7052379);
    4. `systemctl enable` + `restart fapolicyd`.
- `fapolicyd_trust` writes `/etc/fapolicyd/trust.d/90-ocp-disconnected` (path, size, SHA-256) for
  `/usr/local/bin/{oc,kubectl,openshift-install-fips,oc-mirror,ccoctl}`, `/usr/local/aws-cli/` and,
  on the registry node, `/tmp/mirror-registry`. It is called right after the AWS CLI install (the
  CLI's own bundled `.so` files are untrusted objects, so even root cannot run it otherwise
  [INFER from the default rule order: rule 2 only covers trusted subjects]) and again after the
  OpenShift CLIs are installed.
- Applied to all three nodes (Squid, bastion, registry), because CloudFormation user data cannot
  share code, the function block is repeated three times.
- Adds `acl` to the registry node's package list: mirror-registry's playbook needs `setfacl`, which
  the RHEL 10.2 AMI does not have (independent of fapolicyd; seen on RHEL 10 only).

## Not covered / to validate at the next rebuild

- The Squid node under enforcing fapolicyd was **not lab-tested** (squid, iptables-services and dnf
  are RPM-trusted, so [INFER] no extra rules are needed).
- `dnf install fapolicyd` on the registry node runs through Squid (RHUI is allowlisted; dnf update
  already uses it).
- Customer images that already ship their own rules: the crun rule and the trust file are additive;
  the `integrity = sha256` edit overrides a customer's `size`/`ima` choice (drop that line if they
  manage fapolicyd.conf themselves).
- **`openshift-install create cluster` from a node with `enforce-with-trust`** is expected to be
  denied for ec2-user: the installer unpacks and executes etcd, kube-apiserver and the CAPI providers
  under `<install-dir>/cluster-api/` (RESULTS.md section 6). This diff does not add a rule for it;
  test before switching an install host to enforcing.
- Ad-hoc tool updates later (new oc-mirror, new installer) need
  `examples/fapolicyd/fapolicyd-trust-tools.sh` (or `fapolicyd_trust`) to run again.
- `FAPOLICYD_MODE` is in `cluster.env` and passed by `scripts/10-deploy-vpc.sh` as `FapolicydMode` (done 2026-11-08).

## Checks done on the proposal

- `cfn-lint` on the patched template: clean.
- The three resulting user-data scripts (`!Sub` variables substituted) pass `bash -n`.

## Diff

```diff
--- a/cloudformation/disconnected_vpc_plus.yaml
+++ b/cloudformation/disconnected_vpc_plus.yaml
@@ -63,6 +63,16 @@
       clients/ocp/<version>/ (that path returns 404); it ships asynchronously under pub/cgw/oc-mirror/.
     Type: String
 
+  FapolicydMode:
+    Type: String
+    Default: disable
+    AllowedValues: [enforce-with-trust, disable]
+    Description: >-
+      fapolicyd on all three nodes (default disable until openshift-install create cluster is
+      validated under fapolicyd, AGENTS.md B-5). enforce-with-trust installs and enforces it with a crun rule
+      (rootful podman, mirror-registry) and a SHA-256 trust file for the tools under /usr/local
+      (AGENTS.md B-5, examples/fapolicyd/). disable stops and masks it.
+
   PullSecretJson:
     Description: >-
       OpenShift pull secret JSON. NoEcho hides it from the console and describe-stacks, but it is still
@@ -516,11 +526,55 @@
             # systemd but left the RHEL 9.5 SELinux policy, which then denies systemd's BPF device
             # filter after a reboot and breaks every container (CF-22).
             dnf update -y
-            # fapolicyd breaks mirror-registry and other tooling; keep it off for now (AGENTS.md B-5).
-            if rpm -q fapolicyd >/dev/null 2>&1; then
-              systemctl disable --now fapolicyd || true
-              systemctl mask fapolicyd || true
-            fi
+            # fapolicyd (AGENTS.md B-5, examples/fapolicyd/RESULTS.md). FapolicydMode:
+            #   enforce-with-trust  install fapolicyd if missing, enable it enforcing, add the crun rule
+            #                       (rootful podman / mirror-registry), integrity sha256, an audit rule so
+            #                       denials are logged, and trust the non-RPM tools under /usr/local by hash
+            #   disable             stop, disable and mask it (the behaviour before B-5)
+            type fail >/dev/null 2>&1 || fail() { echo "FATAL: $*"; exit 1; }
+            fapolicyd_prepare() {
+              case "${FapolicydMode}" in
+              disable)
+                if rpm -q fapolicyd >/dev/null 2>&1; then
+                  systemctl disable --now fapolicyd || true
+                  systemctl mask fapolicyd || true
+                fi ;;
+              enforce-with-trust)
+                rpm -q fapolicyd >/dev/null 2>&1 || dnf install -y fapolicyd || fail "install fapolicyd"
+                # crun re-executes itself from a memfd (exe=/); the default ld_so pattern rule then denies its
+                # library loads and every rootful podman run fails with "OCI permission denied". Must sort
+                # before 30-patterns.rules; exe=/usr/bin/crun does not match (tested).
+                printf '%s\n' '# AGENTS.md B-5: rootful podman (crun memfd re-exec) under fapolicyd' \
+                  'allow perm=open uid=0 pattern=ld_so exe=/ : all' > /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                chmod 644 /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                chgrp fapolicyd /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                sed -i 's/^integrity = .*/integrity = sha256/' /etc/fapolicyd/fapolicyd.conf
+                # FANOTIFY denial records need at least one audit rule (KCS 7052379).
+                echo '-w /etc/fapolicyd/ -p wa -k fapolicyd-config' > /etc/audit/rules.d/50-fapolicyd.rules
+                augenrules --load || true
+                restorecon -R /etc/fapolicyd
+                systemctl unmask fapolicyd 2>/dev/null || true
+                fagenrules --load || fail "fagenrules"
+                systemctl enable fapolicyd
+                systemctl restart fapolicyd || fail "start fapolicyd" ;;
+              *) fail "unknown FapolicydMode ${FapolicydMode}" ;;
+              esac
+            }
+            # Trust is by path, size and SHA-256 (enforced with integrity = sha256): call this again after
+            # installing or replacing anything under /usr/local, or pass extra paths.
+            fapolicyd_trust() {
+              [ "${FapolicydMode}" = enforce-with-trust ] || return 0
+              rm -f /etc/fapolicyd/trust.d/90-ocp-disconnected
+              for p in /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/openshift-install-fips \
+                       /usr/local/bin/oc-mirror /usr/local/bin/ccoctl /usr/local/aws-cli "$@"; do
+                [ -e "$p" ] || continue
+                # exit 9 = nothing new to add (duplicate path); not an error here
+                fapolicyd-cli --file add "$(readlink -f "$p")" --trust-file 90-ocp-disconnected >/dev/null || [ $? = 9 ] \
+                  || fail "fapolicyd trust $p"
+              done
+              fapolicyd-cli --update || fail "fapolicyd-cli --update"
+            }
+            fapolicyd_prepare
             # firewalld is not used here: the interception rules below are managed by iptables-services,
             # and firewalld.service conflicts with iptables.service (CF-7).
             yum install -y unzip vim wget
@@ -534,6 +588,7 @@
             curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
             unzip awscliv2.zip
             ./aws/install
+            fapolicyd_trust
 
             # Disable source / destination check. It cannot be disabled from the launch configuration
             region=${AWS::Region}
@@ -780,11 +835,55 @@
 
             # Full update, not --security (CF-22: mixed-release SELinux policy breaks podman).
             dnf update -y
-            # fapolicyd breaks mirror-registry and other tooling; keep it off for now (AGENTS.md B-5).
-            if rpm -q fapolicyd >/dev/null 2>&1; then
-              systemctl disable --now fapolicyd || true
-              systemctl mask fapolicyd || true
-            fi
+            # fapolicyd (AGENTS.md B-5, examples/fapolicyd/RESULTS.md). FapolicydMode:
+            #   enforce-with-trust  install fapolicyd if missing, enable it enforcing, add the crun rule
+            #                       (rootful podman / mirror-registry), integrity sha256, an audit rule so
+            #                       denials are logged, and trust the non-RPM tools under /usr/local by hash
+            #   disable             stop, disable and mask it (the behaviour before B-5)
+            type fail >/dev/null 2>&1 || fail() { echo "FATAL: $*"; exit 1; }
+            fapolicyd_prepare() {
+              case "${FapolicydMode}" in
+              disable)
+                if rpm -q fapolicyd >/dev/null 2>&1; then
+                  systemctl disable --now fapolicyd || true
+                  systemctl mask fapolicyd || true
+                fi ;;
+              enforce-with-trust)
+                rpm -q fapolicyd >/dev/null 2>&1 || dnf install -y fapolicyd || fail "install fapolicyd"
+                # crun re-executes itself from a memfd (exe=/); the default ld_so pattern rule then denies its
+                # library loads and every rootful podman run fails with "OCI permission denied". Must sort
+                # before 30-patterns.rules; exe=/usr/bin/crun does not match (tested).
+                printf '%s\n' '# AGENTS.md B-5: rootful podman (crun memfd re-exec) under fapolicyd' \
+                  'allow perm=open uid=0 pattern=ld_so exe=/ : all' > /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                chmod 644 /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                chgrp fapolicyd /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                sed -i 's/^integrity = .*/integrity = sha256/' /etc/fapolicyd/fapolicyd.conf
+                # FANOTIFY denial records need at least one audit rule (KCS 7052379).
+                echo '-w /etc/fapolicyd/ -p wa -k fapolicyd-config' > /etc/audit/rules.d/50-fapolicyd.rules
+                augenrules --load || true
+                restorecon -R /etc/fapolicyd
+                systemctl unmask fapolicyd 2>/dev/null || true
+                fagenrules --load || fail "fagenrules"
+                systemctl enable fapolicyd
+                systemctl restart fapolicyd || fail "start fapolicyd" ;;
+              *) fail "unknown FapolicydMode ${FapolicydMode}" ;;
+              esac
+            }
+            # Trust is by path, size and SHA-256 (enforced with integrity = sha256): call this again after
+            # installing or replacing anything under /usr/local, or pass extra paths.
+            fapolicyd_trust() {
+              [ "${FapolicydMode}" = enforce-with-trust ] || return 0
+              rm -f /etc/fapolicyd/trust.d/90-ocp-disconnected
+              for p in /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/openshift-install-fips \
+                       /usr/local/bin/oc-mirror /usr/local/bin/ccoctl /usr/local/aws-cli "$@"; do
+                [ -e "$p" ] || continue
+                # exit 9 = nothing new to add (duplicate path); not an error here
+                fapolicyd-cli --file add "$(readlink -f "$p")" --trust-file 90-ocp-disconnected >/dev/null || [ $? = 9 ] \
+                  || fail "fapolicyd trust $p"
+              done
+              fapolicyd-cli --update || fail "fapolicyd-cli --update"
+            }
+            fapolicyd_prepare
 
             # DNF install loop due to slow uptime for NAT gateway
             MAX_ATTEMPTS=10
@@ -824,6 +923,7 @@
             curl -fsS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" || fail "download AWS CLI"
             unzip -q awscliv2.zip || fail "unzip AWS CLI"
             ./aws/install || fail "install AWS CLI"
+            fapolicyd_trust
             
             for f in openshift-client-linux-amd64-${client_build}-${ocp_ver}.tar.gz openshift-install-rhel9-amd64.tar.gz \
                      oc-mirror.rhel9.tar.gz ccoctl-linux-${client_build}-${ocp_ver}.tar.gz mirror-registry-amd64.tar.gz; do
@@ -841,6 +941,7 @@
             sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/openshift-install-fips /usr/local/bin/oc-mirror /usr/local/bin/ccoctl
             sudo restorecon -v /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/openshift-install-fips /usr/local/bin/oc-mirror /usr/local/bin/ccoctl
             sudo ln -sf /usr/local/bin/openshift-install-fips /usr/local/bin/openshift-install
+            fapolicyd_trust "$PWD/mirror-registry"
 
             # Signal to the registry node that we're done mirroring to S3
             signal SUCCESS "Configuration Complete"
@@ -973,17 +1074,61 @@
 
             # Full update, not --security (CF-22: mixed-release SELinux policy breaks podman).
             dnf update -y
-            # fapolicyd breaks mirror-registry and other tooling; keep it off for now (AGENTS.md B-5).
-            if rpm -q fapolicyd >/dev/null 2>&1; then
-              systemctl disable --now fapolicyd || true
-              systemctl mask fapolicyd || true
-            fi
+            # fapolicyd (AGENTS.md B-5, examples/fapolicyd/RESULTS.md). FapolicydMode:
+            #   enforce-with-trust  install fapolicyd if missing, enable it enforcing, add the crun rule
+            #                       (rootful podman / mirror-registry), integrity sha256, an audit rule so
+            #                       denials are logged, and trust the non-RPM tools under /usr/local by hash
+            #   disable             stop, disable and mask it (the behaviour before B-5)
+            type fail >/dev/null 2>&1 || fail() { echo "FATAL: $*"; exit 1; }
+            fapolicyd_prepare() {
+              case "${FapolicydMode}" in
+              disable)
+                if rpm -q fapolicyd >/dev/null 2>&1; then
+                  systemctl disable --now fapolicyd || true
+                  systemctl mask fapolicyd || true
+                fi ;;
+              enforce-with-trust)
+                rpm -q fapolicyd >/dev/null 2>&1 || dnf install -y fapolicyd || fail "install fapolicyd"
+                # crun re-executes itself from a memfd (exe=/); the default ld_so pattern rule then denies its
+                # library loads and every rootful podman run fails with "OCI permission denied". Must sort
+                # before 30-patterns.rules; exe=/usr/bin/crun does not match (tested).
+                printf '%s\n' '# AGENTS.md B-5: rootful podman (crun memfd re-exec) under fapolicyd' \
+                  'allow perm=open uid=0 pattern=ld_so exe=/ : all' > /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                chmod 644 /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                chgrp fapolicyd /etc/fapolicyd/rules.d/25-ocp-disconnected-crun.rules
+                sed -i 's/^integrity = .*/integrity = sha256/' /etc/fapolicyd/fapolicyd.conf
+                # FANOTIFY denial records need at least one audit rule (KCS 7052379).
+                echo '-w /etc/fapolicyd/ -p wa -k fapolicyd-config' > /etc/audit/rules.d/50-fapolicyd.rules
+                augenrules --load || true
+                restorecon -R /etc/fapolicyd
+                systemctl unmask fapolicyd 2>/dev/null || true
+                fagenrules --load || fail "fagenrules"
+                systemctl enable fapolicyd
+                systemctl restart fapolicyd || fail "start fapolicyd" ;;
+              *) fail "unknown FapolicydMode ${FapolicydMode}" ;;
+              esac
+            }
+            # Trust is by path, size and SHA-256 (enforced with integrity = sha256): call this again after
+            # installing or replacing anything under /usr/local, or pass extra paths.
+            fapolicyd_trust() {
+              [ "${FapolicydMode}" = enforce-with-trust ] || return 0
+              rm -f /etc/fapolicyd/trust.d/90-ocp-disconnected
+              for p in /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/openshift-install-fips \
+                       /usr/local/bin/oc-mirror /usr/local/bin/ccoctl /usr/local/aws-cli "$@"; do
+                [ -e "$p" ] || continue
+                # exit 9 = nothing new to add (duplicate path); not an error here
+                fapolicyd-cli --file add "$(readlink -f "$p")" --trust-file 90-ocp-disconnected >/dev/null || [ $? = 9 ] \
+                  || fail "fapolicyd trust $p"
+              done
+              fapolicyd-cli --update || fail "fapolicyd-cli --update"
+            }
+            fapolicyd_prepare
 
             # DNF install loop due to slow uptime for NAT gateway
             MAX_ATTEMPTS=10
             attempt_num=1
             until [ $attempt_num -gt $MAX_ATTEMPTS ] || \
-                  sudo dnf install -y wget vim podman unzip jq tmux &> /dev/null; do
+                  sudo dnf install -y wget vim podman unzip jq tmux acl &> /dev/null; do
                 
                 echo "Attempt $attempt_num failed. Trying again in 10 seconds..."
                 sleep 10
@@ -993,6 +1138,7 @@
             curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
             unzip -q awscliv2.zip
             ./aws/install
+            fapolicyd_trust
             [ -x /usr/local/bin/aws ] || { echo "FATAL: AWS CLI not installed; cannot signal, stack will time out"; exit 1; }
             [ $attempt_num -le $MAX_ATTEMPTS ] || fail "dnf install of the base packages"
 
@@ -1010,6 +1156,7 @@
             sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/openshift-install-fips /usr/local/bin/oc-mirror /usr/local/bin/ccoctl
             sudo restorecon -v /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/openshift-install-fips /usr/local/bin/oc-mirror /usr/local/bin/ccoctl
             sudo ln -sf /usr/local/bin/openshift-install-fips /usr/local/bin/openshift-install
+            fapolicyd_trust "$PWD/mirror-registry"
 
             #sudo fips-mode-setup --enable
             #Don't install mirror-registry until after FIPS is enabled
```
