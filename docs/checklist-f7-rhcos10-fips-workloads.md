# Workload inventory checklist: moving to RHCOS 10 in FIPS mode (OpenShift 5.0)

Status: DRAFT, 2026-11-08. Tracker item F7. For clusters that will run RHCOS 10 nodes with `fips: true`: new 5.0
installs (RHCOS 10.2 is the default), and clusters upgraded from 4.22 that plan to switch from the `rhel-9` stream
to `rhel-10` (RHCOS 9 is removed in OpenShift 5.3).

**Labels**
- **[LAB]** seen on our OpenShift 5.0.0 FIPS clusters (AWS, RHCOS 10.2.20261027-0) or RHEL 10.2 FIPS hosts.
- **[DOC]** Red Hat documentation, cited with a URL.
- **[INFER]** our conclusion, not tested. Check it before relying on it.

## How to use this checklist

Most workloads run in containers that bring their own libraries (a UBI 8 or UBI 9 image keeps its own OpenSSL).
What changes under them is the node: the kernel, the host crypto policy, the RHEL 10 FIPS module boundary and what
the container runtime exposes. Items therefore fall into three groups:

| Group | Affected by the RHEL 10 changes |
|---|---|
| Node-level software: MachineConfigs, scripts run with `chroot /host`, privileged DaemonSets, layered RHCOS images, node agents (scanners, EDR, backup) | Directly |
| Containers built on **UBI 10** / RHEL 10 | Directly (same libraries as the host) |
| Containers built on UBI 8 / UBI 9 | Mostly not, except where they read host state (`/etc/system-fips`, crypto policy files) or talk TLS to the platform. RHEL 7 images are **unsupported** on RHEL 10 hosts (item 0) |

For every item: **what breaks**, **how to detect it**, **what to do**. Run the detection commands on a 4.22 or
`rhel-9` cluster before you switch, and again on a test pool afterwards.

A safe way to test: move one worker into a custom MachineConfigPool and switch only that pool to `rhel-10`
(see item 8; the procedure was used in our lab). Mixed RHCOS 9 / 10 clusters are not supported as an end state
(5.0 release notes 1.3.12), so keep the test short.

## Item 0: base images and support

**What breaks.** Red Hat's container compatibility matrix lists **RHEL/UBI 7 images as unsupported on a RHEL 10
host**. RHEL/UBI 8 and 9 images are supported as "workload specific" (unprivileged only, no kernel-specific
interfaces). Privileged containers are supported only when the image and host major versions match.
[DOC] https://access.redhat.com/support/policy/rhel-container-compatibility

Note: the `redhat-operator-index:v5.0` catalog still carries an operator (3scale, 2.13 and MAS channels) whose
image set includes rhel7 images [LAB, mirror-to-disk listing]. Check every operator you mirror.

**Detect.**

```bash
# Base OS of each running image (reads /etc/os-release inside a sample pod per image; needs exec rights)
oc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.containers[0].image}{"\n"}{end}' \
  | sort -u -k3,3 > images.txt
while read -r ns pod img; do
  printf '%s\t%s\t' "$img" "$ns/$pod"
  oc exec -n "$ns" "$pod" -- sh -c '. /etc/os-release 2>/dev/null; echo "${ID}-${VERSION_ID}"' 2>/dev/null || echo "n/a"
done < images.txt | grep -E 'rhel-7|centos-7|n/a'
# Images in the mirror from the oc-mirror dry run
grep -iE 'rhel7|ubi7' <workspace>/working-dir/dry-run/mapping.txt
# Privileged pods (need matched major versions on RHEL 10 hosts)
oc get pods -A -o json | jq -r '.items[] | select(any(.spec.containers[]; .securityContext.privileged==true)) | "\(.metadata.namespace)/\(.metadata.name)"'
```

**Do.** Rebuild RHEL 7 based images on UBI 9 or UBI 10. For privileged node agents, ask the vendor for a RHEL 10 /
RHCOS 10 build. Keep the `rhel-9` stream until they are ready (supported until 5.3).

## Item 1: SHA-1 signatures

**What breaks.** On RHEL 10 the `SHA1` subpolicy is gone (`update-crypto-policies --set DEFAULT:SHA1` no longer
exists), even LEGACY no longer allows SHA-1 signatures in TLS, and libraries other than OpenSSL may reject SHA-1
signatures in every context. FIPS mode never allowed SHA-1 signatures, on RHEL 9 or 10. [DOC]
https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/considerations_in_adopting_rhel_10/index#changes-to-cryptographic-components

So on a FIPS cluster nothing changes for peers that already work on RHCOS 9 FIPS. The risk is for **node-level
workarounds** that relied on `DEFAULT:SHA1` or LEGACY on RHCOS 9 (custom crypto-policy MachineConfigs), and for
UBI 10 workloads. [INFER]

**Detect.**

```bash
# Certificates in TLS secrets signed with SHA-1 (also look at CA bundles in ConfigMaps)
oc get secrets -A --field-selector type=kubernetes.io/tls -o json \
| jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) \(.data["tls.crt"])"' \
| while read -r name crt; do
    alg=$(echo "$crt" | base64 -d 2>/dev/null | openssl x509 -noout -text 2>/dev/null | awk '/Signature Algorithm/{print $3; exit}')
    case "$alg" in *sha1*|*SHA1*) echo "SHA-1: $name $alg" ;; esac
  done
# Route certificates set inline
oc get routes -A -o json | jq -r '.items[] | select(.spec.tls.certificate) | "\(.metadata.namespace)/\(.metadata.name)"'
# External endpoints your workloads call: check the peer certificate chain
openssl s_client -connect <host>:443 -servername <host> -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep 'Signature Algorithm' | head -1
# Custom crypto-policy MachineConfigs that may set SHA1 or LEGACY
oc get mc -o json | jq -r '.items[] | select(any(.spec.config.storage.files[]?; .path|test("crypto-policies"))) | .metadata.name'
```

**Do.** Reissue SHA-1-signed certificates and CAs with SHA-256 or better. Remove `SHA1` / LEGACY crypto-policy
MachineConfigs before switching pools to `rhel-10`; there is no RHEL 10 equivalent.

## Item 2: RSA PKCS#1 v1.5 encryption in GnuTLS, and TLS RSA key exchange

**What breaks.** RHEL 10 sets `allow-rsa-pkcs1-encrypt = false` for GnuTLS in DEFAULT, FUTURE **and FIPS**, so
GnuTLS refuses RSA PKCS#1 v1.5 encryption and decryption. TLS cipher suites with RSA key exchange (`TLS_RSA_*`, no
forward secrecy) are rejected in DEFAULT and stay outside the FIPS policy. [DOC]
https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/considerations_in_adopting_rhel_10/index#changes-to-cryptographic-components

Who is hit: node-level or UBI 10 software linked against GnuTLS (for example tools that use `gnutls-cli`, some
LDAP/VPN/SMTP clients) that talks to legacy peers using RSA key transport or decrypts PKCS#1 v1.5 data. [INFER]

**Detect.**

```bash
# Does a peer only offer RSA key exchange? (If this succeeds and an ECDHE test fails, the peer is legacy-only.)
openssl s_client -connect <host>:<port> -tls1_2 -cipher 'AES256-SHA:AES128-GCM-SHA256' </dev/null 2>&1 | grep -E 'Cipher is|handshake failure'
openssl s_client -connect <host>:<port> -tls1_2 -cipher 'ECDHE' </dev/null 2>&1 | grep -E 'Cipher is|handshake failure'
# Which images ship GnuTLS (run inside an image or on an extracted rootfs)
rpm -q gnutls 2>/dev/null; rpm -q --whatrequires gnutls 2>/dev/null
```

**Do.** Upgrade legacy peers to ECDHE cipher suites. Replace PKCS#1 v1.5 encryption with RSA-OAEP in your own code.

## Item 3: OpenSSL 1.1, OpenSSL engines and PKCS#11

**What breaks.** RHEL 10 removes `compat-openssl11` (the OpenSSL 1.1 compatibility library) and `openssl-pkcs11`
(the `engine_pkcs11` OpenSSL engine). `pkcs11-provider` replaces the engine; in FIPS mode it needs
`pkcs11-module-assume-fips = true`. Apache `httpd` drops OpenSSL ENGINE support (`SSLCryptoDevice`). [DOC]
https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/considerations_in_adopting_rhel_10/index#changes-to-cryptographic-components
(and section 14 for httpd).

Who is hit: binaries run on the node (or in UBI 10 images) that were built against OpenSSL 1.1; HSM integrations
that load an OpenSSL engine on the node. UBI 8 images keep their own OpenSSL 1.1.1 and RHEL 8 FIPS module, and run
on RHCOS 10 as a "workload specific" configuration (item 0). [INFER]

Note: the OpenShift Update Service 5.0.3 operands are RHEL 8.10 / OpenSSL 1.1.1k and worked on RHCOS 10.2 FIPS
nodes, but they are the weakest FIPS story of the operators we checked (the operator is Go 1.21 without
`strictfipsruntime`, the Rust operand also contains `ring`). [LAB]

**Detect.**

```bash
# Node-level binaries linked to libssl.so.1.1 / libcrypto.so.1.1 (run on a node through oc debug)
oc debug node/<node> -- chroot /host sh -c 'for f in /usr/local/bin/* /opt/*/bin/*; do [ -f "$f" ] || continue; ldd "$f" 2>/dev/null | grep -q "so.1.1" && echo "$f"; done'
# Inside an image: OpenSSL major version and engine use
oc exec -n <ns> <pod> -- sh -c 'openssl version 2>/dev/null; ls /usr/lib64/engines-* 2>/dev/null; grep -rl "engine" /etc/pki/tls/openssl.cnf 2>/dev/null'
# MachineConfigs or DaemonSets that install HSM / PKCS#11 bits on the node
oc get mc -o json | jq -r '.items[] | select(any(.spec.config.storage.files[]?; .path|test("pkcs11|engines|openssl.cnf"))) | .metadata.name'
```

**Do.** Rebuild against OpenSSL 3. Move HSM integrations from engines to `pkcs11-provider` and set
`pkcs11-module-assume-fips = true` in FIPS mode. Ask third-party agent vendors for RHEL 10 builds.

## Item 4: libgcrypt is not FIPS-validated on RHEL 10 (GnuPG)

**What breaks.** On RHEL 10, libgcrypt is outside the validated set; the RHEL 10 security hardening guide says the
core cryptographic libraries follow the system-wide policies "except for libgcrypt", and gcrypt-based packages such
as `xmlsec1-gcrypt` are removed. GnuPG (built on libgcrypt) is therefore not a FIPS-compliant way to sign or verify.
On RHEL 9, libgcrypt was validated. [DOC]
https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/security_hardening/index#list-of-rhel-applications-using-cryptography-that-is-not-compliant-with-fips-140-3
(also lists other non-compliant applications, for example curl NTLM, Samba RC4/DES, Unbound SHA-1 DNSSEC, zip
encryption.)

Who is hit: anything in your FIPS boundary that signs or verifies with `gpg` (artifact signing, backup encryption,
Git commit verification) on RHEL 10 nodes or UBI 10 images. [INFER]

**Detect.**

```bash
oc exec -n <ns> <pod> -- sh -c 'command -v gpg gpg2; rpm -q libgcrypt xmlsec1-gcrypt 2>/dev/null'
grep -rlE '\bgpg2? ' <your pipeline / scripts repo>
```

**Do.** Move signing in the FIPS boundary to OpenSSL-based tools (or sigstore/cosign with a FIPS build). Treat GnuPG
on RHEL 10 as non-compliant crypto in your documentation.

## Item 5: `/etc/system-fips`, `fips-mode-setup` and FIPS indicators

**What breaks.**
- RHEL 10 removes `/etc/system-fips` and `fips-mode-setup`. FIPS is set only at installation (`fips=1`); the check is
  `/proc/sys/crypto/fips_enabled`. [DOC]
  https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/considerations_in_adopting_rhel_10/index#changes-to-cryptographic-components ;
  https://access.redhat.com/solutions/7056059
- The RHEL 10.0 OpenSSL FIPS indicators changed and "might return an error message 'unsupported'" after the
  upstream API is adopted. [DOC]
  https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/security_hardening/index#rhel_10_0_openssl_fips_indicators
- Compliance scripts, scanners and day-2 checks that test `/etc/system-fips` report "not FIPS" on RHCOS 10 nodes even
  though the node is in FIPS mode. [INFER] Example: the OpenShift 5.0 docs (ROSA with HCP FIPS procedure,
  `modules/creating-cluster-with-fips-encryption-cli.adoc`) still verify FIPS with `cat /etc/system-fips`. [DOC,
  openshift-docs `enterprise-5.0`]
- [INFER, not verified] Container engines on RHEL 9 pass `/etc/system-fips` into containers when the host has it;
  on an RHCOS 10 host there is no such file to pass, so a UBI 8/9 application that checks `/etc/system-fips` instead
  of `/proc/sys/crypto/fips_enabled` may decide it is not in FIPS mode. On our RHCOS 10.2 FIPS cluster, the mirrored
  Red Hat operators (cert-manager, Lightspeed, OSUS) logged no FIPS errors and loaded the FIPS provider. [LAB]

**Detect.**

```bash
# On a node: what a correct check returns
oc debug node/<node> -- chroot /host sh -c 'cat /proc/sys/crypto/fips_enabled; update-crypto-policies --show; ls -l /etc/system-fips 2>&1'
# Cluster-level check (what the Compliance Operator rule uses): every rendered pool config has fips: true
oc get mc -o json | jq '[.items[] | select(.metadata.name|test("^rendered-(master|worker)-")) | .spec.fips] | all'
# Your code, scripts, Ansible, scanner policies
grep -rnE 'system-fips|fips-mode-setup' <repos>
# Inside an image
oc exec -n <ns> <pod> -- sh -c 'cat /proc/sys/crypto/fips_enabled; ls -l /etc/system-fips 2>&1'
```

**Do.** Check `/proc/sys/crypto/fips_enabled` (node) or the rendered MachineConfig `spec.fips` (cluster). Remove
`fips-mode-setup` from node automation; RHCOS already sets FIPS at install from `install-config.yaml`. If you read
OpenSSL FIPS indicators, handle "unsupported".

## Item 6: HMAC-SHA-1 deprecated in FIPS mode

**What breaks.** Nothing yet: HMAC-SHA-1 is deprecated in RHEL 10 FIPS mode, not removed. It is a future risk for
TOTP and legacy HMAC integrations. [DOC, RHEL 10.0 release notes, per findings §3c]
https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/10.0_release_notes/index

**Detect.** Search your code and integrations for `HmacSHA1`, `hmac.new(..., sha1)`, `HMAC-SHA1`, TOTP defaults
(`algorithm=SHA1` in otpauth URIs).

**Do.** Plan a move to HMAC-SHA-256.

## Item 7: TLS key exchange in FIPS mode: no X25519, no post-quantum, silent P-256 fallback

**What breaks.** OpenShift 5.0 enables the hybrid post-quantum group X25519MLKEM768 by default in its TLS profiles.
The release notes say components in FIPS mode ignore it. [DOC 5.0 release notes 1.3.16]
https://docs.redhat.com/en/documentation/openshift_container_platform/5.0/html-single/release_notes/index

What we measured on a FIPS 5.0.0 cluster (default Intermediate profile) [LAB]:

| Client offers | Result on the API (:6443), ingress (:443) and 38 other platform TLS endpoints (kubelet, etcd client/peer, OAuth, console, registry, monitoring, operator webhooks) |
|---|---|
| `X25519MLKEM768` only | Handshake failure |
| `X25519` only | **Handshake failure** (not mentioned in the docs) |
| `SecP256r1MLKEM768` only | Handshake failure |
| `X25519MLKEM768:X25519:secp256r1:secp384r1` (typical modern client) | **Silently negotiates ECDH P-256**, no warning, condition or metric |
| `secp256r1` or `secp384r1` | Works |

- A FIPS 5.0 cluster has **no post-quantum key exchange** on any endpoint we tested.
- RHEL 10.2 FIPS clients can negotiate the NIST hybrid `SecP256r1MLKEM768` with each other (the ML-KEM part comes
  from the OpenSSL default provider, not the FIPS provider), but OpenShift's profiles do not offer it. [LAB]
- `spec.tlsSecurityProfile.custom.groups` is in the docs, but a 5.0.0 Default cluster rejects it as an unknown field
  and drops it; GitOps tools may not notice. [LAB]

**Detect.**

```bash
# What your client actually negotiates against the API
openssl s_client -connect api.<cluster>.<domain>:6443 -tls1_3 </dev/null 2>/dev/null | grep -E 'Negotiated TLS1.3 group|Peer Temp Key|Server Temp Key'
# Clients that pin X25519 only: look for curve/group settings in client configs
grep -rnE 'X25519|curves|groups|CurvePreferences|ecdhCurve' <client config / code>
# Confirm custom groups are not silently dropped
oc patch apiserver cluster --type merge --dry-run=server -p '{"spec":{"tlsSecurityProfile":{"type":"Custom","custom":{"groups":["secp256r1"]}}}}'
```

**Do.** Make sure every client that talks to the cluster also offers `secp256r1` or `secp384r1`. Do not promise
post-quantum TLS on FIPS clusters. If both FIPS and PQC are required, raise it with Red Hat.

## Item 8: runC to crun (prerequisite for RHCOS 10)

**What breaks.** RHCOS 10 has no `runc`. Any pool whose effective CRI-O default runtime is runC cannot move to
`rhel-10`: the 5.0 render controller refuses to render, the pool goes `RenderDegraded=True` and `Degraded=True`, and
the machine-config operator reports `Upgradeable=False` (`DegradedPool`). Nodes are not touched, and there is no
automatic fallback to `rhel-9`. [LAB, 5.0.0; CODE MCO release-5.0 `render_controller.go`]

This affects most long-lived clusters: every cluster that ran **4.17.11 or later 4.17.z** got MCO-created
MachineConfigs `00-override-{master,worker}-generated-crio-default-container-runtime` that pin runC, and no later
release removes them. Clusters installed on 4.18 or later use crun. [CODE][LAB]

- The 4.22 → 5.0 upgrade itself is not blocked; upgraded clusters stay on `rhel-9`. The block fires when you switch
  the stream. RHCOS 9 is removed in 5.3. [CODE][DOC]
- A new 5.0 install with a day-0 runC ContainerRuntimeConfig and the default `rhel-10` fails at bootstrap. [CODE]
- `EvaluationConditionsDetected` on the machine-config ClusterOperator **misses** the override MachineConfigs (it
  only sees ContainerRuntimeConfigs). [LAB]
- Removing the runC pin **drains and reboots every node in the pool**; afterwards every pod runs on crun. [LAB]

**Detect** (run on 4.22, or on 5.0 while still on `rhel-9`):

```bash
# 1. Implicit runC from 4.17.11+ (most upgraded clusters)
oc get mc -o name | grep generated-crio-default-container-runtime
# 2. Explicit runC through ContainerRuntimeConfig
oc get containerruntimeconfig -o custom-columns=NAME:.metadata.name,RUNTIME:.spec.containerRuntimeConfig.defaultRuntime,POOLSEL:.spec.machineConfigPoolSelector
# 3. Hand-written MachineConfigs that drop files into /etc/crio/crio.conf.d/ (check them for default_runtime)
for mc in $(oc get mc -o name | grep -v rendered-); do
  oc get "$mc" -o json | jq -r --arg mc "$mc" '.spec.config.storage.files[]? | select(.path|startswith("/etc/crio/crio.conf.d/")) | "\($mc) \(.path)"'
done
# 4. What each node actually runs (authoritative)
for n in $(oc get nodes -o name); do echo "== $n"; oc debug -q "$n" -- chroot /host sh -c 'crio status config 2>/dev/null | grep -m1 default_runtime'; done
# 5. In-cluster signals: alert RuncDeprecated (severity info, 4.22 and 5.0) or this PromQL
#    count by (node) (container_runtime_crio_default_runtime{runtime="runc"})
oc get co machine-config -o jsonpath='{.status.conditions[?(@.type=="EvaluationConditionsDetected")]}{"\n"}'   # ContainerRuntimeConfig only
# 6. CRI-O settings made only for runc (allowed_annotations, runtime_root, hooks) that will not carry over
oc debug -q node/<node> -- chroot /host sh -c 'crio status config | sed -n "/runtimes.runc/,/^\[/p"'
```

**Do.**
1. Test workloads on crun on a one-node custom pool first. Known crun differences: per-runtime CRI-O
   `allowed_annotations` (for example `io.kubernetes.cri-o.TrySkipVolumeSELinuxLabel` added only under runc stops
   working; KCS 7123294), and a few fixed crun bugs (see `notes/research-runc-rhcos10.md`).
2. Delete the override MachineConfigs and any runC ContainerRuntimeConfig. Plan it as a rolling reboot of the pool.
3. Re-run step 4 above.
4. Only then switch the stream: `oc patch osimagestream cluster --type merge -p '{"spec":{"defaultStream":"rhel-10"}}'`.
5. If a pool goes RenderDegraded, revert `defaultStream` (or the pool's `spec.osImageStream`) to `rhel-9`, fix the
   runtime, retry.

## Item 9: other RHEL 10 crypto changes to check

| Change | Who is hit | Detect / do | Source |
|---|---|---|---|
| A RHEL 10 FIPS IdM replica cannot join an IdM deployment with a SHA-1 Kerberos master key; RSA PKINIT removed | IdM / Kerberos integrations of node-level tools | Check your IdM master key type before adding RHEL 10 hosts | [DOC] Considerations in adopting RHEL 10, ch. 13 |
| GnuTLS writes PKCS#12 with PBMAC1 (RFC 9579) in FIPS mode | Old PKCS#12 readers (older Java, appliances) | Test importing a `.p12` created on RHEL 10 into each consumer | [DOC] RHEL 10.0 release notes |
| OpenSSH host keys must be mode 0600; `ssh_keys` group removed | Node tooling that manages host keys | `stat -c '%a %G' /etc/ssh/ssh_host_*_key` | [DOC] Considerations in adopting RHEL 10, 20.2 |
| OpenSSL rejects SHA-1 at SECLEVEL=2 in TLS; TLS 1.0/1.1 needs LEGACY + SECLEVEL=0 (never in FIPS) | Legacy TLS peers | Already impossible in FIPS mode on RHEL 9 | [DOC] Considerations in adopting RHEL 10, 20.2 |

## Item 10: FIPS validation status (compliance, not a technical break)

- On RHEL 10.2 the OpenSSL FIPS provider reports itself as **"Red Hat Enterprise Linux 9 - OpenSSL FIPS Provider"
  3.0.7** (package `openssl-fips-provider-3.0.7-11.el10_2`), the same module as RHEL 9.8. [LAB]
- The OpenShift 5.0 FIPS documentation still describes FIPS support only for "RHEL 9 and RHCOS"; it has no RHCOS 10
  statement. [DOC]
  https://docs.redhat.com/en/documentation/openshift_container_platform/5.0/html-single/installation_overview/index#installation-about-fips-validation_installing-fips
- For RHEL 10 module certificates, Red Hat points to its Product compliance page. [DOC]
  https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/security_hardening/index#rhel_10_0_openssl_fips_indicators

**Do.** If your accreditation requires validated (not "in process") modules, confirm the RHEL 10 / RHCOS 10 status
with Red Hat before you switch, or install / keep `osImageStream: rhel-9` (supported until 5.3). RHCOS 10 FIPS
itself works: four of our 5.0 installs ran FIPS on RHCOS 10.2 with all operators healthy. [LAB]

## Summary table

| # | Item | Typical impact on a FIPS cluster | Detect | Lab-checked |
|---|---|---|---|---|
| 0 | RHEL 7 images unsupported on RHEL 10 hosts | Support | os-release per image | No (doc only) |
| 1 | SHA-1 signatures | Low (already blocked in FIPS); node workarounds lost | cert scan, MC scan | No |
| 2 | GnuTLS PKCS#1 v1.5, RSA key exchange | GnuTLS tools vs legacy peers | s_client cipher tests | No |
| 3 | OpenSSL 1.1, engines | Node binaries, HSM | ldd, MC scan | Partly (OSUS on OpenSSL 1.1.1 ran) |
| 4 | libgcrypt / GnuPG not validated | Compliance of gpg signing | rpm/command scan | No |
| 5 | `/etc/system-fips` gone | Compliance scripts false negatives | grep, node check | Partly (operators fine) |
| 6 | HMAC-SHA-1 deprecated | Future | code search | No |
| 7 | No X25519 / no PQC in FIPS | Pinned clients fail; PQC silently absent | s_client | **Yes** |
| 8 | runC → crun | Blocks the RHCOS 10 switch | MC, CRC, node runtime | **Yes** |
| 9 | IdM, PKCS#12, SSH key perms | Integrations | see table | No |
| 10 | Validation status | Compliance | ask Red Hat | Provider identity: yes |

## Sources in this repository

- `ocp5-disconnected-findings.md` section 3c and the 2026-11-05 PQC recheck
- `examples/telemetry-and-tls/RESULTS.md`, `endpoint-probe-2026-11-05.txt`
- `notes/research-runc-rhcos10.md`, `examples/runc-rhcos10-lab/RESULTS.md`
- `examples/operator-fips-and-signatures/RESULTS.md`, `examples/rhel10-fips-host/RESULTS.md`
- `examples/install-results/RESULTS.md` (installs 2-5, RHCOS 10.2 FIPS)
