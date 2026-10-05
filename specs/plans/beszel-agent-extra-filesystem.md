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
- `sudo podman exec beszel-agent ls /extra-filesystems` shows the folder.
- The hub's Bow system shows a "Data" disk whose usage matches
  `df -h /var/lib/materia-data`.
