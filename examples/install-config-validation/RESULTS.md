# D7: offline validation of the example install-configs with the real 5.0.0 installer

Date: 2026-11-04. Workstation (Fedora 44, not FIPS), no AWS credentials, nothing touched in AWS.

- Installer: `openshift-install 5.0.0`, commit f49486a4, extracted with
  `bin/oc adm release extract --command=openshift-install quay.io/openshift-release-dev/ocp-release:5.0.0-x86_64`
  (release digest sha256:5d7ed8b3...).
- Dummy values (`prep-dummy-values.py`): pull secret `{"auths":{"example.com":...,"registry.example.com:8443":...}}`,
  a throwaway ed25519 key (RSA 3072 for the FIPS cases), and a self-signed dummy CA from `certtool`
  (the workstation has no `openssl`). `<local_registry>/<local_repository_name>` became `registry.example.com:8443/ocp5`.
- Agent runs need `nmstatectl` whenever agent-config has `networkConfig`. Without it they fail with
  `failed to validate network yaml for host 0, install nmstate package`. They ran in a Fedora 44 container with
  nmstate 2.2.57 (`Containerfile.nmstate`).
- AWS runs: `AWS_CONFIG_FILE`/`AWS_SHARED_CREDENTIALS_FILE` pointed to nonexistent files, IMDS disabled, stdin closed.
- FIPS configs on a non-FIPS host: `OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=1` was used to get past the host check.
- Logs (ANSI stripped): `logs/`. Scratch dirs: `/tmp/g4-val/` (not kept).

## Results

| # | File | Check | Result | Fix needed |
|---|---|---|---|---|
| 1 | `examples/install-config-agent-baremetal-5.0.yaml` + `examples/agent-config-5.0.yaml` | `agent create cluster-manifests` | **PASS** [LAB]. Warnings: `imageContentSources is deprecated, please use ImageDigestSources`; `hosts[0].interfaces[0/1].name: interface name "enp0s4"/"enp0s5" not found in networkConfig interfaces [bond0.300 bond0]` (expected for a bond; the doc sample produces the same warning). The capabilities override (incl. CompatibilityRequirements, ClusterAPI) is copied verbatim into the AgentClusterInstall `install-config-overrides` annotation. `mirror/registries.conf` maps ocp-release and ocp-v5.0-art-dev. | **Yes, 3 fixes:** (a) remove `CompatibilityRequirements` and `ClusterAPI` from `additionalEnabledCapabilities` (I-10: the Default ClusterVersion CRD accepts neither, so the install stalls at bootstrap; the installer does not catch it); (b) rename `imageContentSources` to `imageDigestSources` (same shape, removes the warning; verified in run 2); (c) **network mismatch:** agent-config `rendezvousIP: 10.10.10.14` / host address 10.10.10.14/24 is outside install-config `machineNetwork 192.168.0.0/16`. `cluster-manifests` does not check this, but an SNO node must be in the machine network [INFER]. Set `machineNetwork` to `10.10.10.0/24` (verified in run 2). |
| 2 | same pair with fixes (b) and (c) applied and `osImageStream: rhel-9` uncommented | `agent create cluster-manifests` | **PASS** [LAB]. No deprecation warning. `"osImageStream":"rhel-9"` is carried in the ACI overrides (only when it differs from the rhel-10 default; installer `pkg/asset/agent/manifests/agentclusterinstall.go:418` release-5.0). | - |
| 3 | `examples/install-config-agent-baremetal-5.0.yaml` (platform none) | `create manifests` (non-agent) | **PASS** [LAB]. `manifests/cvo-overrides.yaml` contains `baselineCapabilitySet: None` plus all 18 listed capabilities **including CompatibilityRequirements and ClusterAPI**. This reproduces the I-10 trap offline: the installer accepts them, and the cluster rejects them later. | Fix (a) as above. |
| 4 | `examples/agent-iso-offline/install-config.yaml` + `agent-config.yaml` (SNO, `fips: true`, imageDigestSources incl. ocp-v4.0 and ocp-v5.0-art-dev) | `agent create cluster-manifests` | **PASS** [LAB] with an RSA key and the hostcrypt bypass. First run with an ed25519 key: **FAIL** `sshKey: ... SSH key type ssh-ed25519 unavailable when FIPS is enabled. Please use rsa or ecdsa.`, plus `fips: Forbidden: target cluster is in FIPS mode, use the FIPS-capable installer binary for RHEL 9 on a host with FIPS enabled` (expected on a non-FIPS host). ACI overrides `{"fips":true,"additionalTrustBundlePolicy":"Always"}`. This file has no `capabilities` block, so Insights stays on (vCurrent). | No change needed for a lab file. Optional: add a comment that `sshKey` must be RSA/ECDSA when `fips: true`. |
| 5 | `examples/install-config-aws-5.0.yaml` | `create manifests`, no AWS credentials | **Static validation PASSES; stops at the AWS API** [LAB]: `controlPlane.platform.aws: Internal error: failed to create EC2 client: EOF` (the installer asks for an AWS Access Key ID; stdin was closed). Proof that static validation (`ValidateInstallConfig`, which includes the capability rules) runs first and passes: negative controls 5a/5b fail in that step with clear errors before any AWS call. Order: `pkg/asset/installconfig/installconfig.go:248` (static) then `:255` (platformValidation needs EC2) on release-5.0. | **Yes:** (a) remove `CompatibilityRequirements` and `ClusterAPI` (same I-10 trap: static validation accepts them); (b) the header says it is not a disconnected sample. Fine as documented, but customers copying it get no `imageDigestSources`/`additionalTrustBundle`/`publish: Internal`. Consider pointing to the rendered generator output as the disconnected AWS example. |
| 5a | AWS example + bogus capability `Bogus` (negative control) | `create manifests` | FAIL as expected, before the EC2 call: `capabilities.additionalEnabledCapabilities[18]: Unsupported value: "Bogus": supported values: "Build", "CSISnapshot", "CloudControllerManager", "CloudCredential", "ClusterAPI", "CompatibilityRequirements", ...` (19 values, union of all vendored capability sets). | - |
| 5b | AWS example without `CloudCredential` (negative control) | `create manifests` | FAIL as expected: `disabling CloudCredential capability available only for baremetal platforms`. | - |
| 6 | Rendered generator output `install-config.yaml` (repo root, 2026-11-04 10:54, read-only copy; AWS, BYO private subnet, publish Internal, `credentialsMode: Manual`, `fips: true`, `osImageStream: rhel-10`, 3 imageDigestSources, 15 capabilities without Insights, samples, CompatibilityRequirements and ClusterAPI) | `create manifests`, no AWS credentials | **Stops before static validation** [LAB]: `unable to load edge subnets: error retrieving Edge Subnets: failed to create EC2 client: EOF`. With `platform.aws.vpc.subnets` set, `finishAWS()` queries EC2 for Local Zone subnets **before** `ValidateInstallConfig` (`pkg/asset/installconfig/installconfig.go:197-213` then `:248`, release-5.0). So the FIPS host check does not run either. | None for the file. Note for testing: a BYO-VPC AWS config cannot be statically validated offline as is. |
| 6a | Rendered output with `vpc.subnets` removed (test-only variant, real RSA key kept) | `create manifests` | Without the bypass: `fips: Forbidden: target cluster is in FIPS mode, use the FIPS-capable installer ...` (expected: non-FIPS host). With `OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=1`: **static validation PASSES**, stops at `failed to create EC2 client: EOF`. Only warning: `Mirror registry "ip-10-0-55-212...:8443" is not found in pullSecret` (artifact of the dummy pull secret). The real file also installed clusters (I-13, I-14, install 4). | - |

## Capability findings (cross-check with I-10 / I6)

- The 5.0.0 installer accepts any capability that appears in any vendored set, which is 19 names including
  CompatibilityRequirements and ClusterAPI (`validateCapabilities`, `pkg/types/validation/installconfig.go:1575-1599`, release-5.0) [CODE][LAB].
- The 5.0.0 ClusterVersion CRD for the **Default** feature set (taken from the CVO image
  `ocp-v5.0-art-dev@sha256:363cd1db...`, `/manifests/0000_00_cluster-version-operator_01_clusterversions-Default.crd.yaml`)
  accepts **17** values for `additionalEnabledCapabilities` and not CompatibilityRequirements or ClusterAPI.
  TechPreviewNoUpgrade, DevPreviewNoUpgrade and CustomNoUpgrade accept 19. `baselineCapabilitySet` accepts
  `None, v4.11 ... v4.18, vCurrent` on all feature sets, so **there is no `v5.0`** [LAB].
  (AGENTS.md I-10 says "16 values" but lists 17 names; the CRD has 17. The error index `[16]` is the 17th list entry.)
- So both doc-derived examples (`install-config-agent-baremetal-5.0.yaml`, `install-config-aws-5.0.yaml`) would
  stall a Default-feature-set install exactly like I-10. `scripts/generate-install-config.sh` already excludes them.

## Proposed fixes (not applied; the examples are owned elsewhere)

1. `examples/install-config-agent-baremetal-5.0.yaml`: delete `- CompatibilityRequirements` and `- ClusterAPI` and add a comment pointing to I-10 / OCPBUGS-136614. Change `imageContentSources:` to `imageDigestSources:`. Change `machineNetwork` to `10.10.10.0/24` to match `agent-config-5.0.yaml` (or change the agent-config IPs). Also correct the comment "List = 5.0 vCurrent MINUS Insights": vCurrent in the vendored API includes the two TechPreview-only capabilities, so the list must be the Default CRD enum minus Insights.
2. `examples/install-config-aws-5.0.yaml`: delete `- CompatibilityRequirements` and `- ClusterAPI` and fix the same comment.
3. Optional: `examples/agent-iso-offline/install-config.yaml`: comment that `sshKey` must be RSA or ECDSA with `fips: true`.
4. Optional: in both doc-derived examples, consider also dropping `openshift-samples` for disconnected use (N-8), as the generator does.

## Reproduce

```
bin/oc adm release extract --command=openshift-install --to /tmp/g4-bin quay.io/openshift-release-dev/ocp-release:5.0.0-x86_64 -a secrets/pull-secret.json
python3 -I examples/install-config-validation/prep-dummy-values.py <example> /tmp/x/install-config.yaml   # expects keys in /tmp/g4-val/keys
podman build -t localhost/g4-nmstate -f examples/install-config-validation/Containerfile.nmstate .
podman run --rm --security-opt label=disable -v /tmp/g4-bin:/b:ro -v /tmp/x:/w -w /w localhost/g4-nmstate /b/openshift-install agent create cluster-manifests --dir .
AWS_CONFIG_FILE=/nonexistent AWS_SHARED_CREDENTIALS_FILE=/nonexistent AWS_EC2_METADATA_DISABLED=true /tmp/g4-bin/openshift-install create manifests --dir /tmp/x < /dev/null
```
