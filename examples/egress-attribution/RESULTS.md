# Which cluster components call quay.io and api.openshift.com on a disconnected OpenShift 5.0.0 cluster

Lab: install 4 (2026-11-04). OpenShift 5.0.0 on AWS, in a private subnet. All egress goes through a Squid SNI
filter that blocks quay.io, registry.redhat.io and api.openshift.com. Node image pulls go to the mirror registry
through IDMS/ITMS. Tags: **[LAB]** means observed on this cluster. **[CODE]** means read in the upstream
`master` branch, so check it against the 5.0 branch before quoting it. **[INFER]** means a conclusion drawn from
timing or code, not observed directly.

## Summary

| Destination | Caller (namespace / pod / container) | Evidence | Cadence | Can a setting stop it? |
|---|---|---|---|---|
| `quay.io:443` | `openshift-controller-manager` / `controller-manager-*` (leader only) / `controller-manager`: the **`openshift.io/image-signature-import`** controller | [LAB] Packet capture on master ip-10-0-53-250 at 10:59:57Z: DNS lookups for `quay.io` from pod IP 10.130.0.101 (search domain `openshift-controller-manager.svc.cluster.local`), then 21 TCP SYNs from that pod to quay.io:443, SNATed to the node IP. Squid logged 22 blocked CONNECTs at the same second. The pod log shows the controller started at 06:59:55, and the bursts land at 06:59:57 and then at hh:59:57 every hour. [CODE] `pkg/cmd/controller/image.go`: `resyncPeriod := 1 * time.Hour` ("TODO these should really be configurable"). `signature/container_image_downloader.go` opens `image.DockerImageReference` with a nil `SystemContext`, so it ignores IDMS/ITMS and goes straight to quay.io | One burst per hour of about 2 connections for each of the 11 images in `openshift` namespace ImageStreams (22 per burst). It follows the controller-manager leader, which is why the source node changes | **No supported setting.** The resync is hard-coded and the controller has no on/off switch. The only lever is the unsupported `openshiftcontrollermanager.spec.unsupportedConfigOverrides` (controllers `["*","-openshift.io/image-signature-import"]`), which we did not test. The traffic is harmless: the call fails, signatures are not imported, and imports and pulls still work. Recommendation: allow the denial and suppress the alert, or raise an RFE/bug asking the controller to use the mirror configuration |
| `api.openshift.com:443` (`/api/accounts_mgmt/v1/subscriptions?...search=external_cluster_id=...`) | `openshift-console-operator` / `console-operator-*` / `console-operator`: the telemetry config sync | [LAB] Capture on master ip-10-0-50-65 at 11:10:07Z: lookup and SYN to api.openshift.com from pod IP 10.128.0.130 = `console-operator-b96f99c6b-ghl6d`. The operator log shows `telemetry.go:120] telemetry config error: failed to GET (https://api.openshift.com/api/accounts_mgmt/v1/subscriptions?...)` at 11:04:24, 11:10:07 and 11:15:14, which match the Squid denials exactly. Before 11:01Z the console-operator pod ran on ip-10-0-53-214, the only api.openshift.com client from 07:00 to 11:00 (every 5 min, at hh:m3:55 and hh:m8:55). When the pod was recreated on ip-10-0-50-65 at 11:01:29, the calls moved to that node. [CODE] `pkg/console/telemetry/telemetry.go`: `FailureBackoffInterval = 5 * time.Minute`. The fetch runs even with **no telemeter-client** (absent on this cluster) and **no `cloud.openshift.com` token** in the pull secret (empty token) | Every 5 min, indefinitely (after a success it would wait 24 h) | **Probably yes, day 0 or day 2 (untested):** `GetOrganizationMeta` skips the OCM call when both `ORGANIZATION_ID` and `ACCOUNT_MAIL` are set, either as annotations `telemetry.console.openshift.io/ORGANIZATION_ID` and `telemetry.console.openshift.io/ACCOUNT_MAIL` on `consoles.operator.openshift.io/cluster` or in the `openshift-console-operator/telemetry-config` ConfigMap. Test both before recommending them. Disabling console telemetry alone does not guard this code path [CODE] |
| `api.openshift.com:443` during install (06:xx) | Bootstrap node (7 calls), then masters ip-10-0-50-65 and ip-10-0-53-250 | [LAB] Squid only. [INFER] CVO update checks (Cincinnati default upstream; the CVO runs on ip-10-0-53-250) plus the console-operator telemetry call above | Until the CVO `upstream` was set to the local OSUS at about 07:00 | CVO: set `spec.upstream` to the local OSUS (day 2, done by `45-post-install.sh osus`). At day 0, leave `channel` empty until the OSUS exists (N-4) |
| `172.30.0.1:443` (no SNI, 70 connections) | Worker nodes ip-10-0-60-35 (42) and ip-10-0-56-98 (28), 06:33-06:39 only | [LAB] Squid `CONNECT 172.30.0.1:443 -`. 172.30.0.1 is the in-cluster `kubernetes` Service VIP, not an internet address. [INFER] While each worker joins, early host-network clients reach the Service VIP before ovnkube-node has programmed it. The packets follow the VPC default route to the NAT/Squid instance, which cannot forward them. They stopped once OVN was up | One-off, while workers join | Nothing to do: these are not internet calls. Squid could drop 172.30.0.0/16 (the service network) quietly to keep the log clean |
| `quay.io:443` from the install host (4 calls) | Registry node 10.0.55.212 (the install host), 05:24-06:04 | [LAB] Squid only. [INFER] Client tooling on the install host (`oc adm release extract` / `openshift-install`) probing the source registry before it uses the mirror | During installer extraction and install | Not part of the cluster. Not investigated further |

## Corrections to the earlier summary (N-10)

- The 88 quay.io denials during install were **four bursts of 22** (06:38 twice, 06:59 twice), not a 20 s cadence.
  All of them are the signature-import controller: it starts when a controller-manager takes the lease, so leader
  changes during install produce extra bursts. Since then it fires once an hour (07:59, 08:59, 09:59, 10:59) [LAB].
- After 07:00 the only api.openshift.com caller is the console-operator, not the CVO [LAB].

## Method

1. The Squid log (`/var/log/squid/access.log`), grouped by client IP, destination and minute, gave the cadence:
   hourly at hh:59:57 for quay.io, every 5 min for api.openshift.com.
2. RHCOS 10 has no `tcpdump` on the host, but the `oc debug node` tools image does. So we ran
   `oc debug node/<n> -- tcpdump -i any -nn -l '(udp port 53 and query) or (TCP SYN to external :443)'` across
   the predicted time on the node Squid named.
3. The capture shows the pod-side source IP (on the pod's veth) before OVN SNATs it to the node IP. We mapped that
   IP with `oc get pods -A -o wide`, then confirmed the caller from the pod log and the upstream source.
4. We changed no cluster configuration and restarted no pods. Debug pods were removed and no capture is left running.
   (The console-operator pod was recreated at 11:01:29Z, during the capture window, by something outside this
   investigation. That move is what tied the calls to the pod.)

## Recommendations for customers

- Expect two kinds of recurring blocked calls on a healthy disconnected 5.0 cluster: quay.io once an hour
  (image-signature-import) and api.openshift.com every 5 min (console-operator OCM subscription lookup). Both
  are harmless when blocked. Do not open firewall exceptions for them.
- To silence the console-operator call, set the telemetry organization metadata (annotations or `telemetry-config`
  ConfigMap) at day 0. This needs lab validation first.
- Point the CVO at a local OpenShift Update Service, or leave the channel empty, to stop Cincinnati calls.
- File upstream: (a) the signature-import controller should respect IDMS/ITMS or be configurable;
  (b) the console-operator should skip the OCM lookup when the pull secret has no `cloud.openshift.com` token.
