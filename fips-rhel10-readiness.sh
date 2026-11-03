#!/usr/bin/env bash
# fips-rhel10-readiness.sh - READ-ONLY pre-check: will this RHEL 9 / RHCOS 9 system hit FIPS-related
# problems on RHEL 10 / RHCOS 10 (OpenShift 5)?
#
# Scope: straight crypto differences between RHEL 9 FIPS and RHEL 10 FIPS (not upgrade mechanics).
# Every check cites the RHEL 10 doc section it is based on:
#   C10  = RHEL 10 "Considerations in adopting RHEL 10", 20.2 Changes to cryptographic components
#   SH10 = RHEL 10 "Security hardening" (FIPS / crypto-policies)
#   RN10 = RHEL 10.0/10.2 release notes (security)
#
# Usage:
#   RHEL 9 host:      sudo ./fips-rhel10-readiness.sh [--scan-path DIR ...] [--cert-path DIR ...] [--quiet]
#   OpenShift node:   oc debug node/<node> -- chroot /host bash -s -- --quiet < fips-rhel10-readiness.sh
#
# Exit codes: 0 = no FAIL/WARN, 1 = WARN found, 2 = FAIL found.
# The script never modifies the system and makes no network calls.
# DRAFT - validate on a lab system before customer use.

set -u
LC_ALL=C

SCAN_PATHS=(/usr/local /opt)
CERT_PATHS=(/etc/pki/tls/certs /etc/pki/ca-trust/source/anchors /etc/pki/tls/misc /etc/kubernetes /etc/pki/nssdb)
QUIET=0
MAX_FILES=20000
FAILS=0; WARNS=0; INFOS=0; PASSES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --scan-path) SCAN_PATHS+=("$2"); shift 2 ;;
    --cert-path) CERT_PATHS+=("$2"); shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

if [ -t 1 ]; then R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; B=$'\e[36m'; N=$'\e[0m'; else R=''; Y=''; G=''; B=''; N=''; fi
fail() { FAILS=$((FAILS+1)); printf '%s[FAIL]%s %s\n       ref: %s\n' "$R" "$N" "$1" "$2"; }
warn() { WARNS=$((WARNS+1)); printf '%s[WARN]%s %s\n       ref: %s\n' "$Y" "$N" "$1" "$2"; }
info() { INFOS=$((INFOS+1)); [ "$QUIET" = 1 ] || printf '%s[INFO]%s %s\n' "$B" "$N" "$1"; }
pass() { PASSES=$((PASSES+1)); [ "$QUIET" = 1 ] || printf '%s[PASS]%s %s\n' "$G" "$N" "$1"; }
section() { printf '\n== %s ==\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------------------------------
section "System"
. /etc/os-release 2>/dev/null || true
info "OS: ${PRETTY_NAME:-unknown}  variant: ${VARIANT_ID:-n/a}"
IS_COREOS=0; [ "${VARIANT_ID:-}" = "coreos" ] && IS_COREOS=1
case "${VERSION_ID:-}" in
  9*|4*|5*) : ;;   # RHEL 9.x, RHCOS 4xx.9x / 9.x
  10*) warn "System already reports version ${VERSION_ID}; this check is intended for RHEL 9 / RHCOS 9." "n/a" ;;
esac
[ "$(id -u)" = 0 ] || warn "Not running as root; some files (host keys, keytabs, private certs) cannot be inspected." "n/a"

FIPS_ON=0
if [ -r /proc/sys/crypto/fips_enabled ] && [ "$(cat /proc/sys/crypto/fips_enabled)" = 1 ]; then
  FIPS_ON=1; pass "Kernel FIPS mode enabled (/proc/sys/crypto/fips_enabled=1)"
else
  info "Kernel FIPS mode NOT enabled. Findings below still apply if you plan to enable FIPS on RHEL 10 / RHCOS 10."
  info "On RHEL 10 FIPS can only be enabled at install time (fips=1); switching later is unsupported. [C10]"
fi

# ---------------------------------------------------------------------------------------------------
section "1. System-wide crypto policy and subpolicies"
if have update-crypto-policies; then
  POL=$(update-crypto-policies --show 2>/dev/null)
  info "Current policy: ${POL}"
  case "$POL" in
    *SHA1*) fail "Policy uses the SHA1 subpolicy ('$POL'). The SHA1 subpolicy is REMOVED in RHEL 10." "C10 'SHA1 subpolicy removed'" ;;
  esac
  case "$POL" in
    LEGACY*) warn "LEGACY policy: in RHEL 10 LEGACY no longer allows SHA-1 signatures in TLS; non-OpenSSL libraries may reject SHA-1 signatures entirely." "C10 'The LEGACY cryptographic policy disallows SHA-1 signatures in TLS'" ;;
  esac
  case "$POL" in
    *NO-ENFORCE-EMS*) warn "Policy uses NO-ENFORCE-EMS (peers without TLS 1.2 Extended Master Secret). Availability of this subpolicy on RHEL 10 is not documented - verify." "SH10 FIPS/EMS; gap" ;;
  esac
  if [ "$FIPS_ON" = 1 ] && [ "${POL%%:*}" != "FIPS" ]; then
    warn "FIPS kernel mode is on but policy is '$POL' (expected FIPS[:...])." "SH10 'FIPS mode status'"
  fi
  CUSTOM=$(ls /etc/crypto-policies/policies/modules/*.pmod /etc/crypto-policies/policies/*.pol 2>/dev/null)
  if [ -n "$CUSTOM" ]; then
    warn "Custom crypto-policy modules found - review against RHEL 10 policy syntax/algorithms: $(echo $CUSTOM | tr '\n' ' ')" "SH10 crypto-policies"
    if grep -lisE 'sha-?1' $CUSTOM >/dev/null 2>&1; then
      fail "Custom policy module re-enables SHA-1: $(grep -lisE 'sha-?1' $CUSTOM | tr '\n' ' ')" "C10 'SHA1 subpolicy removed'"
    fi
  else
    pass "No custom crypto-policy modules"
  fi
else
  info "update-crypto-policies not found"
fi

# ---------------------------------------------------------------------------------------------------
section "2. Removed FIPS tooling (fips-mode-setup, /etc/system-fips)"
REFS=$(grep -rIlsE '^[^#;]*(fips-mode-setup|/etc/system-fips)' /etc /usr/local /opt /var/spool/cron /root 2>/dev/null \
       | grep -vE '^/etc/(alternatives|selinux)/' | head -50)
if [ -n "$REFS" ]; then
  fail "Scripts/config reference fips-mode-setup or /etc/system-fips (both REMOVED in RHEL 10; use /proc/sys/crypto/fips_enabled):" "C10 'fips-mode-setup is removed', '/etc/system-fips removed'"
  echo "$REFS" | sed 's/^/         /'
else
  pass "No references to fips-mode-setup or /etc/system-fips in /etc, /usr/local, /opt, cron, /root"
fi

# ---------------------------------------------------------------------------------------------------
section "3. Removed / unvalidated crypto libraries"
if have rpm; then
  for p in compat-openssl11 openssl-pkcs11 xmlsec1-gcrypt xmlsec1-gnutls; do
    if rpm -q "$p" >/dev/null 2>&1; then
      case "$p" in
        compat-openssl11) fail "compat-openssl11 installed - REMOVED in RHEL 10 (OpenSSL 1.1 apps must move to OpenSSL 3)." "C10 'compat-openssl11 is removed'" ;;
        openssl-pkcs11)   fail "openssl-pkcs11 (engine) installed - replaced by pkcs11-provider in RHEL 10; in FIPS set pkcs11-module-assume-fips = true." "C10 'pkcs11-provider replaces openssl-pkcs11'; RN10" ;;
        *)                fail "$p installed - gcrypt-based xmlsec parts REMOVED in RHEL 10 (use xmlsec1-openssl)." "C10 Appendix A removed packages" ;;
      esac
    fi
  done
  if rpm -q libgcrypt >/dev/null 2>&1; then
    DEPS=$(rpm -q --whatrequires libgcrypt --qf '%{NAME}\n' 2>/dev/null | grep -v '^no package' | sort -u | tr '\n' ' ')
    warn "libgcrypt is NOT FIPS-validated on RHEL 10 (it was on RHEL 9). Packages requiring it: ${DEPS:-none directly}. GnuPG/GRUB2 are listed as non-compliant." "SH10 'RHEL applications using cryptography not compliant with FIPS 140-3'"
  fi
else
  info "rpm not available - skipping package checks"
fi

# ELF scan for third-party binaries linked against OpenSSL 1.1 / libgcrypt
if have readelf; then
  n=0; HITS11=""; HITSGC=""
  while IFS= read -r -d '' f; do
    n=$((n+1)); [ $n -gt $MAX_FILES ] && break
    head -c4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
    d=$(readelf -d "$f" 2>/dev/null) || continue
    case "$d" in *libssl.so.1.1*|*libcrypto.so.1.1*) HITS11+="$f"$'\n' ;; esac
    case "$d" in *libgcrypt.so*) HITSGC+="$f"$'\n' ;; esac
  done < <(find "${SCAN_PATHS[@]}" -xdev -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null)
  if [ -n "$HITS11" ]; then fail "Binaries linked to OpenSSL 1.1 (not available on RHEL 10):" "C10 'compat-openssl11 is removed'"; printf '%s' "$HITS11" | head -20 | sed 's/^/         /'; else pass "No OpenSSL 1.1-linked binaries under ${SCAN_PATHS[*]}"; fi
  if [ -n "$HITSGC" ]; then warn "Binaries linked to libgcrypt (unvalidated on RHEL 10):" "SH10"; printf '%s' "$HITSGC" | head -20 | sed 's/^/         /'; fi
else
  info "readelf not found - skipping ELF scan (install binutils to enable)"
fi

# ---------------------------------------------------------------------------------------------------
section "4. OpenSSL engines / provider configuration"
SEEN_CNF=" "
for cnf in /etc/pki/tls/openssl.cnf /etc/pki/tls/openssl.d/*.cnf /etc/ssl/openssl.cnf; do
  [ -r "$cnf" ] || continue
  real=$(readlink -f "$cnf"); case "$SEEN_CNF" in *" $real "*) continue ;; esac; SEEN_CNF+="$real "
  if grep -qiE '^\s*(engines|dynamic_path|engine_id)\s*=' "$cnf"; then
    fail "$cnf configures OpenSSL ENGINES; RHEL 10 uses the Providers API (pkcs11-provider)." "C10 'pkcs11-provider replaces openssl-pkcs11'"
  fi
done
pass "OpenSSL config engine check done"
info "OpenSSL FIPS indicators changed in RHEL 10 and may return 'unsupported'; apps that query indicators must be retested. [SH10 'RHEL 10.0 OpenSSL FIPS indicators']"

# ---------------------------------------------------------------------------------------------------
section "5. Trust store paths"
CAREFS=$(grep -rIlsE '^[^#;]*/etc/pki/tls/certs/(ca-bundle\.crt|ca-bundle\.trust\.crt)' /etc /usr/local /opt 2>/dev/null | grep -v '^/etc/pki/' | head -30)
if [ -n "$CAREFS" ]; then
  warn "Config references /etc/pki/tls/certs/ca-bundle*.crt directly; RHEL 10 guidance is /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem:" "C10 20.2 trust bundle paths"
  echo "$CAREFS" | sed 's/^/         /'
else
  pass "No direct references to /etc/pki/tls/certs/ca-bundle*.crt"
fi

# ---------------------------------------------------------------------------------------------------
section "6. Certificates: SHA-1 signatures, weak RSA, DSA"
if have openssl; then
  n=0; certs_checked=0
  while IFS= read -r -d '' f; do
    n=$((n+1)); [ $n -gt $MAX_FILES ] && break
    grep -q 'BEGIN CERTIFICATE' "$f" 2>/dev/null || continue
    # only first cert in file (leaf); bundles are reported per first cert
    txt=$(openssl x509 -in "$f" -noout -text 2>/dev/null) || continue
    certs_checked=$((certs_checked+1))
    subj=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    selfsigned=0; [ "$subj" = "$issuer" ] && selfsigned=1
    if echo "$txt" | grep -qiE 'Signature Algorithm: *(sha1With|ecdsa-with-SHA1|dsaWithSHA1)'; then
      if [ $selfsigned = 1 ]; then
        info "SHA-1 self-signed root (signature on a trust anchor itself is not verified): $f"
      else
        fail "SHA-1 signed certificate: $f ($subj)" "C10 'SHA1 subpolicy removed' / LEGACY SHA-1 TLS change"
      fi
    fi
    bits=$(echo "$txt" | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' | head -1)
    if echo "$txt" | grep -q 'rsaEncryption' && [ -n "$bits" ]; then
      if [ "$bits" -lt 2048 ]; then fail "RSA key < 2048 bits ($bits): $f" "SH10 FIPS policy (RSA >= 2048)"
      elif [ "$bits" -lt 3072 ]; then [ "$QUIET" = 1 ] || info "RSA $bits-bit (OK for FIPS, below FIPS:OSPP 3072): $f"; fi
    fi
    echo "$txt" | grep -q 'dsaEncryption\|id-dsa' && fail "DSA certificate (not allowed in FIPS): $f" "SH10 FIPS policy"
  done < <(find "${CERT_PATHS[@]}" -xdev -type f \( -name '*.crt' -o -name '*.pem' -o -name '*.cer' \) -print0 2>/dev/null)
  info "Certificates inspected: $certs_checked (paths: ${CERT_PATHS[*]}). Note: system CA bundle anchors are not individually parsed."
  P12=$(find "${CERT_PATHS[@]}" /etc /opt -xdev -type f \( -name '*.p12' -o -name '*.pfx' \) 2>/dev/null | head -20)
  [ -n "$P12" ] && warn "PKCS#12 files found. RHEL 10 GnuTLS/OpenSSL/NSS write PBMAC1 (RFC 9579) P12 in FIPS; older consumers may not read newly generated files: $(echo $P12)" "RN10.0 PKCS#12 PBMAC1"
else
  info "openssl not found - skipping certificate checks"
fi

# ---------------------------------------------------------------------------------------------------
section "7. SSH"
if [ -d /etc/ssh ]; then
  for k in /etc/ssh/ssh_host_*_key; do
    [ -e "$k" ] || continue
    perm=$(stat -c '%a' "$k" 2>/dev/null); grp=$(stat -c '%G' "$k" 2>/dev/null)
    [ "$perm" != "600" ] && fail "Host key $k has mode $perm; RHEL 10 OpenSSH requires 0600." "C10 / RN10.0 OpenSSH host key permissions"
    [ "$grp" = "ssh_keys" ] && warn "Host key $k is group ssh_keys; that group is removed in RHEL 10." "C10 'ssh_keys group removed'"
    [ "$(basename "$k")" = "ssh_host_dsa_key" ] && fail "DSA host key present: $k" "SH10 FIPS policy"
  done
  SSHCFG=$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf /etc/ssh/ssh_config /etc/ssh/ssh_config.d/*.conf 2>/dev/null | grep -iE '^\s*(Ciphers|MACs|KexAlgorithms|HostKeyAlgorithms|PubkeyAcceptedAlgorithms|CASignatureAlgorithms)\b')
  if echo "$SSHCFG" | grep -qiE 'sha1|ssh-rsa([, ]|$)|ssh-dss|chacha20|3des|arcfour|cbc'; then
    warn "SSH config overrides crypto-policies with SHA-1/DSS/ChaCha20/CBC algorithms:" "SH10 FIPS policy; C10 SHA-1 changes"
    echo "$SSHCFG" | sed 's/^/         /'
  else
    pass "No legacy SSH algorithm overrides"
  fi
  info "RHEL 10.2 OpenSSH adds hybrid ML-KEM KEX (mlkem768nistp256-sha256, mlkem1024nistp384-sha384) allowed in FIPS. [RN10.2]"
fi

# ---------------------------------------------------------------------------------------------------
section "8. Kerberos / IdM"
if [ -r /etc/krb5.keytab ] && have klist; then
  ET=$(klist -ke /etc/krb5.keytab 2>/dev/null | grep -oE '\(([a-z0-9-]+)\)' | sort -u | tr '\n' ' ')
  info "Keytab enctypes: ${ET:-unknown}"
  echo "$ET" | grep -qE 'aes(128|256)-cts-hmac-sha1-96' && warn "Keytab contains AES-HMAC-SHA1 enctypes; their KDF is not allowed by the RHEL 10 FIPS policy (and RHEL 10 FIPS replicas cannot join IdM with a SHA-1 master key)." "C10 ch.13 Identity Management"
fi
if have ipa || [ -r /etc/ipa/default.conf ]; then
  warn "IdM client/server detected: verify the IdM Kerberos master key type before introducing RHEL 10 FIPS hosts; RSA PKINIT is removed in RHEL 10." "C10 ch.13 Identity Management"
fi

# ---------------------------------------------------------------------------------------------------
section "9. GnuTLS RSA PKCS#1 v1.5 encryption"
if have rpm && rpm -q gnutls >/dev/null 2>&1; then
  USERS=$(rpm -q --whatrequires 'libgnutls.so.30()(64bit)' --qf '%{NAME}\n' 2>/dev/null | grep -v '^no package' | sort -u | head -40 | tr '\n' ' ')
  info "GnuTLS consumers (RHEL 10 sets allow-rsa-pkcs1-encrypt=false in DEFAULT/FUTURE/FIPS; RSA key-transport/PKCS#1 v1.5 encryption will fail): ${USERS:-none}"
  info "  Retest any of these that talk to legacy peers using TLS RSA key exchange. [C10 'crypto-policies now set allow-rsa-pkcs1-encrypt = false for GnuTLS']"
fi

# ---------------------------------------------------------------------------------------------------
section "10. HMAC-SHA-1 and SHA-1 usage hints"
HSHA1=$(grep -rIlsiE '^[^#;]*(hmac-?sha1|hmacsha1)' /etc /opt /usr/local 2>/dev/null | grep -vE '^/etc/(crypto-policies|ssh)/' | head -20)
[ -n "$HSHA1" ] && warn "Config mentions HMAC-SHA1 (DEPRECATED in RHEL 10 FIPS mode; may be removed):" "RN10.0 deprecated features - security" && echo "$HSHA1" | sed 's/^/         /'

# ---------------------------------------------------------------------------------------------------
section "11. OpenShift / RHCOS specifics"
if [ "$IS_COREOS" = 1 ] || [ -d /etc/crio ]; then
  RT=$(grep -rhsE '^\s*default_runtime\s*=' /etc/crio/crio.conf /etc/crio/crio.conf.d/ 2>/dev/null | tail -1)
  case "$RT" in
    *runc*) warn "CRI-O default_runtime is runc. RHCOS 10 does not ship runc; OCP 5 keeps runc pools on rhel-9 and runc must move to crun before switching to RHCOS 10." "OpenShift 5.0 docs (hcp-dual-stream-container-runtime.adoc, openshift-docs enterprise-5.0)" ;;
    *) pass "CRI-O default runtime: ${RT:-default (crun)}" ;;
  esac
  info "On OCP, FIPS is set by install-config 'fips: true' (immutable). Workload images inherit host FIPS mode; rebuild images carrying OpenSSL 1.1 or SHA-1 dependencies."
  have podman && info "Tip: scan workload images with this script, e.g. podman run --rm -v ./fips-rhel10-readiness.sh:/s:Z <image> bash /s --quiet"
else
  info "Not an RHCOS/CRI-O host - skipping OpenShift checks"
fi

# ---------------------------------------------------------------------------------------------------
section "Not checkable locally (review manually)"
info "- Remote peers: TLS 1.2 without Extended Master Secret, RSA key exchange, SHA-1 signed peer certs, ChaCha20-only clients."
info "- RHEL 10 CMVP certificate status for your required modules (Red Hat 'Compliance Activities and Government Standards', KB 2918071)."
info "- Java/OpenJDK and Go FIPS behavior specific to RHEL 10 (no official delta doc found)."

printf '\nSummary: %s FAIL, %s WARN, %s PASS, %s INFO\n' "$FAILS" "$WARNS" "$PASSES" "$INFOS"
[ "$FAILS" -gt 0 ] && exit 2
[ "$WARNS" -gt 0 ] && exit 1
exit 0
