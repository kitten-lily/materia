# BUG-006 — bow rejects push of krytis's final assembled OCI image: gRPC `INVALID_ARGUMENT` on UploadBlob

**status:** implemented-pending-verification
**found:** 2026-07-23, during krytis's `cache-warm.yml` workflow run
(https://github.com/starlit-os/krytis/actions/runs/30033645226/job/89319996724),
verifying the bow artifact-cache wiring merged in krytis#343
**severity:** P2 (non-blocking today — krytis's `cache-warm.yml` wraps the
build in `set +e`/`exit 0` so the job still shows green — but it means bow
never actually caches the single most expensive artifact in the build,
undermining a chunk of the point of the cache)
**epic:** issue-28-bst-cache-krytis

## Symptom

Every element in krytis's `oci/krytis/image.bst` build pushed to bow
successfully (24 built, 31 pushed this run) except the final top-level
element itself — `oci/krytis/image.bst`, the `kind: script` element that
assembles the complete OCI image (by far the largest single artifact in
the build; the session's local BuildStream CAS was 53G total). Its push
failed:

```
[push:oci/krytis/image.bst] FAILURE Try #1 failed, retrying
[push:oci/krytis/image.bst] FAILURE Try #2 failed, retrying
[push:oci/krytis/image.bst] FAILURE Try #3 failed, retrying
[push:oci/krytis/image.bst] FAILURE Failed to upload blob 45589bfb88a5e5d72aba50adb16bb0db4ef9ccdcd7fb994aa269734f6a54057f: 3
```

gRPC status `3` = `INVALID_ARGUMENT`.

## Root cause, attempt 1 (necessary but not sufficient)

`components/buildbarn/config/common.libsonnet` sets:

```jsonnet
maximumMessageSizeBytes: 2 * 1024 * 1024 * 1024,  // 2 GiB
```

applied to both `storage.jsonnet`'s and `asset.jsonnet`'s `grpcServers`.
Buildbarn's gRPC message-size interceptor returns `INVALID_ARGUMENT` for
any single message exceeding this limit, and this was raised to 8 GiB
(commit `1d786a6`) as a reasonable general-purpose bump. **This did not
fix the bug** — retried after bb-storage/bb-asset restarted onto the new
config, identical `INVALID_ARGUMENT` on the same blob. The 8 GiB raise is
harmless and worth keeping (gRPC transport-level ceiling is a real,
separate limit from the one below), but it was the wrong hypothesis for
*this* failure.

## Root cause, attempt 2 (confirmed)

Buildbarn's local storage backend (`contentAddressableStorage.backend.local`
in `storage.jsonnet`) divides `blocksOnBlockDevice.source.file.sizeBytes`
into `oldBlocks + currentBlocks + newBlocks + spareBlocks` fixed-size
blocks, and **every blob must fit inside a single block** — a limit
completely independent of `maximumMessageSizeBytes`. Confirmed against
[Buildbarn's own block-sizing writeup](https://meroton.github.io/blog/buildbarn-block-sizes/):
the max storable blob is `blocksOnBlockDevice.sizeBytes / totalBlocks`.

The original layout — `oldBlocks: 8, currentBlocks: 24, newBlocks: 3,
spareBlocks: 3` (38 blocks) over 100G — gives a per-blob ceiling of
`100 * 1024^3 / 38` ≈ **2.63 GiB**. The actual failing blob
(`oci/krytis/image.bst`, hash
`45589bfb88a5e5d72aba50adb16bb0db4ef9ccdcd7fb994aa269734f6a54057f`) was
confirmed at **6,321,065,984 bytes (5.89 GiB)** — more than double the
ceiling. This, not message size, is why the push failed both before and
after the 8 GiB `maximumMessageSizeBytes` bump.

The original 100G/38-block sizing in
`specs/plans/issue-28-bst-cache-krytis.md` (open question #6) reasoned
about total CAS *capacity* only — it never computed the per-block max
blob size implied by the block count. That's the gap this bug exposes.

## Fix

Two changes, both in `components/buildbarn/config/`:

1. `common.libsonnet`: `maximumMessageSizeBytes` 2 GiB → 8 GiB (kept from
   attempt 1, harmless general-purpose headroom for the gRPC transport
   limit).
2. `storage.jsonnet`'s CAS `local` backend: block layout changed from
   `oldBlocks: 8, currentBlocks: 24, newBlocks: 3, spareBlocks: 3` (100G,
   38 blocks, 2.63 GiB/block) to `oldBlocks: 1, currentBlocks: 4,
   newBlocks: 2, spareBlocks: 1` (**130G**, 8 blocks, **16.25 GiB/block**
   — 2.8x margin over the confirmed 5.89 GiB blob).

**Sizing decision:** bow's `/var/lib/materia-data` was at **94% disk
utilization (357G free of 5.5T)** when this was fixed — down from the
401G free the original 100G CAS quota was sized against
(`specs/plans/issue-28-bst-cache-krytis.md`), consumed by the media
libraries (jellyfin/grimmory/audiobookshelf/music) sharing that disk.
Given that pressure, a same-size (100G), block-count-only reduction
(e.g. 6 blocks → 16.67 GiB/block, zero extra disk) was considered and
rejected by the user in favor of a modest +30G growth to 130G — judged
worth trading a sliver of the shared disk's remaining headroom for
keeping *some* extra block-count/granularity (8 blocks vs. 6) over the
zero-cost alternative. `actionCache` and `fileSystemAccessCache` local
backends were left unchanged (2G/100M, small metadata records, not
raw blob content — not implicated in this failure).

This moved past `quick-fix` scope once the message-size fix failed —
root cause required actual investigation (a second, independent limit
buried in Buildbarn's local-storage block math) and a capacity trade-off
decision affecting a disk shared with unrelated components. No separate
`specs/plans/` doc was written; this BUG-006 file serves as the record
per AGENTS.md § Discovered Defects (`fix-bug`).

## Verification

**Repo-side (done):** `mise clean && mise ign --server-name bow` —
Preflight rendered clean, confirming the jsonnet template still
parses/transpiles with no butane errors. (No local jsonnet evaluator
exists in this repo's toolchain — the only real syntax/semantic
verification path is a live container start.)

**Not yet done — requires live host actions, tracked here so this
doesn't get marked `fixed` prematurely:**

1. Redeploy: next `materia-update` run on bow that picks up this commit,
   or a manual `systemctl restart bb-storage.service bb-asset.service`.
   Buildbarn reads both `maximumMessageSizeBytes` and the CAS block
   layout at process start only.
2. **Changing `oldBlocks`/`currentBlocks`/`newBlocks`/`spareBlocks`
   reshapes the local storage ring buffer.** Existing on-disk state
   (`/data/storage-cas/{blocks,key_location_map,persistent_state}`) was
   written under the old 38-block geometry; if bb-storage errors on
   startup about a block-count/geometry mismatch, this is a pure cache
   (losing it just forces re-population, not data loss) — safe to
   `rm -rf` those three paths under `/data/storage-cas/` on bow and
   restart. Confirm whether this was actually necessary once verified
   live.
3. Re-run krytis's `cache-warm.yml` (or a local `bst artifact push` of
   `oci/krytis/image.bst`) and confirm blob
   `45589bfb88a5e5d72aba50adb16bb0db4ef9ccdcd7fb994aa269734f6a54057f`
   (or its current equivalent) pushes without `INVALID_ARGUMENT` before
   closing this out as `fixed`.
4. Re-check `df -h /var/lib/materia-data` after the resize lands to
   confirm the +30G was actually consumed as expected (sparse file
   growth, not a surprise full allocation).

## Cross-repo note

Surfaced from krytis while testing krytis#343 (artifact-cache wiring) and
krytis#350 (unrelated checksum-drift fix, same testing session) — see
krytis's `docs/skills/ci-runner.md` for the client-side context
(push/pull JWT wiring, why krytis's own `quadlet/buildbarn/` copy is
stale/local-dev-test-only and not authoritative for bow's real limits).
