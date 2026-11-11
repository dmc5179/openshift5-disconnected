# Offline must-gather (2026-11-11) [LAB]

Run on the disconnected 5.0.1 cluster (upgraded from 4.22.22; FIPS; mirror registry + Squid allowlist):
`oc adm must-gather --dest-dir ~/mg` from the registry node.

- **PASS: rc 0 in 111 s, 239 MB.** The default image comes from the `openshift/must-gather` ImageStream: `quay.io/openshift-release-dev/ocp-v5.0-art-dev@sha256:90f3f526...`. It was pulled through the mirror (IDMS `ocp-v5.0-art-dev` mapping), as was the low-level tools image. No extra mirroring is needed.
- **Squid during the run:** only AWS API calls (S3 image-registry bucket, STS, EC2). No Red Hat or other internet destinations, **0 denials**.
- **Expected noise:**
  - "the server doesn't have a resource type" for KubeVirt / MTV / multi-networkpolicy (not installed);
  - `clusteroperator/insights is missing` (Insights capability disabled);
  - a tar warning.
- **Customer note:** `oc adm must-gather` works unchanged in a mirrored 5.0 cluster as long as the release payload is mirrored with the `ocp-v5.0-art-dev` mapping. Product-specific must-gather images (ODF, OpenShift Virtualization, Lightspeed) must be mirrored separately (additionalImages or their operator catalogs) and passed with `--image`.
- **Not tested:** product-specific images. Gathering while the API is degraded failed before the fix: `oc debug` fell back to `registry.redhat.io` while the image API was down.
