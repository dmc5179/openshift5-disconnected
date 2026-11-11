# OpenShift 5.0.1 tooling on a RHEL 10 FIPS host (image mode), round 3: lab results, 2026-11-11

Round 3 repeats [RESULTS-round2.md](RESULTS-round2.md) (R2-R5) on a newly built bastion image in the new AWS
account, against the 5.0.1 mirror. It also rechecks mirror-registry now that `acl` is in the image (B-4), and
whether fapolicyd can be tested on this image (B-5). The method and commands are the same as round 2
unless a section says otherwise.

Tags: **[LAB]** observed on this host. Validate on your own build before you rely on these results.

## Summary

| # | Test | Result | Delta vs round 2 |
|---|---|---|---|
| R1 | First boot of the new AMI | **PASS**: RHEL 10.2, kernel 6.12.0-211.74.1.el10_2, `fips=1` on the kernel command line, `fips_enabled=1`, policy FIPS, OpenSSL FIPS provider 3.0.7. `/usr/local` -> `../var/usrlocal` and `/opt` -> `var/opt` are writable. All tools are present, including `acl` (`setfacl`/`getfacl`); fapolicyd is absent. SELinux enforcing. `/var` grown to 299 GB. IMDSv1 returns 401 and IMDSv2 200. cloud-init `done`, 0 failed units, 0 el10_3 packages | New: cloud-init status `done` (it was degraded by its own disk resize) and `acl` present |
| R2 | Extract `openshift-install-fips` from the mirrored **5.0.1** payload (rhel9 `oc` 5.0.1) | **PASS**: 23 s. Release 5.0.1 `sha256:a43b861d...f98a` (939 manifests). The binary reports 5.0.1, commit `8647f26b`, and is pinned to the mirror digest. `go1.26.10`, `-tags=...fipscapable,release,strictfipsruntime`. `LD_DEBUG` shows `libcrypto.so.3` and `fips.so` initialised | 5.0.0 -> 5.0.1, 31 s -> 23 s |
| R3 | CredentialsRequests from the mirror + `ccoctl aws create-all --dry-run` (rhel9 ccoctl 5.0.1) | **PASS**: 6 CredentialsRequests in 7 s (the same 6 as before). The dry run (1 s) wrote 6 roles + 6 policies, OIDC/JWKS/IdP JSON, 7 manifests and an RSA 4096 signer. No AWS credentials were present. ccoctl loads `libcrypto.so.3` + `fips.so` | Same |
| R4 | FIPS-built oc-mirror (image `openshift5/oc-mirror-plugin-rhel9:v5.0`) mirror-to-mirror into the stack Quay, org `rhel10-r6` | **PASS**: 2/2 images, mirror time 20.3 s (21 s total). ITMS only ("No images by digests were mirrored. Skipping IDMS generation."). `libcrypto.so.3` + `fips.so` loaded. Mirrored ubi9-minimal 9.9 `sha256:ecb40c7b...` and ubi10-minimal **10.3** `sha256:cc3d766e...` | Newer oc-mirror build: image `sha256:20f7c159...`, release `202611030132.p2.g4b6e461`, commit `4b6e461b`, `X:strictfipsruntime` (round 2: `202610271435.p2.ga3e6cc2`). The UBI `latest` tags moved on (9.8 -> 9.9, 10.2 -> 10.3) |
| R5 | Agent ISO offline (`agent create image`, SNO, `fips: true`, nmstate `networkConfig`) | **PASS**: run A (rhcos.mirror blocked) 176 s, run B (all Red Hat endpoints blackholed) 180 s, **0 REJECT hits** in both. Base ISO extracted from the release payload (`coreos10-x86_64.iso`, 834,666,496 bytes). Agent ISO 842,483,712 bytes, volume `rhcos-10.2.20261026-0`, `fips=1` | Faster (248/258 s -> 176/180 s). **No "base ISO version mismatch" warning any more**: the 5.0.1 payload's RHCOS (10.2.20261026-0) matches the installer's pinned stream. The imageDigestSources/releaseImage warning remains |
| B-4 | mirror-registry **2.0.12** as root under `/var/quay-root` | **PASS**: install rc 0 in 148 s with no `setfacl` error (the `acl` failure is gone). Health 200; TLS 1.3; generated CA RSA 2048 / sha256WithRSAEncryption. Survives `systemctl restart quay-app` (health 200 again after ~25 s). 0 AVCs. Uninstall rc 0 in 33 s, nothing left (0 units, pods, podman secrets; `/var/quay-root` removed) | 2.0.9 -> 2.0.12. The gevent `AssertionError` tracebacks at Quay start-up still appear (6), with no functional impact |
| B-5 | fapolicyd on this image | **NOT TESTABLE without registration** | See below |

## Environment

| Item | Value |
|---|---|
| Host | i-090f990e30e4947f9, m6i.2xlarge, public subnet of the lab VPC, 300 GB root. AMI `ami-0be7575efaf7a46ad` (`rhel10-bootc-aws-fips-bastion-20261111-074710`, account 640168434332, us-east-2, built by the composer-cli session). Booted image `localhost/rhel10-aws-fips-bastion:latest`, version 10.2 (2026-11-09). User `cloud-user` |
| Mirror | mirror-registry on the stack registry node `ip-10-0-49-224.us-east-2.compute.internal:8443`, org `ocp5` (4.22.22 + 5.0.1 + operators) |
| Clients | `oc`/`kubectl` 5.0.1 and `ccoctl` 5.0.1, rhel9 builds from `mirror.openshift.com/.../clients/ocp/5.0.1/`, sha256 checked against `sha256sum.txt`, installed in `/usr/local/bin` (left installed) |
| Inputs | IDMS built from the lab install-config `imageDigestSources` (ocp-release -> `ocp5/openshift/release-images`; ocp-v4.0-art-dev and ocp-v5.0-art-dev -> `ocp5/openshift/release`), merged mirror pull secret, mirror root CA. All copied mode 600 to `~/rtests` and deleted afterwards |

## B-5: fapolicyd on the image

The image has no fapolicyd and no repositories: it is unregistered (BYOS), and `/usr` is read-only. We did
not register the host, because that needs the organization's credentials. Checks [LAB]:

- `dnf repolist`: "No repositories available".
- The public UBI 10 repositories (`cdn-ubi.redhat.com/.../ubi10/10/x86_64/{baseos,appstream}`) are reachable
  (repomd 200) but do not contain `fapolicyd` or `fapolicyd-selinux` ("No matching Packages").

Result: **not testable on this image without registration.** Two ways to test it:
- bake fapolicyd into a test variant of the image (in the Containerfile, together with the crun rule and the
  trust file from [../fapolicyd/](../fapolicyd/));
- register a test host and use `bootc usr-overlay` plus `dnf install fapolicyd`.

The template's fapolicyd enforcing mode (`FapolicydMode enforce-with-trust`) already fails with a clear
message on image-mode hosts without fapolicyd (commit d76b464). The RHEL 10 fapolicyd results from
2026-11-06 (package-mode RHEL 10.2) still stand: [../fapolicyd/RESULTS.md](../fapolicyd/RESULTS.md).

## Notes

- R5: "Downloading base ISO" and `rhcos.mirror` appear 0 times in the run B log. `oc` 5.0.1 is on `PATH`.
- R4 cleanup: both tags were deleted with `skopeo delete`. The empty org `rhel10-r6` and its two empty
  repositories remain in Quay, like `rhel10-r4` from round 2.
- The test wrapper's `tee` into a not-yet-created log directory made the ssh exit 1 in two runs. Every test
  step itself returned rc 0.

## Cleanup state

- `~/rtests` keeps only `bin/openshift-install-fips` (5.0.1, mirror-pinned) and `bin/oc-mirror` (FIPS
  image build). The pull secret, CA, install-configs, ISOs, caches and the mirror-registry tarball are deleted.
- The mirror CA trust anchor is removed again. `/etc/hosts` is restored and 0 iptables `r6` rules remain.
- `oc`, `kubectl` and `ccoctl` 5.0.1 stay in `/usr/local/bin`.
- The host is still running (not terminated).
