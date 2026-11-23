# Results: Bluefin Server homelab pilot

Plan: [bluefin-server-pilot.md](bluefin-server-pilot.md). Issue #179.
Artifacts are cached outside the repo on the operator workstation under
`~/.cache/bluefin-pilot/<version>/` (not tracked). **Pinned release:
v26.11.2506** (re-pinned 2026-11-20, see "Re-pin" under Phase 0 step 3); the
v26.11.1701 evidence below is kept as the record of the first verification.

## Phase summary

| Phase | Status | Evidence |
| --- | --- | --- |
| 0 — Baseline, release, recovery | **pass** (step 4's two checks ran in Phase 1, 2026-11-20) | below |
| 1 — Local control plane + worker | **pass** 2026-11-20 | below |
| 2 — Host VPN + cross-site networking | **pass** 2026-11-21, except `readyz` p95 (540 ms over DERP vs 500 ms), deferred to Phase 4 by decision | below |
| 3 — Persistent services as Kubernetes workloads | **pass** 2026-11-22: steps 0–6 all pass; step 1's push-to-rollout passes only with tuned polling (miss at the template's 412 s); findings F7–F11 | below |
| 4 — Hetzner edge worker | in progress: E1.2 local rehearsal **pass** 2026-11-23 (F12, F13); Traefik baseline collecting until 2026-11-29; no server yet | below |
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

### Step 4: recovery procedures — pass (checks ran in Phase 1, see "Phase 1 step 6")

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

## Phase 1 — 2026-11-20

Design: [bluefin-server-pilot-phase1.md](bluefin-server-pilot-phase1.md).
Tooling: `mise bluefin:pilot:render`, `mise bluefin:pilot:vm`. Fixtures:
`provisioning/bluefin/fixtures/`. Release v26.11.2506, both VMs on melog
under SMM Secure Boot OVMF, control plane `10.77.0.10`, worker `10.77.0.11`
on the loopback-bound QEMU multicast segment.

| Step | Result | Evidence |
| --- | --- | --- |
| 1 Render | pass | butane 0.29.0 `--strict` exit 0 for both; control plane 6.3 KB, worker 2.4 KB |
| 2 Install + first boot | pass | both: unattended `sysinstall=success 0`; `bootctl`: `Secure Boot: enabled (user)`; `/usr` = `/dev/mapper/usr` erofs; sysexts merged (cp: kubeadm, homelab, argo-workflows, mcp, kubestellar; worker: kubeadm, homelab); `systemctl --failed` empty; both sysupdate timers `masked`; `passwd -S root` = `P`; no kured DaemonSet |
| 3 Init, join, dataplane | pass | cp `Ready` 61 s after first boot; worker `Ready` 61 s after its first boot (threshold 20 min); InternalIPs `10.77.0.10`/`.11`; join log `got a join token … endpoint=10.77.0.10:6443`; `ciliumnodes` and `cilium-dbg node list` show only `10.77.0.x`; pod↔pod across nodes both ways, Service-by-name backed only by the other node's pod both ways, `kubernetes.default` → `10.96.0.1` from both; `cilium-dbg status` OK; `/readyz` ok |
| 4 Components, storage | pass | applier `all enabled components applied`; 39 pods, none failing; `local-path` default; PVC fixture on the worker sha256 `3326f462…668b` = expected, unchanged after both worker reboots |
| 4b Add-on access | pass, 13/13 | Gateway `10.77.0.240` (pool); TLS for argo/mcp/kubestellar verifies against `homelab-ca`; port 80 → `301 https://`; Argo 401 / 200 with `kubectl create token`; MCP 401 / read OK with `mcp-client`, tool list read-only, write refused and no object created; Console `/auth/github` 401 / 3xx with `kc_auth` cookie; Console login not in the journal |
| 5 Reboots | pass | worker 105 s and 111 s to both `Ready`; control plane 32 s and 27 s (threshold 10 min); node UIDs unchanged; no failed units; fixture checksum unchanged. One CoreDNS replica needed ~3 min to pass readiness after the last control-plane reboot (inside the 10-minute pod threshold) |
| 6a Console, no network | pass | both NICs link down via QMP `set_link` (`no-carrier`, SSH timed out); root logged in on tty1 with the vault password (`uid=0(root)`); links restored, both nodes `Ready` 12 s later |
| 6b Reinstall worker, keep data | pass | node deleted (K1), OS disk reinstalled from the installer with enrolled firmware (L3, `--reinstall`), worker rejoined and `Ready` 158 s after the reinstall began with a new node UID; data disk xfs UUID `0b47be81…` and fixture sha256 `22b92180…` unchanged; root password applied on the fresh disk's first boot |

Defects found and fixed during the run (all in the pilot tooling, none
upstream):

- **Root password hash with a trailing newline.** `openssl passwd -6` ends
  its output with `\n`; upstream requires a crypt(5) hash with none. Root
  stayed locked (`!unprovisioned`), so console login failed, and sshd (no
  PAM) also refused the key for the locked account. The credential applies
  only on an installed disk's first boot, so the control plane was
  reinstalled. `render` now strips the newline and checks the `$6$` prefix.
- **SSH offered the agent's keys first.** The workstation agent's four
  security keys used up sshd's attempts before the pilot key. The pilot ssh
  config (`~/.cache/bluefin-pilot/secrets/ssh_config`) sets
  `IdentitiesOnly yes` and `IdentityAgent none`.
- **PVC fixture used `nodeName`.** With `WaitForFirstConsumer` the PVC binds
  only after the scheduler picks a node; `nodeName` bypasses the scheduler, so
  it stayed `Pending`. The fixture uses a `nodeSelector`.
- **`install` assumed fresh firmware.** A reinstall over enrolled firmware
  has no enrollment reset; `vm install --reinstall` skips that stage.

Observations to follow up:

- The worker takes ~5× longer than the control plane to reboot (105–111 s
  vs 21–22 s to a new boot). Not a failure; look at its shutdown journal
  before Phase 5's timing thresholds.
- The secrets added to the `bluefin-pilot` vault: `ssh-root`,
  `root-console-password`, `join-passphrase` (alongside
  `tailscale-auth-key`).

## Phase 2 — 2026-11-20/21

Design: [bluefin-server-pilot-phase2.md](bluefin-server-pilot-phase2.md).
Both VMs rebuilt with `--topology tailnet`: one NIC each (QEMU user-net NAT),
no shared segment, so every node-to-node packet crosses Tailscale. Control
plane `<cp-tailnet-ip>`, worker `<worker-tailnet-ip>` (tailnet IPs; the MagicDNS
suffix is kept out of the repo).

| Step | Result | Evidence |
| --- | --- | --- |
| 1 Host Tailscale before Kubernetes | pass | `pilot-tailnet-prep` finished before `bluefin-cluster-join`, `kubeadm-init` and kubelet on both (cp 9.7 s, worker 53.7 s monotonic); `tailscale debug prefs`: `NetfilterMode: 0`, `CorpDNS: true`, tag `tag:bluefin-pilot`; worker has one NIC (`enp0s4`) plus `tailscale0`; no failed units. Note: Bluefin ships **no `nft` and no `iptables`**, so "no Tailscale firewall rules" rests on `NetfilterMode: 0`, not on a ruleset listing (an earlier `nft list` check silently failed and proved nothing) |
| 1 Ordering of `init.yaml` writers | pass | final `init.yaml` matches the prep unit's own checksum (`sha256sum -c` OK): neither `kubeadm-init-config` nor `bluefin-cluster-prepare` changed it |
| 2 Endpoint and identity | pass | cp `Ready` 96 s after the (fixed) boot, worker `Ready` 108 s after its first boot; InternalIPs are the tailnet IPs; worker join log `endpoint=bluefin-pilot-cp.<tailnet>.ts.net:6443`; TLS to the FQDN verifies against the cluster CA from the workstation over the tailnet (`Verify return code: 0`) and from the worker (`readyz` 200, `ssl_verify=0`); SANs = FQDN, short name, tailnet IP; a wrong name fails verification (curl exit 60) |
| 3a Dataplane over the tailnet | pass | pod↔pod across nodes both ways, Service by name backed by the other node's pod both ways, `kubernetes.default` → `10.96.0.1` from both; Cilium node IPs are the tailnet IPs; pod-to-tailnet: a pod on the cp fetched `pilot-tailnet-ok` from a `tailscale serve` endpoint on the worker's host across the tailnet; 64 MiB pod→pod transfer checksum-intact at ~18.5 Mbit/s |
| 3a Path | DERP | both directions relayed by Tailscale DERP (`ams` one way, `lhr` the other), ~50 ms; `PeerRelay` empty; `netcheck` `MappingVariesByDestIP: true` on both (QEMU user-net behaves as hard NAT). The production peer relay is not granted to `tag:bluefin-pilot` by design, so the local numbers are a worst case |
| 3a MTU | correct | pod `eth0` 1280 (Tailscale's MTU, Cilium's device MTU) with the pod default route at **mtu 1230** (1280 − 50 VXLAN), as Cilium's `getRouteMTU` intends; a 64 MiB transfer moved none of the fragment counters |

| 3a Connectivity test (baseline) | 81/82 | `cilium connectivity test` (CLI v0.20.2, sha256-verified; compatible with Cilium 1.17+), 56 skipped (CLI-marked unsafe tests incl. its own host-firewall tests, disabled features, k8s-localhost tests). The one failure, `no-unexpected-packet-drops`, reports exactly the pre-guard fragment-drop counts (5,539 / 6,967), unchanged across the whole run and across an agent restart: Cilium keeps drop metrics in a pinned BPF map. No new drops occurred. The first run (before the agent restart) also failed `check-log-errors` on the worker agent's 19:51–19:52 API timeouts from the loop window; after the restart that check passes |
| 3a Denial controls | pass (controls) | with the host firewall off, through the non-tailnet NIC: cp 6443 → 200, cp 10250 → 401, cp 6447 → connection arrives (seen on the guest with `ss`), worker 10250 → 401; worker 6443/6447 have no listener (negatives). Two probe-harness faults found and fixed first: the workstation has no `nc` (every earlier "closed" was the probe failing to run), and QEMU's forward accepts locally before trying the guest (a bare connect always "succeeds") |
| 3b Audit mode | pass, after 3 policy fixes | see "Step 3b findings" below. A short window then showed only the denial probes as would-deny. Running the connectivity test in audit mode failed 48/82: `policy-audit-mode` is node-wide, so it also made every pod-level deny policy audit-only (all failures were `*-deny`, L7, FQDN and entity-policy tests), which also means audit mode cannot be left on while validating pod policies |
| 3c Enforce: denial tests | pass (partial coverage) | through the non-tailnet NIC every probe is blocked on both nodes: tcp 6443, 10250, 6447 (no connection arrives on the guest) and udp 8472; Cilium's drop log records each as `Policy denied` from `10.0.2.2`, the UDP one decoded as a VXLAN tunnel packet. Partial: a private NAT, not a public address, and IPv4 only (see F6) |
| 3c Enforce: legitimate traffic | pass, after 4 more fixes | API from the workstation over the tailnet `Verify return code: 0`; worker → API by FQDN 200; dataplane fixture (pod↔pod both ways, Service by name, DNS) passes; `kubectl top` (metrics-server → kubelet 10250) and `exec` (API server → worker kubelet) work. Fixes found by the enforced connectivity test: Envoy L7 replies (11 L7 tests got 503), ICMP errors for PMTU, pod ICMP to the host, and Hubble Relay (crash-looped; see below). Final enforced run: **82/82 pass, 683 actions** (56 skipped as before) |
| 3c Pod-to-tailnet under enforcement | not tested | the only allowed pilot tailnet targets are the cluster nodes themselves, and pod → node host ports are deliberately denied (the drop log shows `Policy denied` from the pod identity to the worker's host port). The host firewall filters ingress to nodes only, so pod traffic to a non-node tailnet service should be unaffected; [INFERENCE] confirming it needs a pilot-tagged non-node tailnet device. Before enforcement, pod-to-tailnet passed (3a) |
| 3d Reboots (enforced) | pass | each node cold-rebooted twice (QEMU stop/start, so the current Ignition with the routing guard applies), one at a time; recovered = new bootID in the node status, node Ready, both Cilium agents ready: worker 33 s and 48 s, control plane 28 s and 24 s (threshold 10 min); every boot: prep unit success first try, both guard `ip rule`s installed by the drop-in, no failed units, no pod-network Tailscale path, host firewall enforcing on both devices. While the control plane is down the worker's agent crash-loops on API timeouts and recovers by itself. Fragment-drop counters were 0 after the reboots, and the connectivity test's drop check passed |

| 4 Resilience (run 2, valid) | pass, except `readyz` p95 | fixture `provisioning/bluefin/fixtures/resilience.yaml`: 64 MiB checksum transfers through a Service across nodes, every 15 s, plus a long-lived TCP connection. **Tailnet-only outage** (`tailscale down` on the worker for 10 min, with the leak below blocked and proven blocked: API by tailnet IP `000`): node `NotReady` after 57 s; after `tailscale up`, node `Ready` +22 s and first good transfer +63 s (threshold 300 s). **Whole-NIC cut** (extra test, QMP `set_link` 10 min): `NotReady` after 52 s; `Ready` +16 s, good transfer +47 s. 18 good transfers, 80 with no data (all inside the outages), 2 short reads, each beginning 6 s after an outage started (streams cut off, not corrupted); no full-length transfer ever had wrong data. **`readyz` from the worker over the tailnet: p50 151 ms, p95 540 ms, max 1.12 s (threshold p95 < 500 ms): miss**, on a DERP-relayed path (run 1: p95 1.08 s). Long-lived connection: **inconclusive** (`nc` never noticed its server pod being evicted and recreated; the server's own log was lost with the pod) |
| 4 Run 1 (invalid, kept for the record) | — | (a) **Harness leak:** with Tailscale down, the worker's route to the control plane's tailnet IP falls back to `via 10.0.2.2` (QEMU NAT on the workstation), and the workstation, itself a tailnet member allowed to reach pilot nodes, forwarded it: the API still answered 200, kubelet lease failures stopped after ~90 s, and the node never went `NotReady`. Pod traffic still failed (VXLAN from the workstation's address is not a known tunnel endpoint). Run 2 blocks it with `ip route add unreachable 100.64.0.0/10` on the worker for the duration of the outage. (b) The server pods were bare pods; evicted after the default 300 s unreachable toleration they were never recreated, so the NIC run "never recovered". Run 2 uses Deployments |

Step 4 observations:

- **Pods on the far side are evicted after 5 minutes of WAN outage.** In both
  outages the worker's pods were evicted at the default
  `node.kubernetes.io/unreachable` toleration of 300 s and recreated when the
  node returned. For a home control plane with a cloud worker (or the
  reverse), any WAN outage over 5 minutes reschedules every pod on the
  unreachable side. Site-pinned or stateful workloads need deliberate
  tolerations.
- **Leak block, now permanent (decided 2026-11-21):** the `tailscaled`
  drop-in also runs `ip route replace unreachable 100.64.0.0/10` before
  Tailscale starts. Tailscale's table 52 is consulted first, so it changes
  nothing while Tailscale is up (`ip route get <cp-tailnet-ip>` → `dev
  tailscale0 table 52`); when it is down, tailnet-bound traffic fails cleanly
  instead of leaking to the underlay. More specific routes inside the range
  (Gerbil's `100.89.128.0/20` on an edge node) still win. Installed on both
  VMs by hand and re-checked after a `tailscaled` restart: with Tailscale
  down on the worker, `ip route get <cp-tailnet-ip>` gives `No route to host`
  and the API by tailnet IP fails at once; after `tailscale up`, table 52
  again, `readyz` by FQDN 200, both nodes `Ready`, Cilium `OK`.
- **`readyz` p95 and throughput are DERP-bound locally.** Both VMs sit behind
  QEMU's user-mode NAT (`MappingVariesByDestIP: true`) and the pilot is not
  allowed to use the production peer relay, so every packet goes through
  Tailscale's public DERP relays (~50 ms, ~18.5 Mbit/s). The threshold has to
  be re-measured over a direct path (the Hetzner node, Phase 4) before the
  plan's "recommend separate clusters" clause is considered. **Decided
  2026-11-21: the miss does not block; Phase 4 re-measures `readyz` p95 over
  the direct path.**

Step 3b findings (host firewall in audit mode), each found because the plan
required checking effective state rather than trusting the applied objects:

- **Device list.** `devices: "tailscale0,enp0s5"` attached the firewall to
  only `tailscale0` on the worker, whose NIC is `enp0s4`. Now
  `tailscale0,en+` (Cilium's prefix wildcard); `cilium-dbg status` shows
  `Host firewall: Enabled [enp0s4, tailscale0]` / `[enp0s5, tailscale0]`.
- **Selector.** A `nodeSelector` on `kubernetes.io/hostname` selected
  nothing: the host endpoint carried only `reserved:host`, none of the Node's
  labels, so enforcement stayed `Disabled` and audit mode produced no host
  verdicts at all. Now `nodeSelector: {}` (every node here is a pilot node).
  Why the Node labels never reached the host endpoint is not yet understood;
  production must understand it before relying on a label selector.
- **Enforcement-only gaps, found by running the connectivity test enforced:**
  (1) Cilium's Envoy L7 proxy connects to backends from the node's
  `cilium_host` address, and the host firewall did not treat the backends'
  replies as replies, so every L7 test got 503; now pods may reach the host on
  TCP 32768–60999 (the kernel's ephemeral range; the only host listeners in
  it are `cilium-agent`/`containerd` on 127.0.0.1 and `tailscaled`'s peer API
  on the tailnet address). (2) ICMP destination-unreachable from outside was
  denied at the host, which would break path-MTU discovery over Tailscale's
  1280-byte MTU; ICMP types 3 and 11 are now allowed from anywhere. (3) Pods
  pinging the node. (4) **Hubble Relay crash-looped** (46 restarts) because it
  reaches each agent's Hubble server on the host network (tcp 4244, via the
  `hubble-peer` Service). The audit window missed it because the relay's
  connection predated it. Lesson: audit mode only shows flows that start
  while it runs; long-lived connections must be forced to reconnect (restart
  their pods) during the audit.
- **Identities.** On the worker, traffic from the control plane's host
  carries identity `kube-apiserver`, not `remote-node`, so every rule written
  for `remote-node` missed it. Audit also showed MetalLB memberlist (tcp
  7946) and Cilium node health pings (ICMP echo) between nodes with no rule.
  All three are now allowed. After that, a short audit window showed only the
  denial probes as would-deny: `10.0.2.2 →` 6443, 6447, 10250 and **udp
  8472** on both nodes, which is also the receiver-side positive control for
  the UDP probe.

Defects found and fixed during the run (all pilot tooling unless noted):

- **`/etc/default` does not exist** on Bluefin's factory `/etc`; writing
  `/etc/default/kubelet` failed and the prep unit retried every 30 s. The
  script creates the directory.
- **`homelab.conf` had no trailing newline,** so appending glued two settings
  into `HOMELAB_KURED=noHOMELAB_K8S_SERVICE_HOST=…`: Cilium fell back to the
  FQDN as its API host and the kured value was corrupt (kured happened not to
  deploy). The render now ends the template with a newline and the script
  checks before appending. The running control plane was repaired in place
  (applier re-run; Cilium rolled out with the tailnet IP) because a rebuild
  would have registered a second tailnet device and renamed the node.
- **Tailscale used the pod network as a "direct" path (tunnel in a tunnel).**
  See finding F5.

## Phase 3 — 2026-11-21 (in progress)

Design: [bluefin-server-pilot-phase3.md](bluefin-server-pilot-phase3.md).
Runs on the Phase 2 cluster until step 6 rebuilds it.

| Step | Result | Evidence |
| --- | --- | --- |
| 0 Unsigned sysext | pass | `pilot-lvm2_26.11.2506.raw` (EROFS, built by `mise bluefin:pilot:lvm2-sysext` from Alpine `lvm2-static` 2.03.32-r0, apk sha256 `ee262d61…`) merged by `systemd-sysext refresh` with the release's own extensions; `lvm version` 2.03.32 from `/usr/bin/lvm`; cluster stayed `Ready` through the refresh. The release's own sysexts are plain EROFS images too (no dm-verity signature): their trust comes from sysupdate's `SHA256SUMS.gpg`, so the static-path fallback was not needed |
| 0 Create | pass | PVs on `virtio-bluefin-data1/2` (checked empty with `blkid -p` first), VG `pilot_data` (2 PVs), LV `data` 15.99 GiB linear across both (bow's shape), ext4 label `pilot-data`, filesystem UUID recorded for the mount unit; fixtures (32/16 MiB media files, 256 MiB random, a hardlink pair across `Downloads/`→`Movies/`) written only after `findmnt` matched that UUID; a second `create` refuses. One creation-only quirk: the LV was made by our lvm with udev rules off and formatted afterwards, so `/dev/disk/by-uuid` appeared only after `udevadm trigger --action=change` |
| 0 Activation at boot | pass, **not by the initrd** | after reboot: `pilot-lvm-activate.service` activated the VG at 9.4 s, mounted 9.45 s, kubelet started 10.2 s; fixtures and hardlink inode intact. The initrd did nothing (no `pvscan` line), although the disks appeared there at 2.46 s: see F7 |
| 0 Missing disk | pass (pod half pending step 3) | booted with `--without-data 2`: lvm `Refusing activation of partial LV pilot_data/data` (missing PV, last on `/dev/vdc`), the unit failed after its minute of retries, the mount failed at 97 s (`dependency`), kubelet ran, both nodes `Ready`, `/var/lib/pilot-data` on the root disk empty. Disk reattached: same VG/LV UUIDs, fixtures intact |
| 1 Root and first sync | pass | `HOMELAB_ARGOCD_ROOT_REPO/REVISION/PATH` = this repository, `main`, `provisioning/bluefin/gitops/apps`; applier re-run (24 s) created `homelab-root` (template: `selfHeal: true`, `prune: false`), which created `pilot-sync-fixture`; both `Synced`/`Healthy` with no manual sync |
| 1 Pushed change, template defaults | **miss**: 412 s (threshold 300 s) | revision 1→2: Argo CD synced at +377 s, Reloader rolled the pod 1 s later. Cause: the controller's comparison expiry (`timeout.reconciliation` default 120 s plus up to 60 s jitter) stacked on the repo-server's cache of what `main` resolves to (`--revision-cache-expiration`, 3 min): the refresh at +158 s still saw the old commit, the next came at +376 s. Worst case at defaults ≈ 7 min |
| 1 Pushed change, tuned | pass: 196 s | `argocd-cm` `timeout.reconciliation: 60s`, `timeout.reconciliation.jitter: 10s` (keys the template does not set, so the applier's server-side apply should leave them: re-checked in step 2), controller restarted. Revision 2→3 in 196 s; worst case ≈ 3 min cache + 70 s ≈ 4.2 min. The revision cache itself has only a command-line flag (no `argocd-cmd-params-cm` key, no env var), and the template owns the repo-server's args, so it stays at 3 min. Production alternative: a git webhook, which needs the Argo CD API reachable from GitHub |
| 1 Hand edit | pass: 13 s | ConfigMap `revision` and Deployment `replicas` (3) changed with kubectl; both reverted by self-heal 13 s later. Reloader rolled the pod for the edit and again for the revert (expected churn: an annotated workload restarts on any drift of its ConfigMap) |
| 1 Broken manifest | recorded | a ConfigMap with list-valued `data` pushed: `OutOfSync`/**`Healthy`** after ~2.8 min, auto-sync then retried 5 times with backoff for 5.5 min before recording `SyncError` (the API server's unmarshal message) and a `Warning` `OperationCompleted` event. During the retries the application list shows only `OutOfSync`; the running workload was untouched. After the revert: `Synced`/`Healthy` 119 s after the push, but `operationState.phase` stays `Failed` (no new sync ran because live already matched), so "last sync failed" outlives the fix until the next real sync. Alerting on sync failure has to key on the `SyncError` condition or the event, not on health |
| 2 Key and KSOPS | pass | pilot-only age key generated in memory into the `bluefin-pilot` vault (item `sops-age-key`; public key in `.sops.yaml`, rule `provisioning/bluefin/gitops/.*\.sops\.yaml$`, only `data`/`stringData` encrypted). `mise bluefin:pilot:bootstrap`: key Secret from the vault on stdin, `argocd-cm` (`kustomize.buildOptions`, polling) and the repo-server patch (KSOPS v4.5.1 init container, pinned by index digest) by server-side apply under field manager `pilot-bootstrap`. Encrypted fixture synced 197 s after the push; consumer logged the expected sha256 prefix |
| 2 Rotation | pass: 43 s, and 84 s under server-side apply | revision 1→2 pushed: Argo CD synced at +7 s, Reloader rolled the consumer, new prefix logged at +43 s (lucky phase of the 60 s poll). Revision 2→3 (after switching to server-side apply) +84 s. No manual step |
| 2 No accidental disclosure | pass, one finding | Every value, plain and base64, scanned (patterns over stdin, never argv): 0 matches in git history (all refs, all patches), `kubectl get events -A`, the logs of every pod in `argocd`, `pilot-secret` and `reloader`, and the whole journal since boot. Argo CD's API views mask the Secret (`++++++++`, 0 matches): `/manifests` (behind `argocd app manifests`), the UI resource view and `/managed-resources` (the diff view). Authorised plaintext, by design of the model: the repo-server renders the decrypted Secret and its manifest cache (redis) holds it. **Finding:** with Argo CD's default client-side apply, the decrypted `stringData` sat **in plaintext** in the Secret's `kubectl.kubernetes.io/last-applied-configuration` annotation (Argo's views mask it, but any reader of the Secret, or of a backup or an etcd dump, gets plaintext beyond `data`). Fixed with `ServerSideApply=true` on the Application: the next real sync (the rotation) was an `Apply` and removed the annotation with no manual step. Every KSOPS Application should sync server-side. A slip: one check printed 30 characters of revision 2's base64 into the local session; revision 3 retired that value |
| 2 Template re-apply and reboot | pass | Before, after `systemctl restart bluefin-homelab-apply` (Result `success`) and after a control-plane reboot (applier `success` again): repo-server keeps the init container, both mounts and `SOPS_AGE_KEY_FILE`, `argocd-cm` keeps all three keys, the Deployment's generation stays 2 (the template's server-side apply did not even roll it), and a hard refresh still renders the encrypted app `Synced`/`Healthy`. The data LV mounted again on the way |
| Add-on teardown (before step 4) | pass | `HOMELAB_ARGO_WORKFLOWS/MCP/KUBESTELLAR_CONSOLE=no`, then `kubectl delete -f` of each add-on's own manifests from the merged sysext (a server dry run first listed only their objects; Argo CD's CRDs untouched) and the Phase 2 fixture namespaces. Stayed gone across a reboot (applier `success`). CRDs 57 → 49; control-plane memory available 3794 → 4976 MiB, mostly `kube-apiserver` (1787 → 1040 MiB) |
| 3 Static volumes | pass | `platform/static-volumes`: StorageClass `pilot-static` (no provisioner), PVs pre-bound by `claimRef`, `Retain`, node affinity; each bound only to its named claim. Check pod (`fixtures/static-volume-check.yaml`, UID 1000 like MediaManager): fixture checksums via the rw `video/` volume; existing hardlink pair one inode; a new `Downloads/`→`Movies/` hardlink works; the ro Movies/TVShows volumes see the same files, mounted `ro`, and refuse writes (`Read-only file system`). MediaManager's own `run_filesystem_checks()`: "Successfully created test hardlink in TV directory", no cross-device error |
| 3 Missing disk, pod half | pass | boot with `--without-data 2` and the workloads present: every consumer refused with `MountVolume.NewMounter initialization failed … path "/var/lib/pilot-data/…" does not exist` (Jellyfin 3 volumes, MediaManager 2, postgres 1), pods `0/1`; the root disk's `/var/lib/pilot-data` empty; cluster and all Applications healthy. Disk reattached: all three pods back with no manual step, 143 s after QEMU start |
| 4 Readiness and gating | pass (MediaManager/postgres/Jellyfin) | production image pins; postgres `Ready` +32 s, MediaManager and Jellyfin +83 s, all 12 migrations on the first try, zero restarts. Gate test: postgres scaled to 0 and MediaManager's pod deleted: the new pod sat in `Init:0/1` for 150 s (init container `wait-for-db` retrying an authenticated `select 1` every 3 s); postgres back: gate passed in 4 s, `Ready` 17 s later, init and app restarts 0 |
| 4 Database survival | pass | 1000 rows in `pilot_marker`, `md5(string_agg(…))` identical after deleting the postgres pod, after a control-plane reboot, and after the unplanned hard kill below |
| 4 Buildbarn reachability | pass | Argo CD synced the Tailscale operator (chart 1.104.7) and Buildbarn; the operator's OAuth Secret from the vault via the bootstrap. Proxy device `bluefin-pilot-bst` (`tag:bluefin-pilot-svc`, address inside the `ipPool`). Blockers found and fixed: F9 (the proxy's CGNAT drop rule ate the API server's replies, so containerboot hung before installing its DNAT; and a `tag:bluefin-pilot → tag:bluefin-pilot-svc` grant made the nodes peers and pulled the API route into the proxy's tailnet, removed) and F10 (Cilium socket LB in pods; `bpf-lb-sock-hostns-only`), which also removes F9's cause, so F9's temporary node attribute was dropped again. Final policy: tags, ipPool, no extra node attribute, no pilot→svc grant. Then from the workstation over the tailnet: TLS on 7981 and 7982 verifies against the pinned pilot cert (`Verify return code: 0`, ALPN `h2`), a wrong name fails (`62 hostname mismatch`); in-cluster both ports serve the same cert (fingerprint match). Both nodes `Ready`, all Applications `Synced`/`Healthy` after the Cilium agents restarted |
| 4 Buildbarn round trip | pass | `mise bluefin:pilot:bst-roundtrip` (harness written by Codex, reviewed; BuildStream 2 in krytis's pinned `bst2` image, krytis's remote layout: index on 7981, storage on 7982, `server-cert` + `access-token`), pilot JWTs minted from the vault key into mode-600 files. Push: a 64 MiB import artifact built and pushed with the push token (30 s). Pull: into an empty cache with the pull token, checked out, sha256 equal (2 s). No token: both remotes `UNAUTHENTICATED: No valid authorization header containing a bearer token provided`. Pull token writing: upload refused with gRPC 7 (`PERMISSION_DENIED`), a fresh-cache pull reports `SKIPPED Pull` (not on the server). 150 MiB blob: refused with gRPC 3 (`INVALID_ARGUMENT`), the per-blob ceiling (~108 MiB, CLAUDE.md BUG-006 class), not stored. Wrong hostname (IP literal): `Peer name … is not in peer certificate`. First run's four negatives were harness misjudgements (BuildStream 2 prints gRPC codes as numbers, reports a server miss as `SKIPPED Pull`, and exits outside 1–124 when every remote fails to initialise); criteria fixed and rerun, all six `PASS` |
| 5 Scheduled backup | pass | CronJob `*/30`, one pod: init `dump` (production `dump.bash`, byte-identical copy checked by `mise check:bluefin-dump-copy`) then the production restic image to a REST server on the worker's own backup disk (ext4 `pilot-backup`, PV `pilot-restic`). Scheduled runs 14:30 (306.7 MiB, 2:01) and 15:00 UTC (84 KiB, 2 s) each saved a snapshot after their dump; the 16:30 run missed during the outage below ran at 16:41 when the cluster came back. Daily retention pruned the same day's earlier snapshot (the production gotcha) |
| 5 Freshness guard | pass | the CronJob's pod with a wrong `PGPASSWORD` (`fixtures/backup-restore-check.yaml`): dump init container exit 2 (`password authentication failed`), the restic container never started, snapshot count 2 → 2, the previous dump set byte-identical, no `.tmp` left. First attempt invalid: the fixture named the dump-script ConfigMap without kustomize's hash suffix and never left `PodInitializing`; that ConfigMap now has no hash suffix (each CronJob run is a new pod anyway) |
| 5 Check and restore | pass | `restic check --read-data`: 21/21 packs, no errors. `restore latest` (snapshot `fef7a07e`, 306.5 MiB) into an empty volume: every fixture checksum, the hardlink pair still one inode, the dump set present; the dump loaded into a fresh postgres with per-table counts **exactly** `counts.post`, `pilot_marker` 1000 rows |
| Unplanned: hard kill | recorded | 15:15 UTC: the **workstation** ran out of memory (an 11 GiB `zig` build, Steam) and its OOM killer killed the control plane's QEMU. Restarted 16:41: XFS root and the LV's ext4 replayed their journals, postgres ran crash recovery (`not properly shut down; automatic recovery`), marker rows and fixtures intact, media pods `1/1` 188 s after start, the missed backup ran. For a real host: an outage of the API server's host does nothing worse than a reboot to this stack |
| 6 Reinstall and import | pass, with deviations | Before (19:31 UTC, 11-21): VG `pilot_data` qhhzsl-…, LV uqN24A-…, PVs QyWPEG-…/benMps-…, ext4 ae24577e-…, fixtures manifest 9220bb1e…, 1000 marker rows md5 2b7fc90e…, two restic snapshots on the worker's disk, all 8 Applications healthy. Both VMs stopped, all four tailnet devices deleted (nodes, operator, proxy), both OS disks reinstalled, data disks untouched. **Deviations on the way, each now fixed in the tooling:** (a) Ignition with the 2.2 MB sysext embedded exceeded QEMU's 128 KiB argv string limit as an SMBIOS credential, and then systemd's 1 MiB credential limit as a fw_cfg credential (`larger than allowed limit (1.3M > 1M), skipping`, so that boot had no Ignition and was discarded): Ignition now goes by fw_cfg file and carries only the small units, and the bootstrap delivers the sysext over SSH by checksum; (b) F11, the first good install upgraded itself to 26.11.2641 and was discarded, pinned and reinstalled; (c) the bootstrap's audit-mode check expected `policy-enabled=ingress` where audit mode reports `audit-ingress`, failed after its retries and restored the enforcing fixture as designed; fixed, and `--reapply-firewall` re-ran audit → 120 s of no audit verdicts → enforce, verified on every agent; (d) the add-ons came back with the fresh `homelab.conf`: render now sets them off. After: one boot each on 26.11.2506, Kubernetes v1.35.10, control plane `Ready` 535 s and worker 76 s after QEMU start; the bootstrap delivered the sysext, the VG activated and **mounted with the same UUIDs** (PV, VG, LV, filesystem), fixtures and hardlink inode intact, the production data-disk initialisation never run; **every Application `Synced`/`Healthy` 20 min 54 s after the control plane's first boot** (threshold 30 min), including the failed and repeated firewall step; all static PVs bound to their named claims again; marker rows md5 identical; static-volume check 7/7; restore check from snapshot `c0843f9b` (taken before the reinstall, from the worker's surviving repository): `restic check --read-data` clean, fixtures, dump load, exact counts, markers all pass; host firewall enforcing, Phase 2 denial probes all blocked (6443 and 10250 no answer, no 6447 connection from `10.0.2.2`, 8 UDP 8472 probes `action deny`); all four tailnet names reused; Buildbarn TLS on both ports and the BuildStream round trip 6/6. Manual steps beyond the bootstrap: deleting the four devices, relaying the new join passphrase into the vault, and the four fixes above |

## Phase 4 — 2026-11-22/23 (in progress)

Design: [bluefin-server-pilot-phase4.md](bluefin-server-pilot-phase4.md),
decisions recorded 2026-11-22.

### E6 baseline: collecting

Minimal Traefik access log on flutterina since 2026-11-22 19:10 UTC (commit
`fb96c3e`): materia applied it cleanly and restarted only `traefik.service`;
badger loaded; lines carry only start time, duration, router, status and
protocol. First rate ~0.25 req/s (~20k lines/day) against a 3 GB journal
holding ~5 weeks. Collection ends ~2026-11-29.

### E1.2 rehearsal: pass, 2026-11-23

`bluefin-pilot-edge` installed with the usual two stages into an
80,000,000,000-byte raw disk, credentials staged on its ESP with
`mise bluefin:pilot:esp-creds`, then booted by `vm rehearse`: fresh OVMF
variables (Setup Mode), virtio-scsi disk, no SMBIOS or fw_cfg credentials,
one user-mode NIC. Three boots:

1. **Fail:** `bluefin-ignition-credentials` failed at step CREDENTIALS
   (`Invalid argument`); the node rebooted in a loop. Cause in F12.
2. **Fail (partial):** Ignition, the release pin, the tailnet step and the
   join unit all worked; SSH refused the key for the locked root (F13).
3. **Pass**, with both fixes:
   - SSH up ~20 s after start; `systemd-creds list` shows all six ESP
     credentials imported; root's field `*`; release 26.11.2506; 9 transfers
     pinned, none `releases/latest`; IPv6 disabled; no TPM.
   - Firmware `UEFI 2.70`, **Secure Boot `disabled (setup)`**: the installed
     disk never enrols keys (its `loader/keys` is empty, `loader.conf` has
     no `secure-boot-enroll`). F4 answered for an installed disk.
   - Tailnet step logged in with the single-use key (~40 s); kubelet line
     carries `--node-labels=pilot.bluefin/edge=true
     --register-with-taints=pilot.bluefin/edge=true:NoSchedule`.
   - Bootstrap by hand (E2): console password via `chpasswd -e` over SSH
     stdin; join passphrase appended to `/etc/bluefin/homelab.conf` over SSH
     stdin and the join unit restarted; `pilot.tailscale-authkey.cred`
     deleted from the ESP, which is mounted at **`/boot`**.
   - Node `Ready` ~30 s later, first registration already labelled, tainted
     (`pilot.bluefin/edge=true:NoSchedule`) and on its tailnet IP; only
     DaemonSet pods (Cilium, cilium-envoy) scheduled. The join removed the
     passphrase from `homelab.conf`.
   - Reboot with the auth key gone: back in ~25 s, new boot ID, no new
     tailnet login (saved state), no failed units, Node `Ready` again; ESP
     holds only the five non-secret credentials.

Node deleted from the cluster and VM stopped afterwards; its tailnet device
and the spent key are to be removed in the admin console.

### Edge bootstrap: pass, 2026-11-23

`mise bluefin:pilot:edge-bootstrap --via local` against a fresh rehearsal
boot (new single-use key, vault item `root-console-password-edge`): console
password set, join passphrase delivered, Node `Ready` with label, taint and
tailnet InternalIP, ESP auth key removed, in 34 s. A second run changed
nothing (every step reported done); after a reboot the password held (the
ESP's `*` credential is first-boot only), no failed units, and a third run
again changed nothing. A `--resume` boot of a disk whose tailnet device had
been deleted cannot rejoin (`tailscale status` shows it offline; the tailnet
step fails on MagicDNS and kubelet waits), so the rehearsal node is kept as
the stand-in edge for the E3 firewall and workload work.

### E3 public-ingress policies: pass on the rehearsal, 2026-11-23

Three `CiliumClusterwideNetworkPolicy` objects in
`fixtures/edge-public.yaml`, each selecting `pilot.bluefin/edge=true`: the
edge's host endpoint carries that node label (`k8s:pilot.bluefin/edge=true`
beside `reserved:host`), so the label selector matches and the cluster-wide
fallback was not needed. `mise bluefin:pilot:edge-fw-check --via local` puts
hostNetwork agnhost listeners on 443/tcp+udp, 51820/udp, 21820/udp, 80/tcp
and a control on 8080/tcp, probes them from the workstation through QEMU
forwards (source 10.0.2.2, Cilium `world`), and judges each by the edge
agent's `policy-verdict`/drop records:

| Round | Policies | Result |
| --- | --- | --- |
| 1 | `pilot-host` only | all six unreachable, all six `deny` verdicts: pass |
| 2 | + public, gerbil, acme-http | five answer with `allow`, control 8080 `deny`: pass |
| 3 | + public only | 443 tcp/udp `allow`, the other four `deny`: pass |

The home nodes' host endpoints carry no rule derived from a `pilot-edge-*`
policy. The cluster bootstrap now applies `pilot-edge-public`; the gerbil and
acme-http policies go on and off with their arm. Still for Hetzner: the same
check `--via public`, where the provider firewall is in front (the check
fails any port that gets neither an answer nor a Cilium record).

## Findings

**F13 — A locked root refuses SSH keys.** Root ships as `!unprovisioned`
and Bluefin's sshd runs without PAM, so with no password credential every
key login is refused, on the user-net forward and the tailnet alike. A
headless node needs root's field set to `*` (no password login, not
locked) as a `passwd.hashed-password.root` credential, which is not a
secret; upstream's own unattended recipe does the same
(`usb-installer.md`). The local VMs never hit it because they always got a
real hash.

**F12 — ESP credentials must stay in `systemd-creds`' base64 text form.**
A base64-decoded (binary) envelope is rejected with `Invalid argument`,
both by the node's initrd (`bluefin-ignition-credentials` fails at step
CREDENTIALS and the node reboot-loops) and by the workstation's own
`systemd-creds decrypt`. Upstream notes the one exception:
`systemd-ssh-generator` reads `ssh.listen` only in binary form.


**F11 — A fresh install does not stay on the release it was installed from.**
Step 6 reinstalled the control plane from the pinned v26.11.2506 installer,
with `systemd-sysupdate.timer` and `systemd-sysupdate-reboot.timer` masked.
On first boot `bluefin-sysext-fetch.service` logged "fetching for
26.11.2506: …" and then fetched "through systemd-sysupdate (features: …)",
which read `releases/latest/download/SHA256SUMS`, logged `Selected update
'26.11.2641' for install`, wrote the 270 MB `bluefin_usr_26.11.2641` into the
B slot, and the node rebooted into 26.11.2641 four minutes after install
(boot −2 19:47–19:51 UTC; 2506 stays as the fallback entry). Phases 1 and 2
did not show it only because 2506 was then the newest release. Consequences:
an install is not reproducible (bow reinstalled next month would run an
untested release), masking the sysupdate timers does not prevent it, and a
version-locked sysext of our own (`pilot-lvm2`, `VERSION_ID=26.11.2506`)
stops merging. Also on that boot `pilot-lvm-activate.service` failed (the
sysext had not been delivered yet), which failed
`systemd-boot-check-no-failures.service`, the unit Bluefin's boot counting
watches: a data-disk problem must not count against the OS image. **Pinned
(2026-11-22):** Codex read the v26.11.2506 source: the helper's installed-node
fallback runs an unversioned `systemd-sysupdate update` over the whole host
target (`/usr`, verity, UKI and the enabled sysexts, all on
`releases/latest/download/`), then itself calls `systemctl reboot` when a newer
version is pending (`sysextfetch.go:308–327`; documented upstream, so it is
intended, not a bug); confirmed in the journal (`the release is newer than
26.11.2506; its sysexts arrived with it, rebooting into it`). Fix: render
writes full copies of the nine host transfers to `/etc/sysupdate.d/` (they
shadow `/usr/lib/sysupdate.d/`), each byte-identical to the 2506 vendor file
except `[Source] Path=…/releases/download/v26.11.2506/`
(`provisioning/bluefin/sysupdate-pin/`). Reinstalled with it: one boot only,
`Selected update '26.11.2506' is already installed, but incomplete.
Repairing.`, the six sysexts fetched at 2506, the only boot entry 26.11.2506,
no failed units. Advancing the pin means re-copying the new tag's transfers.
For bow the same pin is needed before any reinstall. The activation unit now
skips (exit 0, with a message) while no `lvm` is installed, so it cannot fail
`systemd-boot-check-no-failures`; a missing PV still fails it. Open for
production: a genuinely missing data disk still counts against the OS image
in Bluefin's boot counting.

**F10 — With Cilium's kube-proxy replacement, a pod that forwards packets to a
ClusterIP needs per-packet Service translation.** KPR turns socket
load-balancing on for every pod ("Socket LB Coverage: Full", even with
`bpf-lb-sock=false`), and Cilium then skips per-packet translation in pods.
The Tailscale operator's L4 proxy DNATs tailnet traffic to its Service's
ClusterIP and forwards it: those packets were never a socket `connect()`,
so nothing translated them (39 forwarded, 2 back; clients hung). Fix:
`bpf-lb-sock-hostns-only: "true"` in the pilot's `CiliumNodeConfig`
(Coverage then "Hostns-only"), which Tailscale's operator documentation
requires for Cilium KPR. Cost: pods use per-packet load-balancing instead of
socket rewriting; the host keeps the socket path. It also removes F9's cause:
replies to pods now arrive rev-NATed as `10.96.0.1`, so the proxy's CGNAT drop
rule never sees them (tested by removing F9's node attribute).

**F9 — An in-cluster Tailscale proxy cannot reach a Kubernetes API that is
addressed by its tailnet IP.** Phase 2 made the API endpoint the control
plane's tailnet address (`100.68.x`, inside CGNAT 100.64.0.0/10). The Tailscale
operator's L4 proxy (v1.104.7, kernel mode, nftables) installs Tailscale's
standard anti-spoofing rule in its own pod: `iifname != "tailscale0" ip saddr
100.64.0.0/10 drop`. Cilium's socket load-balancing connects the pod straight
to the backend, so the API server's replies arrive on `eth0` with a CGNAT
source and are dropped (counter 85 → 90 during one probe). The proxy's first
Secret write happens before its rules exist and works; the post-login
`device_id` PATCH then hangs forever (goroutine dump: `StrategicMergePatchSecret`
in `roundTrip`, `containerboot/main.go:874`, the kube client has no timeout),
so containerboot never reaches `Installing proxy rules`: no DNAT, the device
is `Running` on the tailnet but refuses every connection, the Service never
gets a LoadBalancer status, and the pod is `Ready` with no error logged.
Diagnosis: Codex read the v1.104.7 source and narrowed it to the post-login
calls; the dump and the nft counters pinned it. First fix: the tailnet node
attribute `disable-linux-cgnat-drop-rule` (nodecap.go:377), scoped to
`tag:bluefin-pilot-svc`. **Superseded by F10 (2026-11-21):** with Cilium's
socket load-balancing host-only, the pod reaches the API by per-packet
translation and the replies arrive rev-NATed from `10.96.0.1`, not from the
CGNAT backend address. With the attribute removed from the policy and the
proxy restarted, the drop rule is back (`… 100.64.0.0/10 … drop`, 0 packets),
containerboot logs `Installing proxy rules` / `Startup complete`, and TLS on
both ports verifies. So F10's setting alone suffices; the attribute is a
fallback for a cluster that keeps socket LB in pods. The same applies to anything running kernel-mode
Tailscale inside a pod of a cluster addressed by tailnet IPs. The host
Tailscale avoids it only because Phase 2 runs it with netfilter off.

**F8 — MediaManager logs its generated admin password in plaintext.** On an
empty database it creates a default admin even when `admin_emails` is set,
and prints the password to stdout (`create_default_admin_user(): Password
…`). In Kubernetes that is the container log, readable by anyone with
`pods/log` and kept by any log shipper. The production component's comment
("Without it MediaManager mints a random admin and prints the credentials")
implies `admin_emails` avoids this; on 1.12.3 it does not, so bow's journal
probably holds its first-start password too. Also: an `admin_emails` address
on a special-use domain (`.invalid`) is rejected by its email validation.

**F7 — Bluefin has no usable LVM outside the initrd, and the initrd never
autoactivates.** Upstream removed lvm2 from `/usr` (projectbluefin/server#487,
2026-10-17: nothing in the image used it) and kept `lvm`, `pvscan`,
`vgchange` and `69-dm-lvm.rules` in the initrd (#489). But the
freedesktop-sdk lvm2 build compiles in `global/event_activation = 0` (the
initrd's `lvm.conf` documents it as the automatic default, with nothing
overriding it), so the rule's `pvscan` answers `LVM_EVENT_ACTIVATION=0` and
nothing is ever activated: confirmed by running the initrd's own `lvm`
(2.03.43) with its own config and libraries on the node. So an existing VG
(bow's two-NVMe `vg_data`) needs tooling we supply: the pilot's `pilot-lvm2`
sysext (static lvm) and `pilot-lvm-activate.service`, ordered before the data
mount and kubelet. It works, but it is a self-maintained binary on the boot
path of bow's data. Production options: keep our sysext (rebuild per release,
since its `extension-release` is locked to the image version like upstream's),
or ask upstream for an lvm2 feature/sysext with activation (needs the
operator's permission). No upstream issue mentions lvm2; ZFS ships as a signed
`zfs` feature but is coupled to the kernel (#678).


**F6 — The homelab Cilium runs IPv4-only, so the host firewall does not
cover IPv6 at all.** The homelab manifest sets `enable-ipv6: 'false'`; Cilium
attaches no IPv6 policy. The local VMs have only link-local and QEMU's
`fec0::` IPv6, so this was not exercised. The Hetzner node has a public IPv6
address: Phase 4 must test IPv6 reachability of 6443/6447/10250/8472
explicitly and decide what protects IPv6 (the provider firewall alone, which
has no IPv6 rules for those ports, or another host layer).

**F5 — Host Tailscale on a Cilium node routes itself through the pod
network unless prevented.** Tailscale advertises every local interface
address as a direct endpoint and skips only ZeroTier (`zt*`) and NetBird
(`wt0`) interfaces (`net/netmon/state.go`, `isProblematicInterface`,
v1.104.7). It therefore advertised Cilium's `cilium_host` address
(`10.244.0.190`), and the worker reached the control plane `direct
10.244.0.190:41641`: WireGuard inside Cilium's VXLAN inside WireGuard, at
**739 ms** per ping, unstable (a ping alternated between a DERP pong and a
timeout). WireGuard datagrams of ~1,360 bytes into the 1230-byte pod route were
fragmented, which produced the connectivity test's ~12,500 "First logical
datagram fragment not found" drops and ~2 million fragmented packets, all
dated to that window (the counters stayed flat afterwards). The worker's
Cilium agent also lost its API connection in that window (19:51:55–19:52:40
UTC). [INFERENCE] the loop caused it. There is no supported Tailscale setting
to exclude an interface, and Bluefin has no `nft`/`iptables`. Fix:
policy routing that makes the pod and service ranges unreachable for traffic
carrying Tailscale's socket mark (`ip rule … fwmark 0x80000/0xff0000 to
10.244.0.0/16 prohibit`, same for `10.96.0.0/12`), installed by a
`tailscaled.service` drop-in (`provisioning/bluefin/tailscaled-no-pod-paths.conf`)
so it is in place before Tailscale picks paths. After it, the path is DERP at
~49 ms. The same drop-in now also installs `unreachable 100.64.0.0/10` in the
main table (step 4's leak block, made permanent). **Any production node running host Tailscale beside Cilium needs this
guard.**


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
