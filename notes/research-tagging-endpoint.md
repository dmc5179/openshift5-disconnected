# Research: ingress operator needs the Resource Groups Tagging API in us-east-1 (CF-17 follow-up)

Date: 2026-11-10. Sources: cluster-ingress-operator `origin/release-4.22` (b90068a5), `origin/release-5.0` (84c07fda), `origin/main` (5a204691); installer `origin/release-5.0` (8647f26b29); openshift-docs `enterprise-5.0` (4eb988c0e8); Red Hat KB via OKP; Jira (read-only).

Lab trigger (2026-11-10, 4.22.22 IPI, us-east-2, publish Internal, STS, Squid allowlist `regional`): ingress DNSReady=False / NoZones, 384 blocked CONNECTs to `tagging.us-east-1.amazonaws.com`; allowing that host fixed `*.apps` within minutes.

## Short answers

1. **Code: confirmed.** The ingress operator's AWS DNS provider pins the tagging client to the partition's Route 53 region: us-east-1 (commercial), us-gov-west-1 (GovCloud, both regions), cn-northwest-1 (China), eusc-de-east-1 (EU Sovereign). In aws-iso / aws-iso-b it has **no** tagging client and falls back to `route53:ListHostedZones` + `ListTagsForResources`. Same logic on 4.22, 5.0 and main.
2. **Zone by ID does NOT avoid the call.** `getZoneID` returns a configured ID without a lookup, but `NewProvider` always runs `validateServiceEndpoints`, which calls `tag:GetResources` whenever a tagging client exists. If that fails, provider creation fails and every DNSRecord stays NoZones. IPI installs set the private zone by **tags**. The only time they set it by **ID** is when `platform.aws.hostedZone` (BYO private zone) is set. So there is no zone-by-ID workaround. The fix is to allow the endpoint.
3. **Docs: partly covered.** The 5.0 firewall module lists `tagging.us-east-1.amazonaws.com` ("always `us-east-1`"). It does not say that the in-cluster ingress operator needs it for the life of the cluster, it has no GovCloud rows, and the AWS VPC-endpoint options ("Option 1: Create VPC endpoints") list only ec2/elb/s3 and say traffic "remains private", leaving out the global route53 and tagging endpoints. The GovCloud Route 53 module covers us-gov-west-1. KB 6753641 covers only the IAM side.
4. **Jira: no duplicate.** Related tickets: OCPBUGS-86052 (tagging in ISO regions, installer destroy), OCPBUGS-126492 (custom tagging endpoint vs global region in destroy), OCPBUGS-37932 (GovCloud NoZones, Not a Bug / not reproduced), OSDOCS-1196 (4.6 custom-endpoint docs). Nothing about the allowlist, VPC endpoints or proxy for tagging. **A docs bug is warranted** (draft: `jira/docs-draft-tagging-endpoint-allowlist.md`).

## Evidence

### Q1 code: region pinning

- [CODE] release-5.0 `pkg/dns/aws/dns.go:147-160` `partitionIDForRegion`: `us-iso-` -> aws-iso, `us-isob-` -> aws-iso-b, `us-gov-` -> aws-us-gov, `cn-` -> aws-cn, default aws.
- [CODE] release-5.0 `pkg/dns/aws/dns.go:300-338`:
  - aws-cn: `tagRegion = r53Region = "cn-northwest-1"` (L303-305).
  - aws-us-gov: `r53Region = tagRegion = "us-gov-west-1"` (L306-313), the same for us-gov-east-1 clusters.
  - aws-iso / aws-iso-b: `enableTagging = false`, `r53Region = region` (L314-318). Comment: "The resourcetagging API is not available in C2S or SC2S".
  - default: `eusc-de-east-1` for EU Sovereign (L320-329). Otherwise `tagRegion = "us-east-1"` with the comment "the Tagging API will only return hosted zone resources when the region is "us-east-1"" (L331-337).
- [CODE] release-5.0 `dns.go:339-378`: a `tagging` entry in `infrastructure.status.platformStatus.aws.serviceEndpoints` overrides the URL. It is ignored in ISO, and for us-gov-east-1 clusters it is ignored and the SDK resolves us-gov-west-1 (L355-363). The client keeps `o.Region = tagRegion` (L385-393), so a custom URL in another region is signed for the wrong region [INFER, same failure mode as OCPBUGS-126492 in the installer].
- [CODE] release-4.22 `pkg/dns/aws/dns.go:191-227`: the same switch on SDK v1 (`tagConfig.WithRegion(endpoints.UsEast1RegionID)` L223; GovCloud L195-202; ISO `tagConfig = nil` L203-207). The GovCloud custom endpoint is rewritten to `https://tagging.us-gov-west-1.amazonaws.com` when the URL contains `us-gov-east-1` (L244-250, constant L51-52).
- [CODE] main (5a204691) `dns.go:314-318`: ISO is still `enableTagging = false`. AWS has offered the tagging API in us-iso/us-isob since 2022 (OCPBUGS-86052), but the ingress operator does not use it there.
- [CODE] release-5.0 `manifests/00-ingress-credentials-request.yaml:22-31`: ingress IAM = `elasticloadbalancing:DescribeLoadBalancers, route53:ListHostedZones, route53:ListTagsForResources, route53:ChangeResourceRecordSets, tag:GetResources, sts:AssumeRole`.

### Q1 code: zone by ID versus the validation call

- [CODE] release-5.0 `dns.go:482-489` `getZoneID`: "If the config specifies the ID already, use it", so there is no tag lookup when `DNSZone.ID` is set. When it is not set, `lookupZoneID` (L517-549) calls `GetResources` with `ResourceTypeFilters: route53:hostedzone` and the zone tags.
- [CODE] release-5.0 `dns.go:443-445` + `451-473`: `NewProvider` ends with `validateServiceEndpointsFn(p)`. That function calls `route53.ListHostedZones`, `elb/elbv2.DescribeLoadBalancers` and, **if `provider.tags != nil`**, `tags.GetResources` (L466-471), and returns an error on any failure. Release-4.22 has the same at L290-292, L298-319.
- [CODE] release-5.0 `pkg/operator/controller/dns/controller.go:824-827`: a `NewProvider` error becomes "failed to create AWS DNS manager". `createDNSProviderIfNeeded` (L175, L237-279) then fails the reconcile, so the record never lands in a zone. `pkg/resources/status/status.go:108-114` then reports `NoZones` / "The record isn't present in any zones."
- [INFER] So in commercial and GovCloud the ingress operator calls the tagging endpoint even with `spec.privateZone.id` set. Zone-by-ID removes only the lookup, not the reachability requirement. This matches the lab: route53 succeeded, tagging was blocked, NoZones, and repeated CONNECT retries (384) from provider re-creation on each reconcile.
- [CODE] installer release-5.0 `pkg/asset/manifests/dns.go:115-121`: with no `platform.aws.hostedZone`, the private zone is `DNSZone{Tags: {kubernetes.io/cluster/<infraID>: owned, Name: <infraID>-int}}`. With `hostedZone` set it is `DNSZone{ID: hostedZone}` (+ `PrivateZoneIAMRole` from `hostedZoneRole`). The public zone (publish External only) is always by ID (L100-114). `userProvisionedDNS: Enabled` sets neither (L95-98).
- [CODE] installer release-5.0 `pkg/asset/installconfig/aws/endpoints.go:30-39`: `tagging` is an accepted `platform.aws.serviceEndpoints` name. It is passed to the cluster through the infrastructure status and read by the ingress operator (controller.go:776-817).
- [CODE, side note] installer release-5.0 `pkg/destroy/aws/aws.go:268-291`: `destroy cluster` adds a second tagging client in the global region (us-east-1 / us-gov-west-1 / cn-northwest-1) only when `hostedZoneRole` is set. The base tagging client uses the install region (L259-266), so a regional allowlist covers it.

### Q2 docs (enterprise-5.0 @ 4eb988c0e8)

- [DOC-preview] `modules/configuring-firewall-module.adoc:235-239`: `*.amazonaws.com`, "Alternatively, if you choose to not use a wildcard for AWS APIs, you must include the following URLs". L281-283: "`tagging.us-east-1.amazonaws.com` | 443 | Used to install and manage clusters in an AWS environment. This endpoint is always `us-east-1`, regardless of the region the cluster is deployed in." L297-299: `tagging.<aws_region>.amazonaws.com`. Missing from this table:
  - the statement that the in-cluster ingress operator needs the endpoint permanently to publish `*.apps` (and that the install fails with NoZones without it);
  - GovCloud equivalents (`route53.us-gov.amazonaws.com`, `tagging.us-gov-west-1.amazonaws.com`); `grep -i 'us-gov\|govcloud'` finds 0 hits in the module;
  - China and ISO notes (ISO needs no tagging; Route 53 is regional there).
- [DOC-preview] `modules/installation-custom-aws-vpc.adoc:115-187` (included in the private, VPC and restricted-network AWS books): "If you are working in a disconnected environment, you are unable to reach the public IP addresses for EC2, ELB, and S3 endpoints". "Option 1: Create VPC endpoints" lists only `ec2`, `elasticloadbalancing`, `s3` (L127-131) and says "With this option, network traffic remains private between your VPC and the required AWS services" (L151). Option 3 (proxy + VPC endpoints, L160-187) has the same list. Nothing says that Route 53 and the Resource Groups Tagging API (us-east-1) must still be reachable through the proxy, or that IAM/STS are needed for Mint mode. The same 3-endpoint list is in `modules/installation-aws-user-infra-other-infrastructure.adoc:24-45` (UPI).
- [DOC-preview] `modules/nw-endpoint-route53.adoc:12-14, 36-37, 44` (GovCloud, included by `installing/installing_aws/installing-aws-account.adoc:16`): "the Ingress Operator uses `us-gov-west-1` region for Route53 and tagging API clients", example `serviceEndpoints` with `tagging: https://tagging.us-gov-west-1.amazonaws.com`. Good for GovCloud, but framed as custom-endpoint config, not as egress. Small inaccuracy for 5.0: L14 describes the 4.22 substring rewrite. On 5.0 a custom tagging URL is ignored for us-gov-east-1 clusters and the SDK resolves us-gov-west-1 (dns.go:355-363). The effective endpoint is the same.
- [DOC-preview] No hits for "Resource Groups Tagging" / "tagging API" in the AWS install books, apart from a UPI CLI example (`modules/installation-aws-provisioning-dns-records.adoc:44`, `aws resourcegroupstaggingapi get-resources`).
- [DOC] KB 6753641 "ingress degraded during IPI installation when deploying the cluster in a specific AWS region" (unverified): NoZones because the IAM user lacks `tag:GetResources` in us-east-1. IAM only, nothing on egress. KB 7076998 (ROSA HCP): same symptom, missing `tag:GetResources` in the SCP; log line `failed to get group tagging resources`. KB 5026501: private-only network NoZones from a wrong publish scope (unrelated). No KB found about a proxy or firewall blocking `tagging.us-east-1`.

### Q3 Jira (read-only, searched 2026-11-10)

| Key | Status | Note |
|---|---|---|
| OCPBUGS-86052 | ASSIGNED | Tagging API in ISO regions (installer destroy, IAM permission guard). Ingress operator not covered. |
| OCPBUGS-126492 | POST | Installer destroy: a custom `tagging` endpoint in the install region conflicts with the global-region client (URL vs signing region). Same root cause as why a regional custom tagging URL cannot replace us-east-1. |
| OCPBUGS-37932 | Closed, Not a Bug | GovCloud restricted install, `*.apps` NoZones. Not reproduced; the cause was never found (plausibly the same egress issue [INFER]). |
| OCPBUGS-38034 | Closed, Not a Bug | GovCloud destroy failure (companion to -37932). |
| OSDOCS-1196 | Closed (4.6) | Docs for custom route53/tagging endpoints (NE-300). Comments note route53/tagging must be us-east-1. |
| NE-326 | Closed | AWS custom endpoints and air-gapped regions (feature). |
| RFE-2589 | Closed, Won't Do | Destroy in AWS private regions. |

Searches: text "tagging.us-east-1", "resourcegroupstaggingapi", "tagging api", "tagging endpoint", "NoZones" + proxy/allowlist/firewall/VPC endpoint/tagging, "tagging" + "VPC endpoint" (OCPBUGS/OSDOCS/RFE/NE/OCPSTRAT/CORS), and OSDOCS firewall/allowlist + AWS (last 3 years; only ROSA tickets). **No existing ticket for the docs gap.**

## (a) Customer guidance text

> **Route 53 and Resource Groups Tagging API egress (AWS IPI, all publish modes).** The Ingress Operator creates the `*.apps` record in the cluster's private hosted zone. It finds the zone with the Resource Groups Tagging API and checks that endpoint every time it starts its DNS provider, so it needs it for the life of the cluster, not only during installation. Route 53 and the tagging lookup are global services pinned to one region per partition. Allow them through your proxy or firewall in addition to your regional endpoints:
>
> | Partition | Allow (HTTPS 443) |
> |---|---|
> | Commercial (`aws`) | `route53.amazonaws.com`, `tagging.us-east-1.amazonaws.com` (whatever region the cluster is in) |
> | GovCloud (`aws-us-gov`, us-gov-west-1 and us-gov-east-1) | `route53.us-gov.amazonaws.com`, `tagging.us-gov-west-1.amazonaws.com` |
> | China (`aws-cn`) | `route53.amazonaws.com.cn`, `tagging.cn-northwest-1.amazonaws.com.cn` |
> | ISO / ISO-B | No tagging endpoint is used. The operator lists hosted zones through the region's Route 53 endpoint (`route53.<region>.c2s.ic.gov` / `.sc2s.sgov.gov`; supply it with `platform.aws.serviceEndpoints` if required). |
>
> Regional VPC interface endpoints do not replace these, because the cluster region's tagging endpoint does not return Route 53 hosted zones. A cluster in us-east-1 (or us-gov-west-1) can use a `tagging` interface endpoint with private DNS in its own region [INFER, untested]. If these hosts are blocked, installation stops with `ingress` DNSReady=False, reason `NoZones` ("The record isn't present in any zones"), and the ingress-operator log shows `failed to validate aws provider service endpoints ... failed to get group tagging resources`. The ingress role also needs `tag:GetResources` (KB 6753641).
>
> **Zone by ID is not a workaround.** Setting `platform.aws.hostedZone` (or `dns.config.openshift.io/cluster spec.privateZone.id`) skips the tag lookup, but the operator still calls `tag:GetResources` to validate the endpoint at start-up, so the endpoint must still be reachable (cluster-ingress-operator release-5.0 `pkg/dns/aws/dns.go:443-471`). The only configuration that avoids the tagging API is `platform.aws.userProvisionedDNS: Enabled`, where you create the DNS records yourself. That one is untested here; it is a separate feature with its own requirements (see OCPBUGS-78093 for ISO).

Status: lab-validated for commercial us-east-2 on 4.22.22 (allowing `tagging.us-east-1.amazonaws.com` fixed the install). The GovCloud, China and ISO rows are from code only [CODE]. The ingress code is the same on 4.22 and 5.0, so it applies to 5.0 [INFER].

## (b) Docs ticket

Warranted: the firewall row exists, but the VPC-endpoint "disconnected" options mislead (they list only ec2/elb/s3 and say traffic stays private), the firewall table has no GovCloud rows and does not say the endpoint is a permanent in-cluster requirement, and the only GovCloud coverage is framed as custom-endpoint config. Draft: `jira/docs-draft-tagging-endpoint-allowlist.md`.
