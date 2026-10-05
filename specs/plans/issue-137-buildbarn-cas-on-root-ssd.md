# Implementation Plan — Issue #137: grow Buildbarn's CAS onto bow's root SSD

**issue:** https://github.com/kitten-lily/materia/issues/137
**cross-repo:** starlit-os/krytis#1094 (evidence, krytis-side gate fix)
**risk:** P2 (one component on one host; the CAS is a pure cache, and losing it
forces re-population rather than losing data)
**epic:** standalone

## Summary

bow's CAS (150 GiB, `/var/lib/materia-data`, NVMe `vg_data`) evicts krytis's
toolchain artifacts while bb-asset's index still lists them. On 2026-10-03,
krytis's cache-warm found index entries for llvm `ba3c0fc3` and rust
`55eef370`, but storage answered `does not have artifact` for both. They were
rebuilt for 4h12m and 1h04m. krytis's full build closure (917 elements) filled
78G of the runner's local cache.

Owner decision (2026-10-05):

- Move the CAS **blocks file** onto bow's root SATA SSD (Flatcar `/var`, about
  800G free) and grow it to **600 GiB**.
- Keep the key-location map, persistent state, AC, FSAC and the bb-asset index
  on the NVMe data volume.
- Accepted: the cache restarts empty, there is downtime, the disk is shared with
  root, and a bigger cache only delays eviction.

## Design

### Only the blocks file moves

`bb-storage.container.gotmpl` gains one bind mount,
`/var/lib/buildbarn/storage-cas-blocks:/data/storage-cas-blocks:Z`.
`storage.jsonnet` points `blocksOnBlockDevice` there. The existing
`/data/storage-cas` mount (NVMe) keeps `key_location_map` and
`persistent_state`: the hot random-access lookups stay on the fast disk, and the
bulk sequential block writes go to the large one.

The host path is outside `/var/lib/materia/components/` on purpose. Materia
treats everything under its data dir as managed and plans unmanaged files for
removal (AGENTS.md gotcha "The data dir is fully managed").

### Block geometry back to Buildbarn's recommendation: 8/24/3/3

This deviates from the issue's "keep 10 blocks". BUG-006 cut the layout to
2/5/2/1 to raise the per-blob ceiling at 150 GiB. Buildbarn's own docs
(`pkg/proto/configuration/blobstore/blobstore.proto`, local backend) say:

- old blocks: "Recommended value: 8"; current: "Recommended value: 24";
- "The number of blocks in the 'old' group should not be too low, as this
  would cause this storage backend to become a FIFO instead of being LRU-like";
- "having more than three or four 'new' blocks would be wasteful".

[INFERENCE] With only 2 old blocks, data that krytis never reads back (the
toolchain sits in cache-warm's own local cache) gets almost no refresh window
before it is evicted, which fits what krytis saw.

At 600 GiB, 8/24/3 plus 3 spare gives 38 blocks of 600/38 ≈ **15.8 GiB**. The
per-blob ceiling (`sizeBytes / total blocks`, BUG-006) is therefore slightly
*above* today's 15 GiB, so BUG-006's 5.89 GiB OCI blob still has a 2.7× margin.

### Key-location map: 400 MiB → 1600 MiB

It scales with the blocks file (×4). [INFERENCE] There is no published
bytes-per-entry figure to size it from. Buildbarn's docs give the check
instead: after deploy and a full cache-warm,
`buildbarn_lossymap_hash_map_put_too_many_iterations_total` and
`buildbarn_lossymap_hash_map_put_iterations_count{outcome="TooManyAttempts"}`
on `:9981` must be 0. If they are not, the map is too small and evicts entries
early. The map stays on NVMe.

### Preallocate, because the root disk is shared

Buildbarn's blocks file is sparse: BUG-006's step 4 watched `df` for growth
rather than a full allocation. On a root disk shared with the OS and podman
storage, a sparse 600G file would take free space gradually and could hit
ENOSPC mid-write months later. The deploy step therefore runs `fallocate -l 600G`
on the file before the first start, so the full reservation is taken up front.

### Wipe CAS and index together

The geometry and size changes invalidate the existing on-disk state. The
BUG-006 resize wiped only `/data/storage-cas/*`, which can leave bb-asset's
index pointing at blobs that no longer exist: exactly the inconsistency in the
Summary. This time the CAS state, the AC, the FSAC and the bb-asset cache are
cleared together, so the index and storage start empty and in agreement.

## Files

1. `components/buildbarn/bb-storage.container.gotmpl`: the new bind mount, with
   a comment explaining why.
2. `components/buildbarn/config/storage.jsonnet` (CAS only):
   - `blocksOnBlockDevice.source.file.path` → `/data/storage-cas-blocks/blocks`;
   - `sizeBytes` 150 GiB → 600 GiB;
   - old/current/new/spare 2/5/2/1 → 8/24/3/3;
   - `keyLocationMapOnBlockDevice` `sizeBytes` 400 MiB → 1600 MiB.

   The comment block is rewritten in place, not appended to. Field names stay as
   they are: the pinned `bb-storage@sha256:155fa806…` accepts them. Upstream
   `main` has since moved them under `key_location_map`, which matters only on a
   future image bump.
3. `AGENTS.md`/`CLAUDE.md`: one gotcha, "Buildbarn CAS geometry: keep ≥8 old
   blocks; resize by wiping CAS **and** index together".

## Deploy (bow, outside krytis's weekday schedule: cache-warm 01:41 UTC, publish 03:30)

1. `sudo systemctl stop bb-asset.service bb-storage.service`
2. `sudo mkdir -p /var/lib/buildbarn/storage-cas-blocks`, then
   `sudo fallocate -l 600G /var/lib/buildbarn/storage-cas-blocks/blocks`, then
   `df -h /var` to confirm the space is taken.
3. Wipe the old state together, then re-create each `persistent_state/`
   (neither bb-storage nor bb-asset creates it; see the container comments):

   ```shell
   cd /var/lib/materia-data/buildbarn
   sudo rm -rf storage-cas/{blocks,key_location_map,persistent_state} \
               storage-ac/{blocks,key_location_map,persistent_state} \
               storage-fsac/{blocks,key_location_map,persistent_state} \
               asset-cache/{blocks,key_location_map,persistent_state}
   sudo mkdir -p {storage-cas,storage-ac,storage-fsac,asset-cache}/persistent_state
   ```
4. `materia update` (or merge and wait for `materia-update`). Confirm both
   services are active and that `journalctl -u bb-storage -u bb-asset` shows no
   geometry or config errors. No CI evaluates this jsonnet; a container start
   is the only check (AGENTS.md).
5. In krytis, dispatch `cache-warm.yml`. Pass when its job summary reads
   `917 of 917` and the `:9981` lossymap counters above are 0.

## Preflight

`mise clean && mise ign --server-name bow`. The `.container.gotmpl` must still
render; the jsonnet itself has no local evaluator.

## Out of scope

- krytis's storage-aware toolchain gate (krytis#1094).
- Renaming the key-location-map fields for a future bb-storage image bump.
- The root SSD's own monitoring. beszel-agent already reports disk usage (#136).
