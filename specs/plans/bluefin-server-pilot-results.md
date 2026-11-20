# Results: Bluefin Server homelab pilot

Plan: [bluefin-server-pilot.md](bluefin-server-pilot.md). Issue #179.
Artifacts are cached outside the repo on the operator workstation under
`~/.cache/bluefin-pilot/<version>/` (not tracked). **Pinned release:
v26.11.2506** (re-pinned 2026-11-20, see "Re-pin" under Phase 0 step 3); the
v26.11.1701 evidence below is kept as the record of the first verification.

## Phase summary

| Phase | Status | Evidence |
| --- | --- | --- |
| 0 — Baseline, release, recovery | **in progress** (steps 1, 2, 3, 5 pass; 4 procedures written, its checks run in Phase 1) | below |
| 1 — Local control plane + worker | not started | |
| 2 — Host VPN + cross-site networking | not started | |
| 3 — Persistent services as Kubernetes workloads | not started; rescoped 2026-11-09 per F2 decision | |
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

### Step 2: home-side virtualization — pass

Candidate: the operator workstation (melog): 16 threads, 31 GiB RAM (~20 GiB
available under normal use), `/dev/kvm`, `qemu-system-x86_64`, OVMF
including Secure Boot variants (`OVMF_CODE_4M.secboot.fd`). libvirt is not
installed or running, so `virt-host-validate` is unavailable; plain QEMU is
enough. `/var` has 76 GiB free (92% used), which does not fit the plan's
allocation (64 + 2 data + 40 GiB) fully provisioned. Use sparse qcow2 and
shrink the OS disks, or pick another host.

UEFI console boot test, 2026-11-09, on melog:

- QEMU 10.2.4, `q35` with KVM, 4 vCPU, 8 GiB, `OVMF_CODE.fd` (the non-SMM
  build) with a fresh copy of `OVMF_VARS.fd`. The verified
  installer image was attached as a USB disk through a qcow2 overlay (the
  downloaded image is never written), plus an empty 64 GiB sparse virtio
  target disk. Console captured from serial and by QMP `screendump`. Run
  files are in `~/.cache/bluefin-pilot/vm/uefi-test/`.
- First boot: OVMF loaded the installer's systemd-boot, which found the
  firmware in Secure Boot setup mode, printed `Enrolling secure boot keys
  from directory: \loader\keys\auto` and `Custom Secure Boot keys
  successfully enrolled, rebooting the system now!`, then rebooted. **The
  installer enrolls its own PK/KEK/db into any firmware left in setup
  mode.** See F4.
- Second boot (same NVRAM): the systemd-boot menu offered "Bluefin Server
  26.11.1701" (installer), "Bluefin Home Server (home-server)", "Homelab:
  control plane", "Homelab: node" and "Reboot Into Firmware Interface". It
  auto-booted the default. The kernel came up at ~2.4 s, and about 60 s after
  start the VGA console showed the installer prompt: "Install Bluefin Server
  26.11.1701 to which disk? … 1) 64G unknown model /dev/vda … Disk number
  [1], or q to cancel". It listed only the target disk, not the USB it booted
  from, and says it confirms again before erasing.
- Serial noise only: 10 `Failed to preset all unit` lines for generated or
  masked units, and `systemd-gpt-auto-generator … exit status 1` (expected
  when booting from a USB image with no root-disk GPT). No unit failures are
  visible on the console.
- Stopped via QMP `quit` without answering the prompt. The target qcow2 stayed
  at ~200 KB, so nothing was installed.

Correction: the installer's `bluefin-installer-secure-boot.service` check
went straight to the disk prompt. Per upstream `usb-installer.md`, it does
that only when Secure Boot is on with the Bluefin certificate in `db`; every
other state shows a warning first. So after enrollment this firmware ran with
Secure Boot on, even on the non-SMM OVMF build (whose variable store is not
SMM-protected). Still needed in Phase 1: the SMM build
(`OVMF_CODE_4M.secboot.fd`, `smm=on`) for a tamper-resistant variable store,
an actual install, and the recovery boot from the installer over an installed
disk (Phase 0 step 4).

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

Second release for update testing: superseded by the re-pin below; pick it
at Phase 5 from releases newer than v26.11.2506 and check its Kubernetes
minor first.

### Step 3 (repeat): re-pin to v26.11.2506 — pass, 2026-11-20

Why: upstream moved 47 commits between the old pin (`b928b45`) and the newest
release (`d7f2890`, v26.11.2506, published 2026-11-20 07:30 UTC; 48 releases
in two weeks, numbered by CI run). Reviewed `compare/b928b45...d7f2890`; most
commits are dependency bumps and CI fixes. Relevant to the pilot:

| Upstream change | Effect |
| --- | --- |
| #591 join loop skips candidates that cannot prove the passphrase; a restarted join no longer trusts a bare token | correctness and security fix for joining |
| #663 kubeadm sysext raises `fs.inotify.max_user_instances` 8192 and `max_user_watches` 1048576 | prevents "too many open files" once pods run |
| #648 Secure Boot `.auth` files signed with attributes 0x27 instead of 0x67 (#612: firmware rejected the enroll) | see the control run below: did not reproduce on melog's firmware |
| #595 release gate on A/B slot headroom; k0s keeps two images | background for Phase 5 |
| Tailscale 1.104.5 → 1.104.7, runc 1.3.6 → 1.3.7 | patch bumps |

Unchanged (so F2, F3 and the network decisions stand): the homelab templates
are byte-identical (same sha256 for `homelab-control-plane.bu`/`.ign` and
`homelab-node.bu`/`.ign`); the extracted homelab manifests are identical
(`diff -rq`); Kubernetes v1.35.10; Cilium v1.20.2; kured 1.23.0 (same digest);
the Podman sysext still has no Quadlet generator and no system units; the
Tailscale sysext still ships `tailscaled.service` disabled by preset.

Verification, same procedure as before:

- Trust root from the new pinned commit,
  `files/os/sysupdate-keys/import-pubring.gpg`: byte-identical to the one from
  `b928b45` (sha256 `9d5a35be…3f239`), same key
  `7A87 E575 D29F 60A4 9B20 D475 709B 5477 95F9 9C34`.
- `gpgv --keyring ./trust/import-pubring.gpg SHA256SUMS.gpg SHA256SUMS` →
  `Good signature`, made 2026-11-20 08:18 CET. `SHA256SUMS` sha256
  `4615a9ee…b299`.
- `sha256sum --check --ignore-missing SHA256SUMS` → all 12 selected assets
  `OK`, exit 0. `gh attestation verify` on the installer → exit 0.
- GitHub reports the release `immutable: false`, as before; the hashes below
  are the pin.

| Asset | sha256 |
| --- | --- |
| `bluefin-server-installer_26.11.2506.raw` | `68bac3c0e9ab4312b3e1d1d1a7b786916253fe619b30db0d0fe8c1da3525db14` |
| `kubeadm_26.11.2506.raw.zst` | `e49c715d52dca1e71a0274c869fd45aeafb6e303ed567963476ee81f981fd7da` |
| `homelab_26.11.2506.raw.zst` | `3ef02f12331a57a27e93a70025abfdc7bafd4945a5ac1ee5b3ab09040ed10066` |
| `podman_26.11.2506.raw.zst` | `853f59a6642d4a226313b2946747b5e89faf7615c67fef015fb6af2333bfe115` |
| `tailscale_26.11.2506.raw.zst` | `64685f39dd7620027aed17916e475313b893c86fbfdf6efb74bd2f7b76dd99a3` |
| `argo-workflows_26.11.2506.raw.zst` | `28ebd30d0638e3743d77adcc625eb982e2131ac00c680059c5696955fd8dacf9` |
| `mcp_26.11.2506.raw.zst` | `01f6690ce1f40dd3a6226eefab3c9e084a74293d9158e36239325b700b504539` |
| `kubestellar_26.11.2506.raw.zst` | `2c8ab7667bf5f404d742d11bbf8ba09ed2c4d4309c8f1524426a2e1f9d5125f8` |
| `homelab-control-plane.bu` | `74f91db8018ab7842cc870d4afd1b2db0fcaae47ea714db1ded8abd0e77e2875` |
| `homelab-node.bu` | `531aaf4344e75421750bcd70532f651801f057e051b3adc7df8036cd4ad2e62d` |
| `homelab-control-plane.ign` | `1e337b4c8336337fd2c133f77f0b2f0a9361f9362b47bf69ad29b0811e91c786` |
| `homelab-node.ign` | `57db9d6ca0817dbae57aa410c308b8eb53eaf245a1bbe29533f360f8fcbf7bd3` |

Versions from the extracted sysexts: Kubernetes **v1.35.10**, runc **1.3.7**,
Cilium **v1.20.2**, kured **1.23.0**, Tailscale **1.104.7**.

UEFI boot under SMM-protected Secure Boot firmware (the run the first test
deferred to Phase 1): QEMU `q35,smm=on` with
`-global driver=cfi.pflash01,property=secure,value=on`,
`OVMF_CODE_4M.secboot.fd` and a fresh `OVMF_VARS_4M.secboot.fd`. (A first try
had the device name wrong, `cfi.flash01`; QEMU warned `invalid class name`,
so that run was discarded and redone from fresh variables.)

- v26.11.2506: first boot printed `Custom Secure Boot keys successfully
  enrolled, rebooting the system now!`; second boot reached the installer's
  disk prompt with no Secure Boot warning, which per upstream happens only
  when Secure Boot is on with the Bluefin certificate in `db`.
- Control, v26.11.1701 on identical firmware and fresh variables: **the same
  result**, enrollment and a silent pass. #612's rejection does not reproduce
  with this OVMF build, so it depends on the firmware. The earlier claim in
  this session that 1701 "would most likely fail" under the SMM build was an
  inference and was wrong. Whether Hetzner's firmware is affected stays a
  Phase 4 check; on the pinned v26.11.2506 it is fixed either way.
- Both runs stopped at the disk prompt via QMP `quit`; target disks stayed at
  ~200 KB. Run files: `~/.cache/bluefin-pilot/vm/uefi-test-2506/` and
  `~/.cache/bluefin-pilot/vm/uefi-control-1701/`.

This also covers the Phase 1 item "Secure Boot under the SMM build" from the
first UEFI test.

### Step 4: recovery procedures — written; checks pending

Procedures and restore inputs:
[bluefin-server-pilot-recovery.md](bluefin-server-pilot-recovery.md).
Upstream facts that shaped them: no emergency shell (a failed boot reboots);
the installer is offline with no shell, so its "recovery boot" is a
reinstall; root is locked unless a console password is set at first boot.
Pilot policy: every node gets a console root password. Its two checks
(console access with networking off, reinstall over an installed disk) need
an installed node and run in Phase 1. The tailnet enrollment policy and the
pilot Proton Pass vault are proposed, not applied.

### Step 5: network posture — pass

Decided by the operator on 2026-11-09:

| Item | Decision | Why |
| --- | --- | --- |
| Tailscale netfilter mode | **off** on every pilot node (`--netfilter-mode=off`) | keeps Tailscale from writing rules next to Cilium's; the pilot nodes advertise no routes and are not exit nodes, so only the 100.64.0.0/10 anti-spoof drop is lost |
| Host firewall | **Cilium host policies** (host firewall, `CiliumClusterwideNetworkPolicy` with a node selector) | Bluefin ships no host firewall at all (no nftables files in the source tree); Kubernetes-native; also covers the `hostNetwork` Pangolin pod; production bow would need the same to replace its nftables posture |
| Pilot Hetzner firewall | created now, rules below | free; required before Phase 4 creates a server |
| Tailscale relay | the pilot does not use flutterina's production peer relay | no production dependency; udp/41641 is open on the edge instead |

Facts behind the decisions, from the extracted sysexts: `tailscaled.service`
runs natively on the host with `--port=${PORT}` (41641 by default, from
`/usr/share/bluefin/tailscale/tailscaled.defaults`, overridable in
`/etc/default/tailscaled`) and is **disabled** by preset (`80-tailscale.preset`),
so the pilot Butane must enable it. Cilium runs in `routing-mode: tunnel`,
`tunnel-protocol: vxlan` (udp/8472) with `enable-ipv4-masquerade`. Joining
defaults to mDNS plus a passphrase on TCP 6447; `HOMELAB_CONTROL_PLANE`
skips mDNS and is set on every node.

Pilot firewall `bluefin-pilot` (id 12011815, label `pilot=bluefin`),
created 2026-11-09 20:51 CET, **not applied** to any server; Phase 4
attaches it at server creation. Inbound, from `0.0.0.0/0` and `::/0`:

| Protocol/port | Purpose |
| --- | --- |
| tcp/443 | Traefik HTTPS (Pangolin test) |
| udp/443 | Traefik HTTP/3 |
| udp/51820 | Gerbil WireGuard |
| udp/21820 | Gerbil client relay |
| udp/41641 | Tailscale direct peer connections |
| icmp | diagnostics |

No rule for tcp/22, 6443, 6447, 10250 or udp/8472: SSH, the API, joining,
kubelet and VXLAN all go over the tailnet. Verified with `hcloud firewall
describe bluefin-pilot`. Remove it in the pilot cleanup.

Operator actions: the `bluefin-pilot` Proton Pass vault was created on
2026-11-09 (`pass-cli vault list` shows it; it holds no items yet). The
tailnet policy was applied on 2026-11-20 (recovery doc, T2), with two
changes from the proposal after comparing it with the live policy: no
separate operator grant (the existing `autogroup:member` → `*` grant already
covers operator devices), and `tag:bluefin-pilot` added to the `nodeAttrs`
`ipPool` target (`100.64.0.0/12`), so pilot nodes cannot get addresses inside
Gerbil's `100.89.128.0/20` tunnel range. The policy carries `tests` asserting
pilot ↔ production denial. Auth key generated (reusable, 7-day expiry, not
ephemeral, pre-approved, `tag:bluefin-pilot` only) and stored in the
`bluefin-pilot` vault as `tailscale-auth-key`, field `key`; read back with
`pass-cli item view --vault-name bluefin-pilot --item-title
tailscale-auth-key --field key` (exit 0, one 61-character line starting
`tskey-auth-`; value not printed). **Phase 0 operator prerequisites are
complete.**

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
toward Kubernetes-native equivalents. The plan was revised the same day
(b22e9ce): Phase 3 now trials Argo CD-reconciled workloads, and the Phase 5
soak checks Argo CD syncs and scheduled backup jobs.

**F4 — The installer auto-enrolls its own Secure Boot keys into firmware in
setup mode.** Seen on the melog UEFI test. The Hetzner cpx12 probe had no
PK/KEK/db enrolled (results, F1), so the same will likely happen on a
Hetzner pilot node. Two things to check in Phase 4 before relying on it:
whether Hetzner's firmware NVRAM persists across stop/start and rebuilds
(otherwise the node is back in setup mode after each one), and whether
enrollment actually turns enforcement on there. Either way it is a firmware
state change on the node; for bow's physical firmware it would replace
whatever keys are enrolled today, which needs a separate decision before any
bow hardware test.

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
