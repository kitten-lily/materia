# Results: Bluefin Server homelab pilot

Plan: [bluefin-server-pilot.md](bluefin-server-pilot.md). Issue #179.
Artifacts are cached outside the repo on the operator workstation under
`~/.cache/bluefin-pilot/v26.11.1701/` (not tracked).

## Phase summary

| Phase | Status | Evidence |
| --- | --- | --- |
| 0 — Baseline, release, recovery | **in progress** (steps 1, 3 pass; 2, 4, 5 pending) | below |
| 1 — Local control plane + worker | not started | |
| 2 — Host VPN + cross-site networking | not started | |
| 3 — Materia + persistent services | not started; **to be rescoped**, see F2 decision | |
| 4 — Hetzner edge worker | not started; UEFI available on cpx gen2, see F1 (resolved) | |
| 5 — Updates, failures, recovery | not started | |
| 6 — Krytis runner (optional) | not started | |

## Phase 0 — 2026-11-09

### Step 1: production inventory (read-only) — pass, except traffic baseline

Collected over the tailnet with `hostnamectl`, `/sys/firmware/efi`, `free`,
`lsblk`, `df`, the live `materia-update.container`, `podman image inspect`,
`journalctl -u materia-update.service`, `systemctl --failed`, `nft list
tables`, `iptables -V` and `podman ps`.

| Fact | bow | flutterina |
| --- | --- | --- |
| Hardware | Dell OptiPlex 7090, i5-10500T, 12 threads | Hetzner vServer (KVM), AMD EPYC-Rome, 2 vCPU |
| Firmware | **UEFI** | **legacy BIOS** (SeaBIOS, "20171111") |
| OS | Flatcar 4757.2.3, kernel 6.12.114 | Flatcar 4757.2.3, kernel 6.12.114 |
| RAM | 31 GiB, ~28 GiB available, no swap | 3.7 GiB, 2.4 GiB available, no swap |
| Root disk | 931 GiB SSD, `/` 78% used (643/868 GiB) | 38 GiB, `/` 62% used (18/31 GiB) |
| Data | LVM `vg_data/lv_data` over two NVMe (1.8 + 3.6 TiB), ext4 5.5 TiB, **93% used**; LUKS2 USB 7.3 TiB XFS at `/mnt/usb`, 71% | none |
| Firewall | nftables active (`inet filter`) + netavark iptables-nft | no host nftables; netavark iptables-nft; Hetzner cloud firewall |
| Live Materia | `v0.8.0@sha256:7276f4a7…6d532d` | same |
| Last Materia runs | 2026-11-08 and -09 05:00, clean ("Nothing to do") | same |
| Failed units | none | none |
| Containers | 12 up (media, DBs, buildbarn, tailscale-gateway, beszel-agent) | 8 up (pangolin pod, newt, tailscale, beszel hub/agent) |

The provisioning templates pin Materia `v0.8.1@sha256:52c10659…`, but both
hosts still run v0.8.0. This is the expected "template pins don't reach a
running host" gap (`mise materia:sync-image` not yet run for v0.8.1). It is
not a pilot blocker: the pilot pins v0.8.1 (plan, Phase 3 step 3). The
production sync is separate work.

**Traffic baseline: pending.** Traefik has neither access logs nor metrics
enabled (`traefik_config.yml.gotmpl`), so flutterina's peak request rate and
concurrency cannot be read from existing data. Only throughput is available
(beszel). Getting a request-rate baseline needs a production config change
(Traefik metrics or access log), which needs its own approval. Until then,
Phase 4's load profile can only be specified as throughput.

### Step 2: home-side virtualization — candidate found, boot test pending

Candidate: the operator workstation (melog): 16 threads, 31 GiB RAM (~20 GiB
available under normal use), `/dev/kvm`, `qemu-system-x86_64`, OVMF
including Secure Boot variants (`OVMF_CODE_4M.secboot.fd`). libvirt is not
installed or running, so `virt-host-validate` is unavailable; plain QEMU is
enough. `/var` has 76 GiB free (92% used), which does not fit the plan's
allocation (64 + 2 data + 40 GiB) fully provisioned. Use sparse qcow2 and
shrink the OS disks, or pick another host. Not yet done: the disposable UEFI
VM console boot.

### Step 3: release verification — pass

- Release v26.11.1701, commit `b928b45bd7a0633de04febf3d654fa084c182e00`,
  published 2026-11-06T08:02Z, not a prerelease.
- Trust root taken from the **pinned git commit**, not the release assets:
  `files/os/sysupdate-keys/import-pubring.gpg` (sha256 `9d5a35be…3f239`),
  key `7A87 E575 D29F 60A4 9B20 D475 709B 5477 95F9 9C34`, "Bluefin Server
  Release Signing <releases@projectbluefin.io>", RSA 4096, created
  2026-07-10.
- `gpgv --keyring ./trust/import-pubring.gpg SHA256SUMS.gpg SHA256SUMS` →
  `Good signature`, made 2026-11-06 08:52 CET by that key.
- `sha256sum --check --ignore-missing SHA256SUMS` → all 12 selected assets
  `OK`, each listed individually (below). `SHA256SUMS` sha256
  `79c072df…25f3`.
- `gh attestation verify bluefin-server-installer_26.11.1701.raw --repo
  projectbluefin/server` → exit 0.

| Asset | sha256 |
| --- | --- |
| `bluefin-server-installer_26.11.1701.raw` | `580116f410b8f2de43afd7df68a63c5747bfe0e3ff43079eacbe3d0fa230e6c8` |
| `kubeadm_26.11.1701.raw.zst` | `6d5e97ae4eb34745886cfc8e3b0e0851afeec0082e7ee896006d3a8879110f97` |
| `homelab_26.11.1701.raw.zst` | `b2b572a30da88fb9ed451dc9f173f024c3ca433b55fb46a11c878d4c21245d37` |
| `podman_26.11.1701.raw.zst` | `8617d30f5e52454e9f500f862e82ebdb4dc3ae08fec326596ab0285b3e654d7b` |
| `tailscale_26.11.1701.raw.zst` | `f21ef7d71d4f3601744fd202c79331c6a4ccaa65ed2f0ae1ae159f969007a341` |
| `argo-workflows_26.11.1701.raw.zst` | `b741abd462b8cedd5d76aeb4ea31789beca2dadfd0aafb9cfdb7ce6699ad8882` |
| `mcp_26.11.1701.raw.zst` | `74aa6abf24349a8a50c0f687250d3dd7fb2e38e2912732b274684d281abf7b4a` |
| `kubestellar_26.11.1701.raw.zst` | `7501092503a64523c35900574ea1009e0ad0ffe439ff8fc5acfae94c48c56fbe` |
| `homelab-control-plane.bu` | `74f91db8018ab7842cc870d4afd1b2db0fcaae47ea714db1ded8abd0e77e2875` |
| `homelab-node.bu` | `531aaf4344e75421750bcd70532f651801f057e051b3adc7df8036cd4ad2e62d` |
| `homelab-control-plane.ign` | `1e337b4c8336337fd2c133f77f0b2f0a9361f9362b47bf69ad29b0811e91c786` |
| `homelab-node.ign` | `57db9d6ca0817dbae57aa410c308b8eb53eaf245a1bbe29533f360f8fcbf7bd3` |

Versions read from the extracted sysexts (`fsck.erofs --extract`):
Kubernetes **v1.35.10** (`kubeadm version`, `kubelet --version`),
containerd/runc/crictl shipped in the kubeadm sysext; Cilium **v1.20.2**
(`quay.io/cilium/cilium:v1.20.2` in the homelab manifests); kured
**1.23.0** (digest-pinned). All sysexts report `ARCHITECTURE=x86-64`.

Second release for update testing: candidate **v26.11.1714** (latest, same
day). Upstream cut four releases on 2026-11-06 alone, so "latest" will move;
re-pin and check its Kubernetes minor before Phase 5.

### Step 4: recovery procedures — pending

### Step 5: network posture — pending (needs operator decisions)

Inputs gathered so far:

- Joining defaults to **mDNS** discovery plus a passphrase on TCP 6447.
  `HOMELAB_CONTROL_PLANE=host[:port]` skips mDNS. The pilot must set it on
  every node (plan requirement: no cross-site mDNS dependency).
- The Tailscale sysext exists and is signed (`tailscale_26.11.1701.raw.zst`);
  its netfilter behaviour is not yet inspected.
- Production backends: both hosts run netavark through iptables-nft
  (`iptables v1.8.13 (nf_tables)`); bow also loads nftables `inet filter`.
- Still undecided: Tailscale netfilter mode, pilot host firewall, and the
  pilot Hetzner firewall object (not created; creating it is an
  outward-facing change awaiting approval).

## Findings

**F1 — Firmware depends on the Hetzner server-type generation. RESOLVED:
UEFI is available, but not on CX.** flutterina (cx23, created 2025-10-30) has
no `/sys/firmware/efi` and reports SeaBIOS firmware. Bluefin boots via
systemd-boot/UKI with A/B boot counting, and the release ships only x86-64
assets (no arm64 release artifacts, so the CAX/Arm line is not an option).

Probe, 2026-11-09 (operator chose option 1a). **CX23 cannot be ordered**:
`hcloud server-type list` shows cx23/cx33/cx43/cx53 available in no location.
So the probe used the closest orderable x86 type, `cpx12` in hel1
(€0.023/h), with a temporary SSH key and a firewall allowing tcp/22 from the
operator's IP only, all labelled `pilot=bluefin`:

- Debian 13 system image: `/sys/firmware/efi` present, `efi: EFI v2.7 by
  Ubuntu distribution of EDK II`, DMI still "Hetzner vServer 20171111". The
  disk has both a BIOS-boot and an EFI System partition. No `SecureBoot`
  variable and no PK/KEK/db enrolled, so Secure Boot is unavailable or off.
- Rebuilt from the **same Flatcar snapshot flutterina was built from**
  (`flatcar-stable-x86`): still UEFI. The image does not select the
  firmware; the server type does.
- Server, firewall and SSH key deleted about 2 minutes after creation.
  `hcloud {server,firewall,ssh-key} list -l pilot=bluefin` all empty, and
  only flutterina remains.

Consequences:
- Phase 4 uses **`cpx22`** (2 vCPU, 4 GB, €0.039/h in hel1), the orderable
  equivalent of cx23's RAM, instead of CX23. Capacity results are measured on
  a different CPU generation (AMD EPYC-Genoa, faster per core per the
  2026-09-24 benchmarks), so they are not a like-for-like sizing of
  flutterina's current box.
- Secure Boot is off on Hetzner. Phase 1 step 2 already treats an insecure
  exception as a provider constraint; record it as such.
- Not Bluefin-specific: CX types are currently unorderable. A
  delete-and-recreate of flutterina (as opposed to `hz:rebuild`, which keeps
  the server) would have to move to another type.

**F2 — Bluefin's Podman sysext is rootless-only and ships no Quadlet
generator. Not a blocker, per the operator decision below.** Extracted `podman_26.11.1701.raw.zst`
contains only *user* units (`bluefin-podman.service`/`.socket` under
`/usr/lib/systemd/user`), private binaries under `/usr/lib/bluefin/podman`
(podman, crun, conmon, netavark, aardvark-dns, pasta), and **no quadlet
binary and no system generator**. Materia installs Quadlets to
`/etc/containers/systemd/` and needs rootful Quadlet plus
`/run/podman/podman.sock`. Unless Phase 3 finds a supported path, running
Materia needs a self-maintained rootful Podman/Quadlet sysext. The plan says
to record that cost and reconsider the migration before more service tests
(Phase 3 exit).

*Operator decision, 2026-11-09:* Materia is not a long-term requirement on
Bluefin. If Bluefin Server is adopted, services are expected to move to
Kubernetes-native deployment, replacing Materia rather than running beside
it. The plan's Phase 3 (Materia/rootful Quadlet compatibility) and the
Materia timer requirements in the Phase 5 soak therefore need rescoping
toward Kubernetes-native equivalents. Until the plan is revised, Phase 3 is
not executed as written.

**F3 — Reboot and update controls (feeds Phase 1 step 1 and Phase 5).**
- kured: disable with `HOMELAB_KURED=no` in `homelab.conf` (on by default).
- Presets enable `systemd-sysupdate.timer` (downloads into the inactive
  slot) and `systemd-sysupdate-reboot.timer` (04:10 nightly).
  `bluefin-fleet-reboot.timer` is `PartOf=` the reboot timer. Disabling or
  masking both sysupdate timers stops every automatic update and reboot, and
  keeps the pilot on the pinned release until Phase 5.
- `/etc/reboot-lock` (or `/run/reboot-lock`) holds the sysupdate reboot and
  `bluefin-boot-deadline`; kured has its own lock and ignores these files.
  This is a ready-made primitive for the Phase 5 host-job interlock.
- **Boot health gate:** `systemd-boot-check-no-failures.service` +
  `bluefin-boot-deadline.timer` mean a boot-counted (post-update) boot with
  *any* failed unit by the deadline reboots, and systemd-boot then falls
  back. A single failing Materia-managed container after an OS update could
  therefore roll the OS back. Phase 5 should test this deliberately.
