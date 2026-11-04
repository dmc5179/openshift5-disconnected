# OpenShift 5.0 tooling on a RHEL 10 FIPS host (image mode) - lab results, 2026-11-04

Can a RHEL 10 host in FIPS mode serve as the bastion and mirror registry for a disconnected
OpenShift 5.0 install? This test runs the published OpenShift 5.0.0 clients (only RHEL 9 builds
exist), the FIPS-capable oc-mirror and mirror-registry on RHEL 10.2 with FIPS enabled at
installation. Every result here comes from one lab host [LAB]. Validate it on your own build
before you rely on it.

## Summary

| # | Test | Result |
|---|---|---|
| 1 | Baseline: RHEL 10.2 image mode, FIPS from installation | **PASS**: `fips_enabled=1`, policy `FIPS`, `fips=1` on the kernel command line, OpenSSL FIPS provider active, no `fips-mode-setup` |
| 2 | RHEL 9 builds of `oc`, `kubectl`, `openshift-install-fips`, `ccoctl` on RHEL 10 FIPS | **PASS**: all resolve their libraries, start, and load `/lib64/libcrypto.so.3` and the OpenSSL FIPS module. `oc adm release info` over TLS works |
| 2b | CDN `oc-mirror` 2.0.0 on RHEL 10 FIPS | **RUNS, NOT FIPS**: static Go binary (`CGO_ENABLED=0`). It never loads the system OpenSSL FIPS module (OCPBUGS-136646) |
| 3 | `openshift-install-fips create manifests` with `fips: true` on RHEL 10 | **PASS**: the host check accepts RHEL 10, and FIPS MachineConfigs are rendered for both pools |
| 4 | FIPS-built `oc-mirror` 5.0.0 from `registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0` | **PASS**: dynamically linked, `X:strictfipsruntime`, loads libcrypto and `fips.so` |
| 5 | mirror-registry 2.0.9 (Quay 3.12.12) on bootc RHEL 10 FIPS, as root | **PASS with a path change**: `/opt` is read-only, so it was installed under `/var/quay-root`. Health returns 200, and it survives `systemctl restart quay-app`. The TLS certificate is RSA 2048 / SHA-256, and the connection uses TLS 1.3 |
| 6 | Mirror-to-mirror of 5.0.0 with the FIPS oc-mirror into that Quay | **PASS**: 199/199 images in 8 min 32 s, IDMS/ITMS/signature ConfigMap/UpdateService generated |
| 7 | Same image set config with the CDN 2.0.0 build, `--dry-run` | **PASS**: 199 images planned in 18 s. The IDMS is identical to the FIPS build's. The dry run still pushed `graph-image:latest` |
| - | Stack user data (`cloudformation/disconnected_vpc_plus.yaml`) on an image-mode host | **WOULD FAIL** as written: it relies on `dnf`, `wget`, `/usr/local/bin`, `/opt/quay-root` and the AWS CLI installer into `/usr/local`. See "Caveats" |

**Bottom line [LAB]:** The RHEL 9 builds of the OpenShift 5.0.0 clients run unchanged on a RHEL 10.2
FIPS host and use the system OpenSSL FIPS provider. `openshift-install-fips` accepts the host.
mirror-registry runs on bootc RHEL 10 with rootful podman, and the FIPS build of oc-mirror mirrors
a full 5.0.0 release into it. Two things are missing: RHEL 10 builds of the clients, and a
FIPS-capable oc-mirror on the CDN. To mirror in FIPS mode, extract oc-mirror from the container image.

## How the host was built

| | |
|---|---|
| OS | Red Hat Enterprise Linux 10.2 (Coughlan), kernel `6.12.0-211.68.1.el10_2.x86_64` |
| Image | **Image mode (bootc).** Built with RHEL image builder from a FIPS blueprint as `localhost/rhel10-aws-fips:latest` (image timestamp 2026-10-27). Exported as an AMI in us-east-1 and copied to us-east-2. `bootc status`: store `ostreeContainer`, no staged update |
| FIPS | Enabled at installation (the only way on RHEL 10; there is no `fips-mode-setup`). `/proc/sys/crypto/fips_enabled` = 1, `update-crypto-policies --show` = `FIPS`, `fips=1` on the kernel command line |
| Root filesystem | composefs, read-only (`/`, `/usr`, `/usr/local`, `/opt`). Writable: `/etc`, `/var` (292 GB free), `/home` -> `/var/home`, `/root` -> `/var/roothome` |
| Instance | m6i.2xlarge (8 vCPU, 30 GiB), 300 GB gp3, public subnet of the lab VPC with direct internet egress |
| Key packages | openssl-libs 3.5.8-2.el10_2, **openssl-fips-provider 3.0.7-11.el10_2**, glibc 2.39-145.el10_2, podman 5.8.2-11.el10_2, crun 1.30.1-2.el10_2, systemd 257-23.el10_2.2, selinux-policy-targeted 42.1.18-4.el10_2.4, container-selinux 2.248.0-1.el10_2, skopeo 1.22.2, jq 1.7.1, curl 8.12.1 |
| Security | SELinux enforcing, cgroup v2, fapolicyd not installed, firewalld inactive |

Reference host for side-by-side checks: the lab's RHEL 9.8 bastion, FIPS enabled with `fips-mode-setup`.

## Test 1 - Baseline

| Check | Command | RHEL 10.2 result |
|---|---|---|
| FIPS kernel flag | `cat /proc/sys/crypto/fips_enabled` | `1` |
| Crypto policy | `update-crypto-policies --show` | `FIPS` |
| Kernel command line | `cat /proc/cmdline` | contains `fips=1` |
| OpenSSL | `openssl version` | `OpenSSL 3.5.8 25 Aug 2026` |
| Providers | `openssl list -providers` | `base`, `default` and `fips` all `active`. The fips provider reports **`Red Hat Enterprise Linux 9 - OpenSSL FIPS Provider`, version `3.0.7-cda111b5812c30d4`** |
| `fips-mode-setup` | `command -v fips-mode-setup` | not present (expected on RHEL 10) |
| Write to `/usr` | `touch /usr/test`, `sudo touch /usr/local/bin/x`, `sudo mkdir /opt/quay-root` | all fail with `Read-only file system` |

**Note [LAB]:** The FIPS provider on RHEL 10.2 is the same module and version that the RHEL 9.8
bastion reports: `Red Hat Enterprise Linux 9 - OpenSSL FIPS Provider` 3.0.7-cda111b5812c30d4. The
RHEL 10 OpenSSL 3.5 library loads the RHEL 9 FIPS provider build. This matters for questions about
FIPS 140-3 validation status (tracker F3): the crypto boundary that the OpenShift clients use on
this host is the RHEL 9 provider.

**Image-mode note [LAB]:** In this image, `/usr/local` is part of the read-only image. It is not
linked to `/var/usrlocal` (that directory exists but is empty and not used). Third-party binaries
therefore cannot go into `/usr/local/bin` unless the image is built that way. Options:
- `~/.local/bin`, which is on the user's PATH. This test uses it.
- A directory under `/var`.
- Bake the binaries into the bootc image.
- `bootc usr-overlay`, which is transient and lost at reboot.

`sudo`'s `secure_path` does not include `/usr/local/bin` either.

## Test 2 - RHEL 9 client builds on RHEL 10 FIPS (tracker B-2, F2)

Downloaded from `https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/5.0.0/`
(`openshift-client-linux-amd64-rhel9-5.0.0.tar.gz`, `openshift-install-rhel9-amd64.tar.gz`,
`ccoctl-linux-rhel9-5.0.0.tar.gz`; all three passed `sha256sum -c` against `sha256sum.txt`) and
`https://mirror.openshift.com/pub/cgw/oc-mirror/latest/oc-mirror-rhel9-linux-amd64.tar.gz`.
No RHEL 10 builds are published. Installed into `~/.local/bin`.

Build info (`go version -m <binary>`):

| Binary | Version | Go | CGO_ENABLED | GOEXPERIMENT / tags |
|---|---|---|---|---|
| `oc` | 5.0.0 | go1.26.10 (Red Hat 1.26.10-1.el9_8) | 1 | `strictfipsruntime` |
| `kubectl` | v1.36.2 (same binary as `oc`) | go1.26.10 | 1 | `strictfipsruntime` |
| `openshift-install-fips` | 5.0.0 (commit f49486a4) | go1.26.10 | 1 | `strictfipsruntime`; tags `baremetal,fipscapable,release,strictfipsruntime` |
| `ccoctl` | 5.0.0 | go1.26.10 | 1 | `strictfipsruntime` |
| `oc-mirror` (CDN) | 2.0.0-202610201601.p2.gc4d52fa | go1.26.5 (Red Hat 1.26.5-1.el9_8) | **0** | none |

Runtime on RHEL 10.2 FIPS:

| Binary | `ldd` | `version` | libcrypto loaded (`LD_DEBUG=libs`) | Strict-FIPS start-up error? |
|---|---|---|---|---|
| `oc` | `libresolv.so.2`, `libc.so.6`, all resolved | `Client Version: 5.0.0` | `calling init: /lib64/libcrypto.so.3` | no |
| `kubectl` | same | `Client Version: v1.36.2` | yes | no |
| `openshift-install-fips` | same | `openshift-install-fips 5.0.0` | yes | no |
| `ccoctl` | same | `--help` OK | yes | no |
| `oc-mirror` (CDN) | `not a dynamic executable` | `2.0.0-...el9-c4d52fa` | **no** | n/a (not a strict-FIPS build) |

`libcrypto.so.3` is opened with `dlopen` (golang-fips/openssl), so `ldd` does not list it. Use
`LD_DEBUG=libs` to confirm it is loaded.

TLS action:

```
$ oc adm release info quay.io/openshift-release-dev/ocp-release:5.0.0-x86_64 -a ~/pull-secret.json | head
Name:           5.0.0
Digest:         sha256:5d7ed8b3e98bc3a10c50f36f07262a962d59ad2d3ea5fb4935ff10c408c02e55
Created:        2026-10-29T16:05:03Z
OS/Arch:        linux/amd64
Manifests:      936
...
$ LD_DEBUG=libs oc adm release info ... 2>&1 >/dev/null | grep 'calling init'
calling init: /lib64/libcrypto.so.3
calling init: /usr/lib64/ossl-modules/fips.so
```

**Result: PASS [LAB].** The RHEL 9 builds run on RHEL 10.2 without any compatibility packages:
glibc 2.39 is backward compatible, and `libcrypto.so.3` keeps the same soname. The strict-FIPS
builds start in FIPS mode and perform TLS through the system OpenSSL FIPS provider.

## Test 3 - `openshift-install-fips` host check (tracker F2)

The lab's real install-config was used: `fips: true`, `publish: Internal`, `credentialsMode: Manual`,
`osImageStream: rhel-10`, mirror IDMS. AWS credentials were set in the environment.

```
$ openshift-install-fips create manifests --dir /var/tmp/ic-test --log-level info
level=info msg=Credentials loaded from the AWS config using "EnvConfigCredentials" provider
level=info msg=Consuming Install Config from target directory
...
level=info msg=Manifests created in: /var/tmp/ic-test/cluster-api, /var/tmp/ic-test/manifests and /var/tmp/ic-test/openshift
rc=0   (1.8 s)
```

The output includes `openshift/99_openshift-machineconfig_99-master-fips.yaml` and `...99-worker-fips.yaml`,
both with `fips: true`, and `99_osimagestream.yaml`.

**Result: PASS [LAB].** The host check
(`pkg/hostcrypt`, installer `release-5.0`) only reads `/proc/sys/crypto/fips_enabled`. It does
not check the RHEL major version, so a RHEL 10 FIPS host qualifies. `create cluster` was not run
on this host. A full FIPS install from a RHEL 9 FIPS host is covered in `examples/install-results/`.
The temporary directory and credentials were deleted afterwards.

## Test 4 - FIPS-built oc-mirror from the container image (OCPBUGS-136646 workaround)

```
$ oc image extract registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0 -a ~/pull-secret.json \
    --filter-by-os=linux/amd64 --path /usr/bin/oc-mirror.rhel9:. --confirm      # 25 s
```

| | Container-image build | CDN build (for comparison) |
|---|---|---|
| Image | digest `sha256:c259dcb3...6855`, label `version=v5.0.0`, `release=202610271435.p2.ga3e6cc2.assembly.stream.el9` | `oc-mirror-rhel9-linux-amd64.tar.gz` |
| Version | `5.0.0-202610271435.p2.ga3e6cc2.assembly.stream.el9-a3e6cc2` | `2.0.0-202610201601.p2.gc4d52fa.assembly.stream.el9-c4d52fa` |
| Go | `go1.26.10 (Red Hat 1.26.10-1.el9_8) X:strictfipsruntime` | `go1.26.5 (Red Hat 1.26.5-1.el9_8)` |
| Linking | dynamic (`libresolv`, `libc`) | static |
| libcrypto / fips.so loaded | yes / yes (already at `version`) | no / no |
| sha256 | `70eab4d5...70c7` | `b9a0702a...56c3` |

**Result: PASS [LAB].** The image build is the FIPS-capable oc-mirror and runs on RHEL 10.2 FIPS.
The CDN build also runs, but its cryptography is Go-native and does not use the RHEL FIPS module,
on RHEL 10 as on RHEL 9.

## Test 5 - mirror-registry on bootc RHEL 10 FIPS (tracker B-4, M6)

mirror-registry 2.0.9 was downloaded the same way the stack template does it
(`https://developers.redhat.com/content-gateway/file/pub/cgw/mirror-registry/2.0.9/mirror-registry-amd64.tar.gz`).
`./mirror-registry --version` reports 2.0.9.

```
$ sudo mkdir -p /opt/quay-root
mkdir: cannot create directory '/opt/quay-root': Read-only file system     # template path does not work
$ sudo ./mirror-registry install --quayHostname $(hostname -f) \
    --quayRoot /var/quay-root --quayStorage /var/quay-root/data --sqliteStorage /var/quay-root/sqlite
...
PLAY RECAP: ok=50 changed=29 unreachable=0 failed=0 skipped=14
Quay installed successfully, config data is stored in /var/quay-root
Quay is available at https://<host>:8443 with credentials (init, <redacted>)
rc=0   (119 s)
```

| Check | Result |
|---|---|
| Installer SSH bootstrap | It generated `/root/.ssh/quay_installer` (**RSA 2048**, acceptable in FIPS) and added it to root's `authorized_keys`. sshd (`PermitRootLogin prohibit-password`, the default) accepted the key |
| systemd units | `quay-pod.service` (active, exited), `quay-redis.service` and `quay-app.service` (active, running), written to `/etc/systemd/system` (writable on bootc). Classic unit files, not quadlets |
| Containers | `registry.redhat.io/quay/quay-rhel8:v3.12.12`, `registry.redhat.io/rhel8/redis-6:1-190`, `registry.access.redhat.com/ubi8/pause:8.10-5`, run by rootful podman 5.8.2 / crun on cgroup v2 |
| Health | `curl https://<host>:8443/health/instance` returns **200**. After `sudo systemctl restart quay-app` it returns 200 again within about 30 s, with all three units active |
| SELinux | Enforcing, no AVC denials in the journal |
| Root CA (`/var/quay-root/quay-rootCA/rootCA.pem`) | RSA 2048, `sha256WithRSAEncryption`, self-signed, valid about 3 years, SAN = host FQDN |
| Server certificate (`/var/quay-root/quay-config/ssl.cert`) | RSA 2048, `sha256WithRSAEncryption`, CN `quay-enterprise`, SAN = host FQDN, valid 1 year. The file holds the chain (2 certificates). Key: RSA 2048 |
| TLS handshake (`openssl s_client`, host FIPS policy) | TLSv1.3, `TLS_AES_256_GCM_SHA384`, peer signature `rsa_pss_rsae_sha256`, `Verify return code: 0 (ok)` against the Quay root CA |
| FIPS inside the container | The RHEL 8 Quay container sees `fips_enabled=1` and enforces it: `hashlib.md5()` raises `disabled for FIPS`. Quay's bundled pushgateway is `X:strictfipsruntime` |

**Result: PASS [LAB]** with two changes: use a `--quayRoot` under `/var`, and do not depend on
`/opt` or `/usr/local`. The generated key and certificates (RSA 2048, SHA-256) are FIPS-acceptable.
The default `openssl.cnf` that mirror-registry writes says `default_bits = 4096`, but the generated
keys are 2048-bit. Supply your own `--sslCert/--sslKey` if policy requires larger keys or an
enterprise CA.

**Observation (not blocking):** At Quay start-up the journal shows 12 Python tracebacks:
`gunicorn-web` / `gunicorn-secscan` `AssertionError` in `gevent._abstract_linkable`. Health,
login, push and pull all worked afterwards. The RHEL 9.8 non-FIPS registry node in the same lab
shows none, so this is either FIPS-related or RHEL 10-related. It was not investigated further.

## Test 6 - Mirror-to-mirror on the FIPS host with the FIPS oc-mirror

ImageSetConfiguration (one platform channel, no operators):

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
      - name: candidate-5.0
        type: ocp
        minVersion: 5.0.0
        maxVersion: 5.0.0
    graph: true
```

Preparation:
1. Copy the Quay root CA to `/etc/pki/ca-trust/source/anchors/` and run `update-ca-trust`.
   After that, `curl` without `-k` returns 200.
2. Build a merged authfile from the Red Hat pull secret plus `init` credentials for the local Quay.
   Store it at mode 600 and never print it.

```
$ oc-mirror.rhel9 --v2 -c /var/tmp/isc.yaml --workspace file:///var/tmp/ocm-ws \
    docker://<host>:8443/rhel10test --authfile <merged authfile> \
    --cache-dir /var/tmp/ocm-cache --port 56500
...
images to copy 199
199 / 199 release images mirrored successfully
mirror time     : 8m32.394937815s
rc=0
```

| | |
|---|---|
| Images | 199/199 (release payload plus OSUS graph-data image), 0 errors |
| Time | 8 min 32 s (direct internet egress; the RHEL 9 bastion run with the CDN build took 12 min 54 s through the lab VPC) |
| Disk | 23 GB in Quay (`/var/quay-root/data`), 473 MB workspace |
| Cluster resources | `idms-oc-mirror.yaml`, `itms-oc-mirror.yaml`, `signature-configmap.{json,yaml}`, `updateService.yaml` |
| IDMS | two mappings: `quay.io/openshift-release-dev/ocp-v5.0-art-dev` -> `<host>:8443/rhel10test/openshift/release` and `quay.io/openshift-release-dev/ocp-release` -> `.../openshift/release-images` (no `ocp-v4.0-art-dev`, as in the RHEL 9 runs) |
| Verification | `oc adm release info <host>:8443/rhel10test/openshift/release-images:5.0.0-x86_64` (FIPS `oc`, system trust) returns digest `sha256:5d7ed8b3...2e55`, the same as quay.io |

**Result: PASS [LAB].**

## Test 7 - CDN oc-mirror 2.0.0, dry run, same image set config

```
$ oc-mirror --v2 -c /var/tmp/isc.yaml --workspace file:///var/tmp/ocm-ws-cdn \
    docker://<host>:8443/rhel10test-cdn --authfile <merged authfile> \
    --cache-dir /var/tmp/ocm-cache-cdn --port 56501 --dry-run
rc=0   (18 s)
```

- `dry-run/mapping.txt`: 199 images, the same count as the real FIPS run.
- The generated IDMS is identical to the FIPS build's apart from the namespace and the version annotation.
- **`--dry-run` is not side-effect free:** it pushed `rhel10test-cdn/openshift/graph-image:latest` into Quay.
  This matches the earlier mirror-to-disk observation (tracker M9).

**Result: PASS [LAB].** Both builds plan the same image set. Only the image build uses the FIPS module.

## Caveats

1. **One host, one image.** RHEL 10.2 image mode built from one FIPS blueprint, in a commercial
   AWS region with direct internet egress. Not tested: package-mode RHEL 10, GovCloud/ISO, or
   mirroring through the Squid proxy.
2. **RHEL 9 binaries on RHEL 10 work, but are they supported?** The test shows they run and use the
   FIPS provider. It does not establish Red Hat support for RHEL 9 builds on RHEL 10 hosts. Ask for
   a support statement, or wait for RHEL 10 builds.
3. **FIPS validation.** The OpenSSL FIPS provider on RHEL 10.2 identifies itself as the RHEL 9
   provider 3.0.7. Check the current CMVP certificate status for your compliance requirements.
4. **The stack's user data does not fit an image-mode host.** On this host:
   - `dnf install` has no repositories (unregistered, no RHUI) and would need `bootc usr-overlay`.
   - `dnf update -y` is the wrong update model; use `bootc upgrade`.
   - `wget`, `unzip`, `vim-enhanced` and `tmux` are not in the image.
   - `/usr/local/bin` and `/opt` are read-only, which breaks the client install, the AWS CLI
     installer (`./aws/install` into `/usr/local`) and `--quayRoot /opt/quay-root`.

   Put packages and tools into the bootc image (Containerfile or blueprint), and keep data under `/var`.
5. **Root.** mirror-registry ran as root (as in the stack template). A rootless install was not tested.
6. **No reboot was performed.** Unit survival across a reboot was not tested; only `systemctl restart`.
7. **Quay start-up tracebacks** (Test 5) are unexplained, although they did not affect function.

## Reproduce

```
# 1. clients (rhel9 builds) into a writable PATH directory
mkdir -p ~/.local/bin && cd /var/tmp
B=https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/5.0.0
curl -fsSLO $B/openshift-client-linux-amd64-rhel9-5.0.0.tar.gz
curl -fsSLO $B/openshift-install-rhel9-amd64.tar.gz
curl -fsSLO $B/ccoctl-linux-rhel9-5.0.0.tar.gz
for f in *.tar.gz; do tar xzf $f; done; cp oc kubectl openshift-install-fips ccoctl ~/.local/bin/
# 2. FIPS-capable oc-mirror
oc image extract registry.redhat.io/openshift5/oc-mirror-plugin-rhel9:v5.0 -a ~/pull-secret.json \
  --filter-by-os=linux/amd64 --path /usr/bin/oc-mirror.rhel9:. --confirm
chmod 755 oc-mirror.rhel9 && mv oc-mirror.rhel9 ~/.local/bin/oc-mirror
# 3. check FIPS use
LD_DEBUG=libs oc-mirror version 2>&1 >/dev/null | grep -E 'libcrypto|fips.so'
# 4. mirror-registry with data under /var
sudo ./mirror-registry install --quayHostname $(hostname -f) \
  --quayRoot /var/quay-root --quayStorage /var/quay-root/data --sqliteStorage /var/quay-root/sqlite
sudo cp /var/quay-root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust
```
