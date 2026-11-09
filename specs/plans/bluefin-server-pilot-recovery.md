# Bluefin pilot: recovery procedures and restore inputs

Phase 0 step 4 of [the pilot plan](bluefin-server-pilot.md). Results and
evidence: [results](bluefin-server-pilot-results.md). Written 2026-11-09
against release v26.11.1701 and the upstream docs at commit
`b928b45bd7a0633de04febf3d654fa084c182e00` (`docs/skills/usb-installer.md`,
`ddi-installer.md`, `secure-boot-keys.md`, `homelab-profile.md`).

Scope: the disposable pilot machines only. Production hosts are never a
recovery dependency, and nothing here touches bow or flutterina.

## What Bluefin gives you to recover with

These upstream behaviours decide the procedures below:

- **No emergency shell.** A failed boot prints a failure summary on every
  console and reboots (`emergency.service.d/10-reboot.conf`). That is what
  makes boot counting work unattended. There is no shell to repair a broken
  boot from.
- **Automatic A/B fallback.** Boot entries are counted
  (`bluefin-server-<ver>+3-0.efi`). After three failed boots of a new image,
  systemd-boot boots the previous UKI. At most two UKIs are kept.
- **Boot health gate.** A boot-counted boot only counts as good once
  `boot-complete.target` is reached with no failed unit. Otherwise
  `bluefin-boot-deadline` reboots it (results, F3).
- **The installer is not a rescue system.** It is offline (networking masked),
  never opens an installed `/usr`, needs no login and has no shell: it asks
  which disk, confirms, erases that disk and installs. "Recovery boot from
  the installer" therefore means **reinstall**. Other disks are untouched,
  which is what Phase 3's LVM import test relies on.
- **Root is locked by default.** Root ships as `!unprovisioned`. Nodes
  installed through the installer's Homelab menu entries prompt for a root
  password on tty1 at first boot, before `sysinit.target`, and the boot waits
  for the answer. Nodes installed any other way never prompt; a
  `passwd.hashed-password.root` credential sets it instead. The homelab
  Ignition templates add key-only root SSH; `sshd` is off unless the
  template enables it (it does).
- **Consoles.** The installed disk UKI uses the serial port as `/dev/console`;
  tty1 is the monitor. Both show the login banner (hostname, addresses,
  update status).
- **Secure Boot is required by the installer, with Bluefin's own keys.** In
  Setup Mode it offers to enroll the stick's PK/KEK/db
  (`loader/keys/auto/`). In VMs systemd-boot does this by itself
  (`secure-boot-enroll if-safe`), which is what happened on melog (results,
  F4). Afterwards the firmware trusts **only** the Bluefin keys. Unattended
  installs cancel without touching a disk unless Secure Boot is on with those
  keys, or a `bluefin.install-allow-insecure-boot` credential says `1`.

## Pilot policy (applies to every procedure)

1. **Every pilot node gets a console root password.** Install through the
   installer's Homelab entries and answer the tty1 prompt, or pass a
   `passwd.hashed-password.root` credential. Without it, a node whose SSH or
   tailnet path is broken can only be reinstalled. Store it as described
   under "Restore inputs".
2. **Recovery is reinstall, not repair,** unless the boot menu or console
   gets the node back in minutes. Pilot data that must survive lives on
   separate data disks or in a backup, never only on the OS disk.
3. **Record every recovery** in the results file: what broke, which
   procedure, elapsed time. Recovery times feed the Phase 5 thresholds.

## Procedure L — local VMs on melog

Run files live under `~/.cache/bluefin-pilot/vm/<vm>/` (see the UEFI test in
the results for the QEMU command line). Each VM has its own OVMF VARS copy,
which holds its enrolled Secure Boot keys.

- **L1 Console access.** The VGA console via QMP `screendump` (or run with a
  GTK/VNC display), and the serial console via `-serial file:` or
  `-serial mon:stdio`. To check access without networking, start with
  `-nic none` (or set the link down with QMP `set_link`) and log in as root
  on tty1 or serial with the console password.
- **L2 Boot menu.** Interrupt systemd-boot with a key press at the menu (VGA
  console, or `-serial mon:stdio`) to pick the previous UKI by hand or
  "Reboot Into Firmware Interface". From a running node, `bootctl
  set-oneshot <entry>` followed by `systemctl reboot` does the same without
  a console.
- **L3 Reinstall (the installer "recovery boot").** Attach the verified
  installer image read-only through a fresh qcow2 overlay as a USB disk with
  `bootindex=0`, keep the OS disk attached, boot, pick the Homelab entry,
  choose the OS disk, confirm. Data disks stay attached and untouched. Then
  re-render and re-apply the node's Ignition, rejoin, and re-run the phase's
  verify commands.
- **L4 Start over.** Stop the VM (QMP `quit`), delete its qcow2 disks and
  VARS copy, and recreate from the run script. Nothing outside the VM
  directory depends on it.
- **L5 Secure Boot reset.** Copy a fresh VARS template over the VM's VARS
  file to return the firmware to Setup Mode; the next installer boot
  re-enrolls.

## Procedure H — the Hetzner pilot node (cpx22)

The pilot firewall (Phase 0 step 5) has no public SSH rule. Recovery access
is the Hetzner console first, the tailnet second.

- **H1 Console.** `hcloud server request-console bluefin-pilot-edge` prints
  a VNC-over-WebSocket URL and password valid for a short time; the Hetzner
  Cloud web console does the same. This is the monitor (tty1). Log in as
  root with the console password. Works with `tailscaled` stopped and with
  the firewall closed, which is the Phase 4 step 3 check.
- **H2 Boot menu.** Through the H1 console at power-on, same as L2. A
  `hcloud server reset` gives a cold boot to catch the menu.
- **H3 Rescue system.** `hcloud server enable-rescue bluefin-pilot-edge
  --type linux64 --ssh-key <pilot key>` then `hcloud server reboot`. This
  boots Hetzner's Linux rescue image from the network, with the server disk
  unmounted. Reaching it over SSH needs a temporary firewall rule for tcp/22
  from the operator's IP only; remove the rule afterwards. Use it to copy
  data off the disk, inspect the ESP and boot entries, or write an install
  image. The rescue system is disabled again by the next reboot.
- **H4 Reinstall.** Not yet proven; Phase 4 step 1 must establish one path
  and record it here. Candidates, in order:
  1. Attach a Hetzner Volume, write the verified installer image to it from
     the rescue system, wipe the server disk's ESP so firmware falls back to
     the Volume, boot, and install onto the server disk unattended
     (credentials on the ESP or via the installer's unattended mode). Detach
     and delete the Volume afterwards.
  2. From the rescue system, write the OS image (`bluefin-server_<ver>.raw`)
     straight to the server disk and let first boot grow the partitions.
     Upstream says the OS DDI is not a ready-to-upload provider image, so
     treat this as an experiment.
  Unattended installs cancel unless Secure Boot is on with the Bluefin keys
  or `bluefin.install-allow-insecure-boot=1` is supplied. Hetzner firmware
  showed no enrolled keys, so either the enrollment holds across reboots
  (check in Phase 4: does NVRAM survive stop/start and rebuild?) or the
  insecure credential is required and recorded as a provider constraint.
- **H5 Start over.** `hcloud server delete bluefin-pilot-edge`, recreate from
  the Phase 4 procedure. Before deleting, copy off anything the results need.

## Procedure K — cluster state

- **K1 Rejoin a worker.** On the control plane, `bluefin-cluster passphrase`
  prints the current join passphrase (also on its console). Delete the old
  node object (`kubectl delete node <name>`), reinstall or reset the worker,
  and give it the passphrase in `homelab.conf` or the
  `bluefin-cluster.passphrase` credential, with `HOMELAB_CONTROL_PLANE` set.
- **K2 Control plane loss.** Restore etcd from the latest snapshot into a
  replacement control-plane VM (Phase 5 step 1 records the exact
  version-specific commands). Until Phase 5 has proven that, losing the
  control plane means rebuilding the pilot cluster from scratch.
- **K3 Workloads.** Argo CD re-syncs everything declared in git. Persistent
  data comes back from the static data disks (bow stand-in) or from the
  pilot backup repository.

## Procedure T — tailnet

- **T1 Node lost from the tailnet.** Use the console (L1/H1), check
  `systemctl status tailscaled` and `tailscale status`, and re-authenticate
  with a fresh pilot auth key if the node's state was lost. A lost state
  means a new node and a new tailnet IP: delete the old device first so the
  name is reused.
- **T2 Pilot enrollment policy (needs the tailnet admin; not applied yet).**
  - Tag `tag:bluefin-pilot`, owned by the existing provisioner tag pattern
    (see the Tailscale OAuth gotcha in `AGENTS.md`: one owner tag, one tag
    per node registration).
  - Auth keys: tagged `tag:bluefin-pilot`, **not ephemeral** (an ephemeral
    node is deleted while offline and returns with a new IP), pre-approved,
    expiring after the 7-day pilot window.
  - Grants: the operator's devices to `tag:bluefin-pilot` on tcp/22, 6443 and
    the Argo CD/UI ports; `tag:bluefin-pilot` to `tag:bluefin-pilot` on all
    ports (API, join 6447, kubelet 10250, Cilium transport). **No** grants
    between `tag:bluefin-pilot` and the production tags (`tag:server`,
    `tag:gateway`, `tag:relay`).
  - Cleanup: delete every `tag:bluefin-pilot` device and revoke the keys.

## Restore inputs

What is needed to rebuild any pilot machine, and where it lives. Nothing here
is a fleet credential; none of it goes into this repo.

| Input | Where | Notes |
| --- | --- | --- |
| Verified release artifacts | `~/.cache/bluefin-pilot/v26.11.1701/` on melog | hashes and signing-key fingerprint are in the results file, so a re-download can be re-verified |
| Rendered Ignition per node | `~/.cache/bluefin-pilot/render/` (private, never committed) | re-renderable from the templates plus the secrets below |
| Console root password per node | Proton Pass, pilot-only vault (`bluefin-pilot`) | one item per node |
| Pilot SSH key (root on pilot nodes) | Proton Pass, pilot-only vault | not the fleet `core` key |
| Join passphrase | the control plane (`bluefin-cluster passphrase`); copy into the pilot vault | changes if the control plane is rebuilt |
| Tailscale pilot auth key | Proton Pass, pilot-only vault | tagged `tag:bluefin-pilot`, expires with the pilot |
| Pilot GitOps secrets key | Proton Pass, pilot-only vault | not the fleet age key |
| Test backup repository credentials | Proton Pass, pilot-only vault | test repository only |
| Hetzner token | existing `hetzner` item via `fnox get HCLOUD_TOKEN` | pilot resources carry the `pilot=bluefin` label |
| etcd snapshots | from Phase 5, stored off the control plane | path recorded in the results |
| Run scripts and OVMF VARS | `~/.cache/bluefin-pilot/vm/<vm>/` | VARS holds the enrolled Secure Boot keys |

A separate Proton Pass vault keeps the materia PAT (read-only on the
`materia` vault) from reading pilot secrets and the reverse. Creating the
vault and items is an operator step.

## Verification status

| Check (plan Phase 0 step 4) | Status |
| --- | --- |
| Procedures and restore inputs recorded | done (this file) |
| Console access with guest networking disconnected | pending: needs an installed node with a console password (Phase 1), via L1 with `-nic none` |
| Recovery boot from the installer on the disposable VM | pending: needs an installed node (Phase 1), via L3, confirming the data disks survive |
| Pilot-only VPN enrollment policy | proposed (T2), not applied: tailnet admin change |
| Separate secrets | proposed (pilot vault), not created |
