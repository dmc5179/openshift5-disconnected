# Squid egress audit: simulated-disconnected OCP 5.0.0 on AWS (2026-11-03)

Read-only audit of the Squid NAT/egress filter (10.0.9.36, Squid 5.5) after the `ocp5` install
(OCP 5.0.0, IPI AWS, publish Internal, FIPS, RHCOS 10.2). Log window 13:07-19:33 UTC, 2,613 lines.

## Setup observed

- iptables on the Squid host redirects only tcp/80 → 3129 and tcp/443 → 3130 (intercept). No other
  ports are forwarded, so non-HTTP(S) egress (NTP, etc.) is not logged here. The tcp/80 counter was 0;
  all 2,613 entries are intercepted HTTPS (`CONNECT ip:443`).
- Allowlist (`/etc/squid/whitelist.txt`): `.amazonaws.com .cloudfront.net .ce.redhat.com .opentlc.com`,
  matched on SNI (peek step1, peek+splice step2/3 if allowed, else `terminate`).
- Result codes: `TCP_TUNNEL/200` = spliced (allowed), 1,660 lines. `NONE_NONE/000` with
  `HIER_NONE` = terminated (denied), 953 lines.

### The log does NOT contain the SNI (config defect in the running instance)

`/etc/squid/squid.conf` on the instance has
`logformat squid %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %ssl::>sni %Sh/%<a %mt`.
`squid -k parse` reports `ERROR: logformat squid is already defined. Ignoring.` The built-in
`squid` format is used, and the 8th field (which we expected to be the SNI) is really `%[un` (always
`-`). Every line therefore has only the destination IP. The repo template
(`cloudformation/disconnected_vpc_plus.yaml` lines 536-537) already has the fix (`logformat egress ...`
plus `access_log daemon:/var/log/squid/access.log logformat=egress`), but the deployed stack predates it.
**Hostnames below were reconstructed** by resolving candidate names from the Squid host (5 rounds of
`getent ahostsv4`) and matching IPs, plus AWS `ip-ranges.json` for AWS-service attribution. That is
[INFER] at the name level. The quay.io and registry.redhat.io matches are strong (whole round-robin pools match).

## Sources

| Source IP | Role | Window (UTC) | Allowed | Denied |
|---|---|---|---|---|
| 10.0.53.54 | mirror-registry node | 13:07-18:34 | 458 | 9 |
| 10.0.57.172 | earlier attempt (terminated) | 14:45-15:34 | 1 | 6 |
| 10.0.59.55, .57.223, .57.196, .56.235, .57.107 | earlier install attempt (bootstrap/masters/workers, terminated) | 15:23-18:29 | 837 | 463 |
| 10.0.57.204 | current install bootstrap (terminated) | 18:48-19:13 | 2 | 9 |
| 10.0.49.92, .50.111, .63.30 | current control plane | 18:58-now | 352 | 96 |
| 10.0.59.162, .62.181 | current workers | 19:12-now | 11 | 370 |

The bastion is in the public subnet and does not use Squid, so it does not appear.

## DENIED (terminated) destinations

| Destination (reconstructed) | Who | Count | Cause (from the cluster side) |
|---|---|---|---|
| **registry.redhat.io** | current master 10.0.50.111 (74, 19:15-19:28); earlier masters/bootstrap (143) | ~217 | **OLM v1 default ClusterCatalogs** `openshift-redhat-operators`, `-certified-`, `-community-operators` point at `registry.redhat.io/redhat/*-index:v5.0`. catalogd retries forever: `pinging container registry registry.redhat.io: Get "https://registry.redhat.io/v2/": EOF`. `OperatorHub.spec.disableAllDefaultSources: true` is set and there are no CatalogSources, but this **does not disable the OLM v1 ClusterCatalogs**. |
| **api.openshift.com** | bootstrap 10.0.57.204 (9); masters 10.0.49.92, .63.30 (7); earlier attempt (102) | ~118 | CVO update checks: `https://api.openshift.com/api/upgrades_info/v1/graph?arch=amd64&channel=stable-5.0&id=...&version=5.0.0` → `RemoteFailed ... EOF`. ClusterVersion condition `RetrievedUpdates=False`. The cluster ID is sent in the query. The bootstrap CVO tries as well. |
| **quay.io / cdn03.quay.io** | masters (15, 19:15-19:32); earlier attempt (~110) | ~125 | **ImageStream imports in `openshift` ns** (cli, cli-artifacts, driver-toolkit, installer, must-gather, network-tools, ...). Import first tries the IDMS mirror, fails with `x509: certificate signed by unknown authority` (the mirror CA is not in `image.config.openshift.io/cluster` `additionalTrustedCA`; spec is `{}`), then falls back to `quay.io/openshift-release-dev/ocp-v5.0-art-dev@sha256:...` → `EOF`. |
| 172.30.0.1:443 (Service VIP) | workers 10.0.59.162/.62.181 (370, 19:12-19:16 only); earlier workers (114) | 484 | Not external. Node-boot traffic to the kube Service VIP that left the node before OVN-Kubernetes programmed it, so it hit the default route (NAT instance). Transient, stops within ~4 min of node boot. Harmless, but noisy in an egress audit. |
| subscription.rhsm.redhat.com (Akamai) | registry node | 2 | RHEL subscription-manager/RHSM on the registry host. |
| registry.access.redhat.com | registry node | 3 | RHEL host (podman pull or similar) at 13:43, around mirror-registry install time. |
| quay.io | registry node | 3 | 14:35, host-side pull attempt. |
| 3.212.198.128 (us-east-1 EC2, unresolved) | registry node | 1 | Unknown Red Hat or AWS-hosted endpoint at 13:43. |

**Not seen at all** from any node (no matching IPs): cloud.openshift.com, console.redhat.com,
sso.redhat.com, infogw/cert-api (Insights), observatorium (telemetry), mirror.openshift.com,
rhcos.mirror.openshift.com, any LLM endpoint (api.openai.com, generativelanguage.googleapis.com).
This is consistent with the capability set: `baselineCapabilitySet: None`, Insights not enabled (no
`insights` ClusterOperator), no Lightspeed/agentic pods, and the samples operator `Removed`. Telemetry
(monitoring remote-write) would only show up if enabled. [INFER: absence in a ~40 min window is not proof.]

Console: the console pod logs `SEGMENT_API_HOST console.redhat.com/connections/api/v1` and
`SEGMENT_JS_HOST console.redhat.com/connections/cdn` (console telemetry config). Those calls are made
from the **user's browser**, not from the nodes, so they never go through this Squid.

## ALLOWED (spliced) destinations

All allowed traffic went to AWS (`.amazonaws.com` SNI). By IP and AWS range:
- us-east-2 AWS APIs: **sts**, **ec2**, **elasticloadbalancing** (machine-api, CCM, ingress, CCO STS
  flow). servicequotas came from the registry node (the openshift-install run that was there earlier).
- Global or us-east-1 APIs: **route53**, **tagging.us-east-1** (installer, ingress DNS), iam.
- **S3 us-east-2** (3.5.x / 52.219.x): ignition/bootstrap and the image-registry bucket. Workers
  pulled S3 at boot.
- 1 CloudFront IP and 1 us-west-2 IP (registry node, bootstrap), probably AWS endpoints.
- Registry node 10.0.53.54: 55 connections to 18.190.44.10 (us-east-2 EC2) at 13:07, plus S3 and
  AWS APIs (that node ran openshift-install in an earlier attempt).

There are no VPC endpoints, so AWS API traffic is the bulk of the allowed egress. In a true air gap
(ISO/GovCloud with no egress), these become VPC interface endpoints (sts, ec2, elb, s3 gateway,
route53/tagging via the partition endpoints).

## Customer takeaways [INFER until lab-validated]

1. A disconnected 5.0 cluster with `disableAllDefaultSources: true` **still** has three OLM v1
   ClusterCatalogs pulling `registry.redhat.io`. Disable or delete them and apply oc-mirror's
   `cc-*.yaml`. Check whether `OperatorHub.disableAllDefaultSources` is supposed to cover OLM v1
   (possible bug or docs gap).
2. Set `image.config.openshift.io/cluster spec.additionalTrustedCA` to the mirror CA. Otherwise
   ImageStream imports fail and fall back to quay.io. install-config `additionalTrustBundle` alone
   was not enough here.
3. CVO keeps calling api.openshift.com (cluster ID in the URL). Point `spec.upstream` at OSUS or
   clear `spec.channel` to stop it.
4. Fix the Squid logformat (rename it from `squid`) so audits capture the SNI directly.
