# Bare-metal provisioning runbook

Provision a bare-metal Flatcar server with materia, delivered via iPXE
HTTP boot from a USB stick + a tiny HTTP server in podman on the
workstation. Designed to be runnable from a fresh checkout with no other
setup beyond `mise install` and `pass-cli login` (or equivalent Proton
Pass auth for `fnox`).

This is the second provisioning path alongside Hetzner Cloud (see
`provisioning/templates/hetzner.bu` + the `hz:*` tasks). The same materia
baseline runs on both; the difference is delivery: Hetzner passes the
Ignition config as `user_data`, bare metal uses iPXE because there's no
cloud metadata service.

The Flatcar ISO is **BIOS-only** ([Flatcar docs][1] explicitly say "UEFI
boot is not currently supported. Boot the system in BIOS compatibility
mode."), so for UEFI-only boxes we use iPXE HTTP boot instead — no
CSM/Legacy BIOS needed.

[1]: https://www.flatcar.org/docs/latest/installing/bare-metal/booting-with-iso/

## 0. Pre-flight (one-time per machine)

### Hardware checks

- [ ] BIOS: **Secure Boot disabled** (iPXE + Flatcar bootloaders are
      unsigned), boot from USB enabled.
- [ ] Disk device names confirmed from a live boot (the LVM script in
      `bare-metal.bu` reads `${DATA_DISKS}` from `server.toml`):
      ```sh
      lsblk -d -o NAME,SIZE,MODEL,TRAN   # → confirm disk names
      ip link                             # → confirm NIC name (for reference)
      ```
      If the disk names differ from what you expected, edit
      `provisioning/servers/<name>/server.toml`'s `data_disks` and re-run
      `mise ign --server-name <name>`.

### Workstation setup (one-time per machine)

```sh
# Toolchain (butane, fnox, gum, jq, yq, pass-cli, etc.)
mise install

# Proton Pass login (for fnox to fetch the age key + SSH pubkey + ping URL)
pass-cli login

# Render the Ignition config (used by ipxe:serve).
mise ign --server-name <name> --debug   # discovery boot (see step 3)
mise ign --server-name <name>           # real config (after step 5)
```

## 1. Scaffold the server

```sh
mise server:new --server-name <name> --type bare-metal
```

Creates `provisioning/servers/<name>/server.toml` with `data_disks = []`
and a `[Hosts.<name>]` entry in `MANIFEST.toml`. Commit both.

## 2. Write the iPXE firmware to USB

**Interactive (recommended):**

```sh
mise ipxe:firmware
```

Downloads `ipxe.iso` to `$XDG_CACHE_HOME/provisioning/` and `dd`s it to a
USB stick you pick from `gum choose`. The whole stick is overwritten.

**Non-interactive (manual `dd`):**

```sh
mise ipxe:download
# then follow the printed dd instructions
```

> **Why .iso?** The `.iso` includes its own hybrid MBR + EFI boot sectors
> so it boots on virtually any UEFI or legacy BIOS via CD emulation. The
> `.efi` variant needs the firmware to support direct EFI binary loading
> from USB, which not all boards do reliably.

## 3. Discovery boot (identify hardware)

Bare metal has no cloud metadata service, so you can't know the real disk
device names until you boot the box. The debug template boots Flatcar
entirely in RAM with just SSH access — no LVM, no nftables, no materia.

**Terminal 1 — render + serve the debug Ignition:**

```sh
mise ign --server-name <name> --debug
mise ipxe:serve --server-name <name> --debug
```

The serve task discovers your workstation's LAN IP, writes `boot.ipxe`
with that IP baked in, and runs a foreground `podman run nginx:alpine`
serving `boot.ipxe` + `materia-debug.ign` on `:8080`. Ctrl-C stops it.

**Target box — boot from USB and chain into iPXE:**

1. Plug the USB stick in; power on.
2. Mash the UEFI boot-menu key (Del / F2 / F10 / F12 — varies by board).
3. Pick the USB stick from the one-time boot menu.
4. At the iPXE prompt (`Ctrl-B` if you don't see one):
   ```
   iPXE> dhcp
   iPXE> chain http://<LAN-IP>:8080/boot.ipxe
   ```
   Replace `<LAN-IP>` with the IP `mise ipxe:serve` reported.

**SSH in and identify the disks:**

```sh
ssh core@<box-lan-ip>
lsblk -d -o NAME,SIZE,MODEL,TRAN   # → note the data disk device names
ip link                             # → note the NIC name (for reference)
```

Note the device names for the disks you want in the LVM `vg_data` volume
group (e.g. `/dev/nvme0n1`, `/dev/sdb`).

## 4. Fill in server.toml

Edit `provisioning/servers/<name>/server.toml`:

```toml
[bare_metal]
data_disks = ["/dev/nvme0n1", "/dev/nvme1n1"]
```

Commit the change.

## 5. Render the real Ignition

```sh
mise ign --server-name <name>
```

This renders `bare-metal.bu` with `${DATA_DISKS}` substituted from
`server.toml`. If `data_disks` is still empty, the task errors with a
message pointing back at the discovery-boot step.

Verify:

```sh
jq '{ver: .ignition.version, users: (.passwd.users | length)}' \
  provisioning/servers/<name>/materia.ign
# must be < 32768 bytes (Ignition's inline limit for some boot paths)
stat -c %s provisioning/servers/<name>/materia.ign
```

## 6. Boot the target + install to disk

**Terminal 1 — serve the real Ignition:**

```sh
mise ipxe:serve --server-name <name>
```

**Target box — boot from USB, chain into iPXE, SSH in, install:**

```
iPXE> dhcp
iPXE> chain http://<LAN-IP>:8080/boot.ipxe
```

This boots Flatcar in RAM and runs the real Ignition (which sets up the
hostname, materia quadlet, LVM, nftables, etc. — but doesn't write to
disk yet). SSH in and install Flatcar to the boot disk:

```sh
ssh core@<box-lan-ip>
curl -s http://<LAN-IP>:8080/materia.ign -o /tmp/materia.ign
sudo flatcar-install -d <boot-disk> -i /tmp/materia.ign
sudo reboot
```

Replace `<boot-disk>` with the device you want to boot from (e.g.
`/dev/sda` or `/dev/nvme0n1` — typically *not* one of the `data_disks`,
which are for the LVM data VG).

> **Why manual `flatcar-install`?** The iPXE boot runs Flatcar in RAM. To
> persist to disk, you either SSH in and run `flatcar-install` by hand
> (this step), or use a declarative one-boot install (Ignition
> `storage.disks` + a self-installing first-boot unit). The latter is a
> known future improvement — see "Future" below.

## 7. Verification checklist (post-reboot from disk)

```sh
ssh core@<box-lan-ip>

sudo systemctl status materia-update.timer     # active, waiting
sudo systemctl status materia-update.service   # inactive (ran on boot), exit 0
sudo systemctl status lvm-data.service         # active (exited), exit 0
sudo systemctl status nftables.service          # active (exited)
sudo systemctl status enable-podman-socket.service  # active (exited)

sudo vgdisplay vg_data                          # VG present
sudo lvs vg_data                                # lv_data using 100%FREE
ls /var/lib/materia-data                        # mounted

sudo nft list ruleset                           # table inet filter, policy drop

# materia ran on boot (OnBootSec=2min) — check it converged:
sudo journalctl -u materia-update.service -n 50 --no-pager
```

## 8. Troubleshooting

| Symptom | Where to look |
|---|---|
| iPXE doesn't fetch `boot.ipxe` | USB stick not picked — check UEFI boot menu. Firewall on workstation blocks `:8080`. `curl -v http://<lan-ip>:8080/boot.ipxe` from another machine. |
| iPXE fetches but Flatcar doesn't boot | Wrong Flatcar channel/version — check `FLATCAR_CHANNEL`/`FLATCAR_VERSION` env vars. Secure Boot still on. |
| Can't SSH into RAM-booted box | `bare-metal-debug.bu` only has the `core` user + your SSH key — confirm the key matches. DHCP gave an unexpected IP — check the box's console for the assigned address. |
| `lvm-data.service` failed | `journalctl -u lvm-data.service` — usually wrong disk device names in `data_disks`. Re-run discovery boot, confirm `lsblk` output, fix `server.toml`, re-render, reboot. |
| Lost SSH after nftables applied | The closed-posture rules drop all inbound by default. Connect via physical/serial console, `sudo systemctl stop nftables` (or add a temporary input rule for SSH). If you need persistent SSH, add an nftables rule accepting your SSH port to `/etc/nftables.conf` before the final reboot — see `bare-metal.bu`. |
| `materia-update.service` failed | `journalctl -u materia-update.service` — check the repo URL, age key, and SOPS vault decryption. The dead-man's-switch ping URL (healthchecks.io) failing is harmless (leading `-` on the curl). |
| USB stick not bootable | See [USB troubleshooting](#usb-troubleshooting) below. |

### USB troubleshooting

Plug the USB stick into the workstation, then run:

```sh
# 1. Confirm which device IS the USB
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E "(usb|NAME)"
# → SanDisk 3.2Gen1 usb /dev/sda (your stick)
# → NVMes (internal SSDs) will show TRAN=nvme

# 2. See what's currently on it
sudo fdisk -l /dev/sdX

# 3. If any partition is mounted, unmount it (CRITICAL before re-dding)
mount | grep '/dev/sdX'
sudo umount /dev/sdX1 2>/dev/null
sudo umount /dev/sdX2 2>/dev/null

# 4. Verify the MBR signature is intact
sudo dd if=/dev/sdX bs=1 count=2 skip=510 2>/dev/null | xxd
# → should print "00000000: 55aa"   (valid boot signature)
# → if you see "00000000: 0000" or anything else, the MBR is broken — re-dd

# 5. Re-write cleanly
sudo dd if="$FIRMWARE_FILE" of=/dev/sdX bs=4M status=progress conv=fsync oflag=direct
sync

# 6. Verify the result
sudo fdisk -l /dev/sdX
sudo dd if=/dev/sdX bs=1 count=2 skip=510 2>/dev/null | xxd
# → should be 55aa

# 7. Eject properly before unplugging
sync
sudo eject /dev/sdX
```

If the USB still isn't bootable after re-dding:

- Try a different USB stick (some cheap sticks have flaky boot support).
- Try a USB 2.0 port instead of 3.0.
- On the target box, enter BIOS (Del / F2 / F10 at POST) and:
  1. Disable **Secure Boot**.
  2. Enable **USB boot** / **Boot from USB** / **Legacy USB support**.
  3. Set boot order so USB is first.
- Alternative write methods if `dd` isn't working:
  - **Ventoy** (https://ventoy.net) — install Ventoy on the USB once, then
    drop the ISO file on it.
  - **Popsicle** / **Fedora Media Writer** / **balenaEtcher** — GUI tools
    that handle the USB write + boot flag for you.

## 9. Next steps

After successful bring-up:

1. Assign components to the host in `MANIFEST.toml` (or via a role).
2. Add host-specific secrets to `attributes/<name>.yml` if needed:
   ```sh
   sops attributes/<name>.yml
   ```
3. Push to origin — the next `materia update` on the host (daily timer or
   external trigger) will reconcile.

## Future: declarative on-disk provisioning

The current flow requires SSHing into the RAM-booted Flatcar and manually
running `flatcar-install` (step 6). Fine for one-off bring-up, but for
**repeatable rebuilds** (wipe the box, re-run the same flow, get a fresh
server), the future goal is:

1. **One-boot path.** iPXE chain → Ignition has kernel arg
   `root=/dev/sda` + a `storage.disks` / `storage.filesystems` /
   `storage.files` block that initializes `/dev/sda` (GPT + ext4 + copies
   of `/boot`, `/usr`, OEM partition).
2. **First-boot unit** that calls `flatcar-install -d /dev/sda -i <ign>`
   from the live environment to write Flatcar + Ignition, then
   `systemctl reboot`.
3. **Reboot** lands on the installed system, which runs the same
   materia / LVM / nftables flow as today.

Outcome: `mise ipxe:serve` + USB stick + power-cycle = fresh server, no
console interaction. This is a known gap in both this repo and the source
`server-provisioning` repo — not implemented here.
