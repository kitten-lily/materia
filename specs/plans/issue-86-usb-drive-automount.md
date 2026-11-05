# Plan: auto-unlock and automount bow's LUKS USB drive (#86)

## Goal

When the external USB drive is connected to `bow`, either at boot or
later by hotplug, it unlocks without a password and mounts at `/mnt/usb`.
When it's removed, the mount and the dm-crypt mapping go away. Out of
scope for now: anything that consumes the drive (a future restic or
rsync job, see "Later").

## Findings (bow, 2026-11-05, read-only inspection)

- `sdb`: Seagate Desktop, 7.3T, USB (`uas`), by-id
  `usb-Seagate_Desktop_<serial>-0:0`. The whole disk is LUKS2
  (`aes-xts-plain64`), with no label. The serial and LUKS UUID are left
  out on purpose (repo-generic rule); `ls /dev/disk/by-id | grep usb-`
  on the host shows them.
- Keyslot 0 is the password (argon2id). Keyslots 1–3 are three
  `systemd-tpm2` tokens bound to PCR 7+14.
  `cryptsetup open --test-passphrase --token-only /dev/sdb` fails on
  all three with `TPM policy does not match current system state`. No
  enrollment appears in bow's or the workstation's shell history; they
  are believed to come from the drive's previous host. Decision: wipe
  them.
- Today the drive is unlocked by hand: `cryptsetup luksOpen … usb` and
  `mount /dev/mapper/usb /mnt/usb` (core's shell history). It holds
  `Backup/{@media,@opt,@docker,Downloads,…}`. The inner filesystem type
  is unknown, so the mount unit leaves `Type=` unset.
- Host support is already in place:
  - TPM 2.0 (`/sys/class/tpm/tpm0`);
  - systemd 260;
  - cryptsetup 2.8.6;
  - `/usr/lib64/cryptsetup/libcryptsetup-token-systemd-tpm2.so`;
  - `/usr/lib/systemd/systemd-cryptsetup`;
  - `/usr/bin/systemd-cryptenroll`.

  The token test reaching a *policy* error shows that the TPM stack
  works end to end. No `/etc/crypttab` exists, and `/etc/fstab` has only
  the `vg_data` entry.
- Secure Boot is disabled, and the boot chain goes through shim (PCR 14
  `shim-policy` is populated).

## Decisions

### Key binding: TPM2 token, no PCRs

`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=` (an empty PCR
list). The key is sealed to bow's TPM storage root key only.

- **What this protects:** a drive that is lost, stolen or unplugged is
  useless without bow's TPM. That is the realistic threat for an
  external disk.
- **What it doesn't protect:** someone who takes all of bow can unseal
  the key. That matches the host's existing posture: the root disk is
  unencrypted and `/etc/materia/key.txt` (the age key for every vault
  secret) is in plaintext on it.
- **Why not PCR 7 / 7+14:** with Secure Boot off, PCR 7 adds almost no
  protection. It still changes when shim bumps its SBAT level or the
  firmware's dbx is updated, so a routine Flatcar or BIOS update would
  silently stop auto-unlock. The old tokens were in the same state:
  enrolled, but they don't unlock on this host.
- **Recovery:** the keyslot 0 password stays. After a TPM clear or a
  board swap, unlock by hand and re-run the enroll task.
- **Rejected: a keyfile from the SOPS vault.** materia forces data files
  to 0644 in 0755 dirs, so the key would be world-readable on the host.
  It would also put key material in git for no gain over the TPM.

### Mechanism: hotplug-triggered units, not crypttab

- crypttab only unlocks devices present at boot: its generated units
  hang off `cryptsetup.target`. It also lives in `/etc/crypttab`, which
  materia can't write (resources only go to the data, quadlet, systemd
  or scripts dirs).
- Butane changes don't reach a running host.
- So: a materia component installs one service that starts from the
  drive's device unit through `[Install] WantedBy=`, plus a mount unit
  pulled in by that service.

### Device identity: a LUKS label

- materia templates have no string-replace function (`FuncMap` in
  `pkg/materia/snippet.go`, no sprig). A UUID therefore can't be
  converted into the escaped unit name `dev-disk-by\x2duuid-…\x2d….device`.
- Instead, the enroll task sets the LUKS2 header label to `usbbackup`
  (dash-free) with `cryptsetup config --label`. That changes the label
  field only and can be undone.
- udev links crypto devices by label
  (`60-persistent-storage.rules`:
  `ID_FS_USAGE=="filesystem|other|crypto"` → `disk/by-label/…`), so the
  device unit becomes `dev-disk-by\x2dlabel-usbbackup.device`. The only
  escaping is the constant `by\x2dlabel`.
- With this, the units are static files, with no `.gotmpl` and no
  attributes.

### materia semantics (verified in source; revised after the first deploy)

The first design listed the unlock service in `[[Services]]` with
`Static` + `Stopped` + `Oneshot`, checked against v0.8.0 / master
source. **bow runs materia v0.7.0**: its live quadlet still uses
`:stable`, pulled 2026-06-16, even though the `.bu` templates now pin
v0.8.0. In v0.7.0, `coalesceServices` (`pkg/plan/plan.go`) adds a
zero-valued action whenever a service's only planned step is Enable.
The first deploy (`bea0e45`) therefore aborted bow's whole run with
`FATA unsupported resource type: Unknown` (0/7 steps, nothing applied).
Upstream fixed it in v0.7.1 (`f1e7425`). The component was unassigned
in `36992ea` and bow went green again.

Revised approach, safe on v0.7.0 and v0.8.0:

- `.service` and `.mount` resources are `ResourceTypeService`. They are
  installed to `/etc/systemd/system`, and a daemon-reload follows.
- Units *not* listed in `[[Services]]` get no service actions at all: no
  enable, start, stop, disable or health check. That holds in both
  versions: v0.7.0 `GenerateServiceActions` only walks `ServiceConfigs`,
  and in the failed v0.7.0 plan `mnt-usb.mount` got `Install` only. A
  missing drive or a failed unlock therefore can't fail a
  `materia-update` run (that would be the all-host blast radius of
  BUG-010).
- The one-time `systemctl enable usb-drive-unlock.service` moves into the
  enroll task. `systemctl enable` reloads systemd itself, so the
  enable-after-reload gap of the `Static` approach goes away too.
- Trade-off: enablement isn't declared in git. If someone disables the
  unit by hand, materia won't re-enable it; re-running the enroll task
  does.

## Changes

### `components/usb-drive/` (new; assigned in `MANIFEST.toml` `Hosts.bow.Components`)

`MANIFEST.toml`: comments only, deliberately no `[[Services]]` (see
above).

`usb-drive-unlock.service`:

```ini
[Unit]
Description=Unlock USB backup drive (LUKS2, TPM2 token)
BindsTo=dev-disk-by\x2dlabel-usbbackup.device
After=dev-disk-by\x2dlabel-usbbackup.device
Wants=mnt-usb.mount

[Service]
Type=oneshot
RemainAfterExit=yes
# headless: fail instead of waiting on a password prompt nobody can answer.
ExecStart=/usr/lib/systemd/systemd-cryptsetup attach usb /dev/disk/by-label/usbbackup - tpm2-device=auto,headless=true
ExecStop=/usr/lib/systemd/systemd-cryptsetup detach usb

[Install]
WantedBy=dev-disk-by\x2dlabel-usbbackup.device
```

`mnt-usb.mount` (the file name must match `Where=`):

```ini
[Unit]
Description=USB backup drive
BindsTo=usb-drive-unlock.service
After=usb-drive-unlock.service

[Mount]
What=/dev/mapper/usb
Where=/mnt/usb
# Drops the implicit Before=local-fs.target. Without it, a drive attached
# at boot creates an ordering cycle with the unlock service's default
# After=sysinit.target (found by systemd-analyze verify during implementation).
Options=nofail
```

How the units behave:

- **Unplug:** the device unit goes away, so `BindsTo` stops the
  service. The mount is ordered after it, so it unmounts first, then the
  service detaches the mapping.
- `What=/dev/mapper/usb` also gives the mount an implicit binding to the
  mapper device.
- The mapper name `usb` and the mount point `/mnt/usb` match the manual
  procedure used today.

### `.mise/tasks/usb-drive/enroll` (new; the required host-side step, made executable per BUG-010's rule)

`mise usb-drive:enroll --target core@<host> --device <path>`, run over
`ssh -t` because cryptenroll prompts for the existing password. The label
is not a flag: it has to match the units, so it is a constant in the
task. Nothing bow-specific is committed; the device path is a flag.
Re-running is safe: an enrollment that already works (one TPM2 token,
no PCRs, `--token-only` unlocks) is skipped.

1. Refuse unless `usb-drive-unlock.service` is installed (the component
   lands first) and `cryptsetup isLuks <device>` succeeds.
2. `systemctl enable usb-drive-unlock.service`, which also reloads systemd.
3. `systemd-cryptenroll <device> --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=`.
   Enrollment completes first and the new slot is excluded from the wipe
   (`systemd-cryptenroll(1)`), so the three stale tokens go and the
   password slot is untouched.
4. `cryptsetup config --label <label> <device>`, then `udevadm settle`.
   The new by-label alias is a new device unit, which pulls in the unlock
   service. If `/mnt/usb` still isn't mounted (for example on a re-run
   where the label already existed), `systemctl start
   usb-drive-unlock.service`.
5. Verify, and fail loudly on any miss:
   - `cryptsetup open --test-passphrase --token-only <device>` succeeds;
   - `luksDump` shows slot 0 plus exactly one `systemd-tpm2` token with
     empty `tpm2-hash-pcrs`;
   - `systemctl show -p WantedBy usb-drive-unlock.service` includes the
     device unit;
   - `findmnt /mnt/usb` shows `/dev/mapper/usb`.

### Docs

- `AGENTS.md`: repo-layout entry for `usb-drive/` and the `usb-drive/enroll` task.
- `AGENTS.md` gotchas:
  - check the materia version a host actually runs (bow: v0.7.0), and
    the v0.7.0 Enable-only phantom action;
  - hotplug units: install with materia, unlisted; enable from the task;
  - no replace function in templates, so use a dash-free label for
    device units;
  - never bind-mount `/mnt/usb` into a materia container (see Risks).

## Sequencing

1. Land `components/usb-drive/` and the `Hosts.bow` assignment, run
   bow's `materia-update`, and confirm it was green: no `FATA` in
   `journalctl -u materia-update.service`, and both units exist under
   `/etc/systemd/system`. The units are inert before step 2: nothing
   enables them, and no device carries the label yet.
2. Run `mise usb-drive:enroll --target core@bow --device /dev/disk/by-id/usb-Seagate_Desktop_<serial>-0:0`.

## Acceptance

- The `materia-update` run that installs the component is green, both
  with the drive attached and without it.
- After enroll, the drive is mounted at `/mnt/usb` with no password
  prompt.
- Physical unplug: `usb-drive-unlock.service` becomes inactive,
  `/dev/mapper/usb` is gone, and `/mnt/usb` is not a mount point.
  Replug: it is mounted again within seconds.
- After a reboot with the drive attached, it is mounted once the boot
  completes.
- A failed unlock shows up as a failed `usb-drive-unlock.service` in
  `systemctl --failed`, and beszel's systemd failed count picks it up.
  It never shows up as a `materia-update` failure.

**Verified on bow, 2026-11-05:**
- materia-update green with the component (drive attached).
- `mise usb-drive:enroll`:
  - TPM2 token as keyslot 4, no PCRs; stale slots 1–3 wiped; password
    slot 0 kept;
  - unlocked and mounted (XFS) with no password;
  - all checks pass after `f60005a` fixed two broken checks in the task.
- Hotplug:
  - `systemctl stop usb-drive-unlock.service` closed the mapping and
    unmounted;
  - after a physical replug, both units came back `active` and
    `/dev/mapper/usb` was mounted at `/mnt/usb` within 10 s, with no
    password.

Not yet checked: pulling the drive while it is mounted (the clean stop
was used instead), and a reboot with the drive attached. Check the
reboot after bow's next Flatcar update.

## Risks / limits

- **Containers:** a container bind-mounting `/mnt/usb` hard-fails when
  the drive is absent (`statfs` exit 125, the BUG-005 class), and that
  aborts `materia-update` for every component on bow. Any future
  consumer must be a unit triggered by `mnt-usb.mount` (see Later), not
  a long-running container with a static `Volume=`.
- **Busy filesystem on unplug:** if `/mnt/usb` is busy when the drive is
  pulled, the umount fails and the mapping lingers on a dead device.
  Recovery: `umount -l /mnt/usb && systemd-cryptsetup detach usb`.
  Yanking a mounted read-write drive can always lose in-flight writes;
  no unit design avoids that.
- **TPM clear / board swap:** auto-unlock stops (failed unit, data
  intact). Recover with the password and re-run the enroll task.
- **Reprovisioning:** a reprovisioned bow gets the units from materia.
  The label and token live in the drive's LUKS header. The seal depends
  only on the TPM's storage root key, which an OS reinstall doesn't
  touch, so auto-unlock keeps working unless the TPM itself is cleared
  [INFERENCE: not tested].
- **SSH to bow uses a FIDO2 resident key (`ssh:Bow`).** During
  exploration several connections stalled at publickey auth until they
  timed out, which is what a key waiting for a touch looks like
  [INFERENCE]. The enroll task is interactive anyway (`ssh -t` +
  password prompt), so it needs no extra handling.

## Later (not #86)

- A restic or rsync job to the drive: a `.service` with
  `BindsTo=mnt-usb.mount`, `After=mnt-usb.mount`,
  `WantedBy=mnt-usb.mount` (runs on every plug), and/or a timer whose
  service has `ConditionPathIsMountPoint=/mnt/usb`. Same treatment as the
  unlock unit: unlisted in `[[Services]]` (or `Static`+`Stopped`+`Oneshot`
  once the host runs materia ≥ v0.7.1), for the same never-health-checked
  reason.
