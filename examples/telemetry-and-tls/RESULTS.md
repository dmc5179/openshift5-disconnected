# Disconnected OpenShift 5.0: console telemetry call and post-quantum TLS in FIPS mode

Lab: install 4 (2026-11-04). OpenShift 5.0.0 on AWS, private subnet, FIPS on all 5 nodes (RHCOS 10.2). All egress
goes through a Squid SNI filter that blocks api.openshift.com. Commands ran on the registry node (RHEL 9.8, FIPS,
OpenSSL 3.5.8), which holds the kubeconfig. Tags: **[LAB]** observed on this cluster, **[CODE]** read in upstream
source, **[DOC]** published 5.0 docs.

## T1: stopping the console-operator call to api.openshift.com

### Result

**It works.** [LAB] Two annotations on `consoles.operator.openshift.io/cluster` stop the 5-minute OCM subscription
lookup. They take effect on the next sync, with no operator restart. Before: 4 calls in 20 min (one every 5 min).
After: 0 calls in 15.5 min (the 15:35, 15:40 and 15:45 calls did not happen), from any node.

```bash
oc annotate consoles.operator.openshift.io cluster \
  telemetry.console.openshift.io/ORGANIZATION_ID=0000000 \
  telemetry.console.openshift.io/ACCOUNT_MAIL=disconnected@example.com
```

Remove:

```bash
oc annotate consoles.operator.openshift.io cluster \
  telemetry.console.openshift.io/ORGANIZATION_ID- \
  telemetry.console.openshift.io/ACCOUNT_MAIL-
```

The values are placeholders. The cluster has no OCM subscription to look up, so no real value exists. Use a value
that is obviously fake, so that nobody mistakes it for a real Red Hat organization.

### Why it works [CODE]

Source: github.com/openshift/console-operator, branch `release-5.0`. `pkg/console/telemetry/telemetry.go` is
identical on `master`.

- `pkg/console/operator/sync_v400.go` `GetTelemetryConfiguration()` builds the telemetry map in this order: every
  annotation on the Console operator config that starts with `telemetry.console.openshift.io/` (prefix removed),
  then the data keys of the `openshift-console-operator/telemetry-config` ConfigMap (these override the
  annotations), then `CLUSTER_ID` and `TELEMETER_CLIENT_DISABLED`, then the organization metadata.
- `pkg/console/telemetry/telemetry.go` `GetOrganizationMeta()`:

  ```go
  customOrganizationID, isCustomOrgIDSet := telemetryConfig["ORGANIZATION_ID"]
  customAccountMail, isCustomAccountMailSet := telemetryConfig["ACCOUNT_MAIL"]
  if isCustomOrgIDSet && isCustomAccountMailSet {
      klog.V(4).Infoln("telemetry config: using custom data")
      return customOrganizationID, customAccountMail, false
  }
  ```

  The OCM fetch (`getSubscriptionWithRateLimit`, `FailureBackoffInterval = 5 * time.Minute`) runs only when this
  early return does not happen. Both keys must be present. The check is for presence, not for a non-empty value.
- The fetch does not depend on telemeter-client or on a `cloud.openshift.com` token. With neither, it still runs
  every 5 min (seen in N-10).

Why the annotation and not the ConfigMap: `telemetry-config` is owned by the ClusterVersion
(`ownerReferences: ClusterVersion version`, release annotations), so the CVO would reconcile manual keys away. We
did not test the ConfigMap route. The Console operator config is a user-owned CR.

### Evidence [LAB]

Baseline (15:10-15:30Z, console-operator pod `console-operator-b96f99c6b-ghl6d` on master ip-10-0-50-65):

```
$ oc logs -n openshift-console-operator deploy/console-operator --since=20m | grep -c "telemetry config error"
4
E1104 15:15:24.809509 1 telemetry.go:120] telemetry config error: failed to GET (https://api.openshift.com/api/accounts_mgmt/v1/subscriptions?fetchAccounts=true&fetchOrganization=true&search=external_cluster_id%3D...
E1104 15:20:24.825497 ...
E1104 15:25:24.810498 ...
E1104 15:30:24.816083 ...

Squid (/var/log/squid/access.log, blocked = NONE_NONE/000):
15:15:24 10.0.50.65 NONE_NONE/000 api.openshift.com
15:20:24 10.0.50.65 NONE_NONE/000 api.openshift.com
15:25:24 10.0.50.65 NONE_NONE/000 api.openshift.com
15:30:24 10.0.50.65 NONE_NONE/000 api.openshift.com
```

Annotation applied at 15:30:59Z. The AI opt-out ValidatingAdmissionPolicy (`examples/ai-opt-out-policy/`) did not
deny it: it checks `spec`, and annotations are metadata. The operator synced at once:

```
I1104 15:30:59.654012 1 core.go:352] ConfigMap "openshift-console/console-config" changes: ...
$ oc get cm -n openshift-console console-config -o yaml | grep -A2 telemetry
    telemetry:
      ACCOUNT_MAIL: disconnected@example.com
      ORGANIZATION_ID: "0000000"
```

After (15:31:00-15:46:31Z, 15.5 min, any node):

```
$ oc logs -n openshift-console-operator deploy/console-operator --since-time=2026-11-04T15:31:00Z | grep -c "telemetry config error"
0
(the last telemetry error in the log is E1104 15:30:24.816083)

Squid, all clients, api.openshift.com:
15:10:00-15:31:00  pre=5   (15:10:24, 15:15:24, 15:20:24, 15:25:24, 15:30:24, all 10.0.50.65 NONE_NONE/000)
15:31:00-15:46:31  post=0
```

### Side effects [LAB]

- The console-config change rolls the `console` Deployment once (new ReplicaSet `console-5698dc848d`, pods started
  15:31Z). Plan it as a short console restart, like any console config change.
- `clusteroperator/console`: Available=True, Progressing=False, Degraded=False after the change and at the end of the
  window.
- Route `console-openshift-console.apps.ocp5.<baseDomain>` (reencrypt/Redirect). `curl --cacert <ingress CA>` from
  the registry node returned HTTP 200 with a verified certificate (CA from
  `openshift-config-managed/default-ingress-cert`).
- [INFER] The placeholder org ID and e-mail go to the console front end as telemetry metadata (Segment analytics).
  On a disconnected cluster the Segment hosts (`console.redhat.com/connections/...`) cannot be reached, so nothing
  leaves the cluster. Do not use this setting on a connected cluster that reports telemetry, because it would send
  fake account data.

### Day-0 equivalent (proposed, not applied to the script)

Put the annotations on the Console operator manifest that `scripts/generate-install-config.sh` already writes to
the day-0 manifests directory. Keep one manifest per object. When `DISABLE_LIGHTSPEED=true`, add the annotations to
`99-console-disable-lightspeed.yaml`. Otherwise, write a separate metadata-only manifest. A proposed snippet with a
new `cluster.env` switch `SILENCE_CONSOLE_OCM_LOOKUP` (default `true` for disconnected):

```bash
# --- console-operator OCM subscription lookup (N-10) -------------------------------
# console-operator GETs api.openshift.com/api/accounts_mgmt/v1/subscriptions every 5 min
# unless ORGANIZATION_ID and ACCOUNT_MAIL are both set (telemetry.go GetOrganizationMeta,
# console-operator release-5.0). Placeholders: a disconnected cluster has no OCM subscription.
CONSOLE_TELEMETRY_ANNOTATIONS=""
if [ "${SILENCE_CONSOLE_OCM_LOOKUP:-true}" = "true" ]; then
    CONSOLE_TELEMETRY_ANNOTATIONS='  annotations:
    telemetry.console.openshift.io/ORGANIZATION_ID: "0000000"
    telemetry.console.openshift.io/ACCOUNT_MAIL: "disconnected@example.com"'
fi

if [ "${DISABLE_LIGHTSPEED:-false}" = "true" ]; then
    cat > "${D0}/99-console-disable-lightspeed.yaml" <<EOF
# Hide the OpenShift Lightspeed AI entry point in the web console from first boot.
# Capability names per openshift/api operator/v1 types_console.go (5.0):
# LightspeedButton, GettingStartedBanner, GuidedTour.
apiVersion: operator.openshift.io/v1
kind: Console
metadata:
  name: cluster
${CONSOLE_TELEMETRY_ANNOTATIONS}
spec:
  managementState: Managed
  customization:
    capabilities:
    - name: LightspeedButton
      visibility:
        state: Disabled
EOF
elif [ -n "$CONSOLE_TELEMETRY_ANNOTATIONS" ]; then
    cat > "${D0}/99-console-telemetry-org.yaml" <<EOF
apiVersion: operator.openshift.io/v1
kind: Console
metadata:
  name: cluster
${CONSOLE_TELEMETRY_ANNOTATIONS}
spec:
  managementState: Managed
EOF
fi
```

The heredoc becomes unquoted (`<<EOF`) so the variable expands. The manifest has no `$` or backticks, so this is
safe. The rendered manifest:

```yaml
apiVersion: operator.openshift.io/v1
kind: Console
metadata:
  name: cluster
  annotations:
    telemetry.console.openshift.io/ORGANIZATION_ID: "0000000"
    telemetry.console.openshift.io/ACCOUNT_MAIL: "disconnected@example.com"
spec:
  managementState: Managed
  customization:
    capabilities:
    - name: LightspeedButton
      visibility:
        state: Disabled
```

Not tested at day 0. Validate it on the next install (expect zero console-operator api.openshift.com denials from
the start, apart from the CVO calls during install; see N-4).

## T2: X25519MLKEM768 and FIPS mode

### What the docs say [DOC]

5.0 release notes, 1.3.16 "Security", "Quantum-safe key encapsulation support with ML-KEM is now available"
(https://docs.redhat.com/en/documentation/openshift_container_platform/5.0/html-single/release_notes/index):

> OpenShift Container Platform 5.0 adds support for quantum-safe key encapsulation across all Go-based TLS servers in
> the platform. This implementation uses the X25519MLKEM768 hybrid key encapsulation mechanism (KEM) [...] The
> X25519MLKEM768 group is enabled by default in the Old, Intermediate, and Modern predefined TLS security profiles.
> When a client supports ML-KEM, the TLS handshake automatically negotiates quantum-safe key exchange.
>
> Important: X25519MLKEM768 is not FIPS-approved. Components running in FIPS mode automatically ignore this group.

Release notes 1.1.2 "About PQC compliance" adds that components use hybrid ML-KEM "where enabled by the configured
TLS security profile and supported by the component."

### Cluster configuration [LAB]

```
$ oc get apiserver cluster -o jsonpath='{.spec}'
{"audit":{"profile":"Default"}}                 # no tlsSecurityProfile -> default (Intermediate)
$ oc get ingresscontroller -n openshift-ingress-operator default -o jsonpath='{.spec.tlsSecurityProfile}'
                                                # empty -> default
$ oc get ingresscontroller -n openshift-ingress-operator default -o jsonpath='{.status.tlsProfile}'
{"ciphers":[...8 ciphers...],"minTLSVersion":"VersionTLS12"}   # no groups/curves field in status
$ oc explain apiserver.spec.tlsSecurityProfile.intermediate
  The supported groups list includes by default the following groups in suggested preference order
  (ordering may not be honored by all implementations): X25519MLKEM768, X25519, secp256r1, secp384r1.
$ oc explain apiserver.spec.tlsSecurityProfile.custom
  The supported groups list for this profile is empty by default.
  FIELDS: ciphers, minTLSVersion             # no curves/groups field exposed in this 5.0.0 API
```

There is no user-settable `curves` / `groups` field in the 5.0.0 APIServer or IngressController schema
(`oc explain --recursive | grep -iE 'curve|group'` returns nothing). The groups are implied by the profile.

### Client [LAB]

The registry node is RHEL 9.8 in FIPS mode with OpenSSL 3.5.8. Its FIPS crypto policy offers only
`secp256r1:secp521r1:secp384r1:ffdhe*` (`/etc/crypto-policies/back-ends/opensslcnf.config`). The FIPS provider is
`Red Hat Enterprise Linux 9 - OpenSSL FIPS Provider 3.0.7`, which has no ML-KEM and no X25519. With the default
configuration the client cannot even offer the group:

```
$ openssl s_client -connect api.ocp5.<baseDomain>:6443 -groups X25519MLKEM768 -tls1_3 </dev/null
Call to SSL_CONF_cmd(-groups, X25519MLKEM768) failed
```

To test what the **server** accepts, we ran the client with `OPENSSL_CONF=/dev/null`. That skips the system crypto
policy and the FIPS provider configuration, so OpenSSL uses its default provider, which supports X25519MLKEM768
(`OPENSSL_CONF=/dev/null openssl list -tls1_3 -tls-groups` lists `X25519MLKEM768`). This is a test client only. It
does not change the host. It plays the part of a non-FIPS client, such as a workstation.

### Results [LAB]

Command pattern (TLS 1.3 only):

```bash
OPENSSL_CONF=/dev/null openssl s_client -connect <host:port> -servername <host> -groups <list> -tls1_3 -msg </dev/null
```

| Client offers (`-groups`) | API `api.ocp5...:6443` (kube-apiserver, Go) | Ingress `console-openshift-console.apps...:443` (HAProxy router) |
|---|---|---|
| `X25519MLKEM768` | **handshake_failure** (alert 40), client wrote 1441 bytes (ML-KEM key share sent) | **handshake_failure** (alert 40) |
| `X25519MLKEM768:X25519:secp256r1:secp384r1` | HelloRetryRequest, then **secp256r1** (`Peer Temp Key: ECDH, prime256v1, 256 bits`), TLS_AES_128_GCM_SHA256 | HelloRetryRequest, then **secp256r1**, TLS_AES_128_GCM_SHA256 |
| `X25519` | **handshake_failure** (alert 40) | **handshake_failure** (alert 40) |
| `secp256r1` | **secp256r1**, TLS_AES_128_GCM_SHA256 | **secp256r1**, TLS_AES_128_GCM_SHA256 |
| `secp384r1` | **secp384r1**, TLS_AES_128_GCM_SHA256 | **secp384r1**, TLS_AES_128_GCM_SHA256 |
| `SecP256r1MLKEM768` (NIST hybrid) | **handshake_failure** (alert 40) | **handshake_failure** (alert 40) |
| default FIPS client (no `OPENSSL_CONF` override), `secp256r1:secp384r1` | secp256r1, TLS_AES_128_GCM_SHA256 | secp256r1, TLS_AES_128_GCM_SHA256 |

The HelloRetryRequest shows up in `-msg` output as two ServerHello records (length 0x58, then 0x9b). OpenSSL 3.5
sends key shares for X25519MLKEM768 and X25519 first. The server accepts neither and asks for P-256.

### Conclusions

- [LAB] Confirmed: in FIPS mode, both the API server and the default ingress ignore X25519MLKEM768, as the release
  note says. A PQC-capable client falls back to classical P-256 ECDHE with a HelloRetryRequest. One extra round trip,
  no failure.
- [LAB] The docs leave this out: FIPS mode also drops **X25519**, the classical half of the default group list. A
  client that offers only X25519 (or only X25519MLKEM768) **cannot connect** to a FIPS cluster. Clients must offer
  secp256r1 or secp384r1. Most general-purpose clients (browsers, curl, Go, OpenSSL defaults) offer P-256 as well,
  so this matters mainly for hardened or pinned client configurations.
- [LAB] The NIST-curve hybrid `SecP256r1MLKEM768` is not accepted either. A FIPS 5.0 cluster has **no PQC key
  exchange** on these endpoints. [INFER] This follows from the RHEL FIPS provider (3.0.7 on RHEL 9 and RHEL 10.2, see
  F3), which has no ML-KEM. Customers who need both FIPS and PQC have to wait for a validated provider with ML-KEM.
- [LAB] The release note talks about "Go-based TLS servers". The ingress router (HAProxy, OpenSSL) behaves the same in
  FIPS mode.
- [INFER] Not tested here: the non-FIPS behaviour (the same matrix against a non-FIPS 5.0 cluster should negotiate
  X25519MLKEM768), and other endpoints (oauth, internal services, etcd, kubelet).

## State left behind

- The two telemetry annotations stay on `consoles.operator.openshift.io/cluster` (removal command above).
- No pods, debug sessions or background jobs are left running. The T2 tests were read-only.

## Recheck on a second FIPS cluster, with FIPS and non-FIPS clients (2026-11-05)
Cluster: install 5 (5.0.0, RHCOS 10.2, FIPS, installed from a RHEL 10.2 FIPS host). Default Intermediate TLS profile.

**Server side (unchanged from 2026-11-04)** [LAB]. Clients: a non-FIPS RHEL 9.8 host (OpenSSL 3.5.8) and a FIPS RHEL 10.2 host (OpenSSL 3.5.8, policy FIPS).

| Client | Offers | API :6443 and ingress :443 |
|---|---|---|
| non-FIPS | `X25519MLKEM768` only | handshake failure (alert 40) |
| non-FIPS | `X25519` only | handshake failure |
| non-FIPS | `SecP256r1MLKEM768` only | handshake failure |
| non-FIPS | `X25519MLKEM768:X25519:secp256r1:secp384r1` | **silently negotiates ECDH P-256** (`Peer Temp Key: ECDH, prime256v1`), TLS_AES_128_GCM_SHA256 |
| non-FIPS | `secp256r1` / `secp384r1` | P-256 / P-384 |
| FIPS (RHEL 10.2) | `X25519MLKEM768` | not offered: `SSL_CONF_cmd(-groups, X25519MLKEM768)` fails on the client |
| FIPS (RHEL 10.2) | `SecP256r1MLKEM768` only | handshake failure: the cluster doesn't offer it |
| FIPS (RHEL 10.2) | `SecP256r1MLKEM768:secp256r1` | silently falls back to P-256 |

**Client side: RHEL 10.2 in FIPS mode can do a PQC hybrid** [LAB]
- `openssl list -tls-groups -tls1_3` in FIPS mode: secp256r1, secp384r1, secp521r1, brainpool, ffdhe*, **SecP256r1MLKEM768**. No X25519 or X25519MLKEM768.
- A local `s_server`/`s_client` handshake, both ends in FIPS mode, negotiated **`SecP256r1MLKEM768`**.
- `openssl list -kem-algorithms`: `SecP256r1MLKEM768 @ default`, `SecP384r1MLKEM1024 @ default`. **The ML-KEM part comes from the default provider, not the FIPS provider.** The FIPS provider is `Red Hat Enterprise Linux 9 - OpenSSL FIPS Provider 3.0.7`, which has no ML-KEM. [INFER] RHEL 10 permits the hybrid in FIPS mode because the key-exchange security rests on the approved P-256 ECDH component; whether that counts as FIPS 140-3 compliant for a given customer is a compliance question.

**What this means**
1. **Silent downgrade.** A FIPS OpenShift 5.0 cluster has no post-quantum key exchange on the API or ingress. Modern clients that offer hybrid plus classical groups fall back to classical P-256 with no error, warning, condition or metric. Customers who enable FIPS and expect 5.0's "quantum-safe by default" TLS won't notice they don't have it.
2. **Visible failures for some clients.** Clients restricted to X25519, or to PQC-only groups, fail the handshake. The docs don't say X25519 is unavailable in FIPS mode.
3. **A FIPS-compatible hybrid exists but isn't used.** RHEL 10.2 in FIPS mode supports `SecP256r1MLKEM768`, but the OpenShift TLS profiles only list `X25519MLKEM768`, `X25519`, `secp256r1` and `secp384r1`, so even FIPS client to FIPS cluster connections end up classical.
4. **Can't be configured.** `spec.tlsSecurityProfile.custom.groups` is documented, but the 5.0.0 API on a Default cluster returns "unknown field" and drops it, a silent misconfiguration risk with GitOps. Administrators can't add `SecP256r1MLKEM768` themselves.
5. **Not tested yet:** non-FIPS clusters (expected to negotiate X25519MLKEM768) and the RHEL 10 / RHCOS 10 CMVP certificate status (F3). Other platform endpoints and operator operands: tested below.

## Platform endpoints and operator operands on the FIPS cluster (2026-11-05)
Same cluster (install 5). Client: OpenSSL 3.5.8 on a worker or master node (`oc debug node`, `chroot /host`) with `OPENSSL_CONF=/dev/null`, so the client ignores the node's FIPS policy and can offer every group. Targets: every Service endpoint port in the platform, cert-manager and Lightspeed namespaces plus the host-network services (56 targets). Three probes each: the full list `X25519MLKEM768:X25519:secp256r1:secp384r1`, `SecP256r1MLKEM768` only, `X25519MLKEM768` only. Raw output: `endpoint-probe-2026-11-05.txt` [LAB].

| Result | Count | Endpoints |
|---|---|---|
| **TLSv1.3, ECDH P-256 with the full list; both PQC groups rejected (alert 40)** | 38 + 2 | kube-apiserver direct :6443, kubelet :10250 (master and worker), kube-controller-manager :10257, kube-scheduler :10259, openshift-apiserver, oauth-apiserver, oauth-openshift, console, image-registry, node-exporter and every monitoring kube-rbac-proxy / metrics endpoint, metrics-server, thanos-sidecar grpc, cert-manager webhook :10250 and operator metrics :8443, Lightspeed operator metrics :8443 and agentic webhook :9443. **etcd client :2379 and peer :2380** (rerun from a master with the etcd peer certificate as the client cert): same result. |
| Plain HTTP (no TLS in the pod) | 13 | OSUS graph-builder / policy-engine :8080/:8081/:9080/:9081 (the route is `edge`, so external TLS ends at HAProxy, already covered by the ingress test), console downloads :8080, alertmanager mesh :9094, cert-manager metrics/health, Lightspeed agentic operator metrics/health |
| Not testable | 3 | thanos-sidecar :10902 and thanos-query :9090 (HTTP-only ports behind kube-rbac-proxy); machine-config-server :22623/:22624 (listening, but the node firewall refuses connections from the host itself and from other nodes) |

**Conclusion:** no TLS server on a FIPS 5.0 cluster offers a post-quantum group. Every endpoint, including etcd, the kubelet and the operator webhooks, behaves exactly like the API server and the ingress: silent fallback to P-256 for clients that also offer classical groups, handshake failure for PQC-only clients. Operator operands with their own TLS stacks (OSUS on OpenSSL 1.1.1) don't change the picture because they serve plain HTTP behind the router.
