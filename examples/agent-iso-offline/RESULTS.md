# Agent-based Installer: building the boot ISO with no internet access (OCP 5.0.0)

Lab test, 2026-11-04 (tracker items I1, I2, F1, F4). Tags: **[LAB]** observed in this lab, **[CODE]** read in
`openshift/installer` `release-5.0`, **[INFER]** conclusion not directly tested.

## Result in one paragraph

**[LAB]** An `openshift-install-fips` binary extracted from the mirrored 5.0.0 release built a bootable
Agent ISO on a host with no internet route. It read the RHCOS live ISO and stream metadata out of the
`machine-os-images` image in the mirrored payload. The Squid egress log shows **zero** connections from the
install host during either build. Both streams work: the default `rhel-10` gives an RHCOS 10.2 ISO, and
`osImageStream: rhel-9` gives an RHCOS 9.8 ISO. Both ISOs carry `fips=1`. Two prerequisites on the install
host are easy to miss: **`oc` must be on `PATH`**, and **`nmstatectl` (the `nmstate` package) must be installed**
if agent-config.yaml has `networkConfig`. If `oc` is missing, the installer silently tries to download the ISO
from `rhcos.mirror.openshift.com`.

## Environment

| Item | Value |
|---|---|
| Install host | mirror-registry node, RHEL 9.8, FIPS mode (`/proc/sys/crypto/fips_enabled` = 1), private subnet, egress only through a Squid SNI allowlist that blocks quay.io, mirror.openshift.com and rhcos.mirror.openshift.com |
| Installer | `~/bin-mirror/openshift-install-fips` 5.0.0, commit `f49486a4`, release image pinned to `<mirror>:8443/ocp5/openshift/release-images@sha256:5d7ed8b3...` |
| oc | 5.0.0 at `/usr/local/bin/oc` (also extracted from the mirror) |
| Mirror | mirror-registry (Quay), full 5.0.0 release in namespace `ocp5` (oc-mirror v2 mirror-to-mirror). The mirror root CA is in the host trust store (`/etc/pki/ca-trust/source/anchors/quay.pem`). |
| Agent cache | `~/.cache/agent` empty before the test, so nothing came from an earlier run |

How the installer was extracted (scripts/38-extract-installer.sh, I1/F1):

```bash
oc adm release extract --idms-file idms.yaml -a auth.json --certificate-authority ca.pem \
    --command=openshift-install-fips --to ~/bin-mirror \
    <mirror>:8443/ocp5/openshift/release-images:5.0.0-x86_64
```

## Inputs (redacted)

- [install-config.yaml](install-config.yaml): SNO, `platform: none`, `fips: true`, mirror pull secret, mirror CA
  in `additionalTrustBundle`, and the same three `imageDigestSources` as the working AWS install
  (`ocp-release` → `.../openshift/release-images`; `ocp-v4.0-art-dev` and `ocp-v5.0-art-dev` → `.../openshift/release`).
- [agent-config.yaml](agent-config.yaml): rendezvousIP 192.168.111.80, one master with a fake MAC and a static nmstate config.

## Run 1: default stream (rhel-10)

```bash
~/bin-mirror/openshift-install-fips agent create image --dir ~/agent-iso-test/work --log-level=debug
```

The first attempt failed in 1 s before any download:

```
level=fatal msg=failed to fetch Agent Installer ISO: ... failed to generate asset "NMState Config": staticNetwork configuration is not valid: 1 error occurred:
level=fatal msg=	* failed to validate network yaml for host 0, install nmstate package, exec: "nmstatectl": executable file not found in $PATH
```

**[LAB]** You must install `nmstate` on the install host whenever agent-config.yaml has `networkConfig`. On a
disconnected host it has to come from a local RHEL repository or Satellite. In this lab it came through RHUI
before the measured window, along with `xorriso`, which was used only to inspect the ISOs.

The second attempt succeeded: rc 0, 5 min 34 s, 10:59:26 → 11:04:59 UTC. Log excerpt (digests shortened):

```
10:59:29 level=info  msg=Extracting base ISO from release payload
         level=debug msg=extracting /coreos/coreos10-x86_64.iso to ~/.cache/agent/image_cache,
                         [oc image extract --path=/coreos/coreos10-x86_64.iso:... --filter-by-os=linux/amd64
                          --insecure=true --confirm --icsp-file=/tmp/icsp-file... quay.io/openshift-release-dev/ocp-v5.0-art-dev@sha256:4c73d478...]
11:02:02 level=info  msg=Base ISO obtained from release and cached at [~/.cache/agent/image_cache/coreos10-x86_64.iso]
11:02:03 level=debug msg=extracting /coreos/coreos10-stream.json to ~/.cache/agent/files_cache, [oc image extract ...]
         level=warning msg=base ISO version mismatch in release payload. Expected version 10.2.20261026-0 but found 10.2.20260922-0
11:04:36 level=debug msg=extracting /usr/bin/agent-tui ... ; extracting /usr/lib64/libnmstate.so.* ...
11:04:59 level=info  msg=Generated ISO at ~/agent-iso-test/work/agent.x86_64.iso.
```

| Artifact | Value |
|---|---|
| Base ISO (cache) | `coreos10-x86_64.iso`, 831,520,768 bytes, volume ID `rhcos-10.2.20260922-0` |
| Stream metadata | `coreos10-stream.json`: stream name `rhcos-4.22`, metal release `10.2.20260922-0` |
| Agent ISO | `agent.x86_64.iso`, 839,985,152 bytes (≈ 801 MiB), volume ID `rhcos-10.2.20260922-0`; `fips=1` in `/EFI/redhat/grub.cfg` |
| Squid entries from the install host, 10:59:20–11:05:10 | **0** |

## Run 2: `osImageStream: rhel-9`

The same inputs, plus `osImageStream: rhel-9` in install-config.yaml. Result: rc 0, 5 min 38 s.

```
level=debug msg=extracting /coreos/coreos-x86_64.iso to ~/.cache/agent/image_cache, [oc image extract ... ocp-v5.0-art-dev@sha256:...]
level=info  msg=Base ISO obtained from release and cached at [~/.cache/agent/image_cache/coreos-x86_64.iso]
level=warning msg=base ISO version mismatch in release payload. Expected version 9.8.20261026-0 but found 9.8.20260921-0
level=info  msg=Generated ISO at ~/agent-iso-test/work9/agent.x86_64.iso.
```

| Artifact | Value |
|---|---|
| Base ISO | `coreos-x86_64.iso`, 1,447,034,880 bytes |
| Agent ISO | 1,455,482,880 bytes (≈ 1.36 GiB), volume ID `rhcos-9.8.20260921-0`, `fips=1` |
| Squid entries from the install host | **0** |

**[LAB]** The 5.0.0 `machine-os-images` image contains both RHCOS 10 and RHCOS 9 live ISOs, and oc-mirror v2
mirrors both, so customers who pin RHCOS 9 (for example for the FIPS-validated RHEL 9 modules or for runc)
can build an agent ISO offline too.

## Run 3 (negative control): `oc` not on PATH

```bash
env PATH=/usr/bin:/bin XDG_CACHE_HOME=<empty dir> ~/bin-mirror/openshift-install-fips agent create image --dir worknooc
```

```
level=warning msg=Unable to validate mirror config because "oc" command is not available
level=warning msg=Failed to extract base ISO from release payload - check registry configuration
level=info    msg=Downloading base ISO
level=fatal   msg=... failed to download base ISO image https://rhcos.mirror.openshift.com/art/storage/prod/streams/rhel-10.2/builds/10.2.20261026-0/x86_64/rhcos-10.2.20261026-0-live-iso.x86_64.iso: ... EOF
```

The Squid log shows three blocked `CONNECT rhcos.mirror.openshift.com` from the install host in that window
(`NONE_NONE/000`). **[LAB]** Without `oc`, the installer gives only a warning and then tries the internet. On a
truly air-gapped host this fails. On a host with a partial or proxied route it would **succeed silently**
with the ISO pinned in the installer binary (10.2.20261026-0 here), not the one in your mirrored payload.
**[CODE]** `pkg/asset/rhcos/iso.go` `retrieveBaseIso()` (release-5.0): extract with `oc` from the release
payload, and on any error other than "file not found" log a warning and call `downloadIso()` using the URL from
the installer's embedded stream metadata. `pkg/asset/rhcos/releaseextract.go` calls `exec.LookPath("oc")` and
picks `/coreos/coreos10-<arch>.iso` for rhel-10 and `/coreos/coreos-<arch>.iso` for rhel-9.

## Other observations

1. **[LAB] Version mismatch warning is expected and harmless here.** The installer binary embeds RHCOS
   `10.2.20261026-0` / `9.8.20261026-0`, while 5.0.0 `machine-os-images` carries `10.2.20260922-0` /
   `9.8.20260921-0`. The installer only warns (`checkReleasePayloadBaseISOVersion`, iso.go). **[INFER]** The node
   then updates to the payload's `rhel-coreos-10` image during installation, as on the IPI cluster in this lab,
   whose nodes ran 10.2.20261027-0.
2. **[LAB] The installer warns:** `The imageDigestSources configuration in install-config.yaml should have at least one
   source field matching the releaseImage value <mirror>/...release-images@sha256:...`. The extracted installer's
   release image already points at the mirror, so this warning is cosmetic. Keep the `quay.io/...` sources as
   oc-mirror generates them: the payload's component references still resolve through the `ocp-v5.0-art-dev` mapping.
3. **[LAB] `oc image extract` is run with `--insecure=true`** (visible in the debug log). The registry TLS is
   therefore not what protects the ISO. Integrity comes from the digest-pinned `machine-os-images` reference in the
   digest-pinned release payload.
4. **[LAB] Timing.** About 2.5 min for the ISO and another 2.5 min for `coreos10-stream.json`. The stream file is
   only 30 KB, but it comes out of the same large image layer, so the layer is pulled a second time. Plan about
   6 min per stream on first use. Later runs use `~/.cache/agent`.
5. **FIPS host check.** **[CODE]** `hostcrypt.VerifyHostTargetState(c.FIPS)` runs in install-config validation
   (`pkg/types/validation/installconfig.go` L1559, release-5.0), so `agent create image` also enforces it.
   **[LAB]** On this FIPS-mode host it passed silently, with no log line. It was not tested on a non-FIPS host.
6. Disk: base ISOs are cached in `~/.cache/agent/image_cache` (0.8 GB for RHCOS 10, 1.4 GB for RHCOS 9) and
   remain after the run. Delete them, or set `XDG_CACHE_HOME`, if space or hygiene matters.

## Customer checklist (Agent ISO, disconnected)

1. Extract `openshift-install-fips` (or `openshift-install`) **from your mirror** with `oc adm release extract`
   on a FIPS-mode RHEL host. Do not use the CLI tarball from mirror.openshift.com.
2. Put a release-matched `oc` on `PATH`, extracted the same way.
3. Install `nmstate` from your local repositories if agent-config.yaml has `networkConfig`.
4. Trust the mirror CA on the host and put the mirror credentials in `pullSecret`.
5. Copy all `imageDigestSources` from oc-mirror's `idms-oc-mirror.yaml`, including `ocp-v5.0-art-dev`.
6. Check the log for `Base ISO obtained from release`. If you see `Downloading base ISO`, stop: the ISO did not
   come from your mirror.
7. Optional: pin `osImageStream: rhel-9`. This also works offline.

## Not tested

Booting the ISO and completing an agent install; a non-FIPS install host; RHEL 10 install host; IBI
(`OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE`, I3); `agent create pxe-files`; add-nodes (I4).
