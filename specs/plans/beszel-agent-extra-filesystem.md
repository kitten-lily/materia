# Plan: beszel-agent reports bow's data-disk usage

## Problem

`beszel-agent` only reports the root filesystem. On `bow` the bulk of the
storage — media libraries, buildbarn CAS — lives on the LVM data volume
(`vg_data/lv_data`, mounted at `/var/lib/materia-data`), which is the disk
that is actually filling up (~94% used at BUG-006 time). It is invisible in
the hub.

## Mechanism (beszel v0.21.0, `agent/disk.go`)

A containerized agent reports any directory bind-mounted at
`/extra-filesystems/<name>`:

- Usage comes from `statfs` on that mountpoint — any path on the
  filesystem gives the whole-filesystem numbers.
- I/O stats use the partition device from the container's mountinfo
  (`/dev/mapper/vg_data-lv_data`), resolved through its symlink to `dm-N`
  (v0.21.0 handles device-mapper explicitly). The folder name is only an
  I/O fallback.
- `<device>__<Name>` sets the display name in the hub.

## Scoping to bow

`beszel-agent` is assigned to every host via `[Roles.base]`. Making the mount
optional per host:

- The template emits the `Volume=` line only inside
  `{{ if exists "beszelExtraFilesystem" }}`. `exists` checks the merged vars
  map, so a host without the attribute renders nothing. It never hits the
  fatal `map has no entry for key` error.
- bow sets the value through `[Hosts.bow.Extensions.beszel-agent.Defaults]`
  in `MANIFEST.toml`. Extensions *merge* into the component's `Defaults`
  (`manifests.ExtendComponentManifests`). `Overrides` would *replace* them.
  This needs no vault edit, and the path is not sensitive (it already
  appears in several tracked components). Verified against materia v0.7.2,
  the pinned version: `ExtendComponentManifests`, the `exists` macro, and
  `MergeAttributes(attrs, comp.Defaults)` in the template stage.

## Mount details

- `Volume=/var/lib/materia-data:/extra-filesystems/data__Data:ro`
- **No `:z`/`:Z`.** Relabelling would recursively relabel the entire
  multi-TB data disk, overriding the labels every other component's mounts
  rely on. `statfs` needs no file-level read access.
- The mountpoint always exists on bow (created by the `.bu` LVM script), so
  the missing-bind-source failure class (BUG-005) doesn't apply.

## Verify (on bow, after the next materia-update)

- `journalctl -u materia-update.service | grep FATA` — empty.
- `sudo podman inspect beszel-agent --format '{{range .Mounts}}{{.Destination}} {{end}}'`
  lists `/extra-filesystems/data__Data`. (Not `podman exec … ls`: the
  agent image is scratch, with no `ls` or shell.)
- `journalctl -u beszel-agent.service -b | grep 'Detected disk'` shows
  `name=Data mount=/extra-filesystems/data__Data io=dm-N` (logged at
  Info level on startup, `agent/disk.go`).
- The hub's Bow system shows a "Data" disk whose usage matches
  `df -h /var/lib/materia-data`.

## Follow-up: root fallback swallowed the Data disk

First deploy: mount present, agent logged `Detected disk name=Data`, but the
hub showed nothing. Cause (`agent/disk.go`, v0.21.0): rootful podman serves
`/etc/hosts` from `/run` (tmpfs), so `isRootFallbackPartition` never sees a
`/dev` device and the agent falls back to `addLastResortRootFs`. That picks
the most active I/O device, which on bow is the data LV (`dm-N`), and writes
the root entry under that same key. The Data entry is overwritten with
`Root: true`, and root entries are never sent as extra disks. Confirmed on
bow by the `Using most active device for root I/O` warning.

Fix: optional `beszelRootFilesystem` attribute → `Environment=FILESYSTEM=`,
set to `sda` for bow (the device the fallback chose before the Data mount
existed, so root I/O is unchanged). With `FILESYSTEM` set, root resolves via
`addConfiguredRootFs` → `findIoDevice` on host diskstats, and the fallback
never runs.

Verify: no `most active` warning in `journalctl -u beszel-agent.service -b`,
and the Data disk appears on the Bow system page.

## Follow-up: hide Flatcar's btrfs storage pools

bow and flutterina each showed two ~1 GB btrfs "storage pools" with KB used
(Flatcar's OEM partition plus an unlabeled one, shown by UUID). The agent's
btrfs backend (`agent/btrfs/btrfs_linux.go`) reads every filesystem under
`/sys/fs/btrfs` and has no env var to filter them. Neither host has real
btrfs data (root and bow's data LV are ext4).

Fix: opt-in `beszelHideBtrfsPools` flag → quadlet `Mask=/sys/fs/btrfs`
(podman ≥4.6). The masked dir is empty in the container, so `Filesystems()`
returns none and no pools are sent. Set for bow and flutterina only;
krytis-build isn't Flatcar and might have real btrfs.

Verify: `sudo podman inspect beszel-agent --format '{{.HostConfig.MaskedPaths}}'`
includes `/sys/fs/btrfs`, and the pools are gone from both system pages.
