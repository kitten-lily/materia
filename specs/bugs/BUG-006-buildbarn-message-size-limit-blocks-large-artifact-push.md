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

## Root cause (probable, not yet confirmed against an exact blob size)

`components/buildbarn/config/common.libsonnet` sets:

```jsonnet
maximumMessageSizeBytes: 2 * 1024 * 1024 * 1024,  // 2 GiB
```

applied to both `storage.jsonnet`'s and `asset.jsonnet`'s `grpcServers`.
Buildbarn's gRPC message-size interceptor returns `INVALID_ARGUMENT` for
any single message exceeding this limit. `oci/krytis/image.bst`'s blob is
the full assembled desktop OCI image (freedesktop-sdk + niri + desktop
apps) — plausibly multi-GB uncompressed, and if BuildStream's CAS client
sends it via a single-message RPC (e.g. `BatchUpdateBlobs`, intended for
bundling many *small* blobs, not streaming one huge one) rather than a
chunked `ByteStream.Write`, the whole blob has to fit under
`maximumMessageSizeBytes` in one message. Every other element in the
build is small enough to clear this bar; the final assembled image likely
isn't.

**Not yet confirmed:** the exact byte size of blob
`45589bfb88a5e5d72aba50adb16bb0db4ef9ccdcd7fb994aa269734f6a54057f`. The
krytis CI run that hit this had already cached the element from an
earlier build, so no fresh size was logged; would need either a local
`bst artifact log`/CAS inspection on the krytis side, or bow-side
Prometheus metrics (`enablePrometheus: true` is already set — check
`buildbarn_blobstore_*_size_bytes` or similar) to pin down the actual
number before picking a specific new limit.

## Fix

Raised `maximumMessageSizeBytes` in `common.libsonnet` from 2 GiB to
8 GiB — CAS storage is already provisioned generously (100G,
`blocksOnBlockDevice.source.file.sizeBytes` in `storage.jsonnet`), so
the message-size ceiling costs nothing to raise generously rather than
tuning precisely to the current image size, since the image will only
grow as more desktop components are added. The constant is shared via
`common.libsonnet`, so both `storage.jsonnet` (CAS blob upload, where
this failure occurred) and `asset.jsonnet` pick it up automatically.

This was a `quick-fix`-shaped change (single jsonnet constant, no logic
risk) per AGENTS.md § Discovered Defects — no separate `specs/plans/`
doc, this BUG-006 file serves as the plan record.

## Verification

**Repo-side (done):** `mise clean && mise ign --server-name bow` —
Preflight rendered clean, confirming the jsonnet still parses/transpiles
with no template errors.

**Not yet done — requires a live host action, tracked here so this
doesn't get marked `fixed` prematurely:** Buildbarn reads
`grpcServers.maximumMessageSizeBytes` at process start, not
hot-reloaded, so the repo constant alone does nothing until bow's
`bb-storage`/`bb-asset` containers actually restart on the new config
(next `materia-update` run that picks up this commit, or a manual
`systemctl restart bb-storage.service bb-asset.service` on bow). Then
re-run krytis's `cache-warm.yml` (or a local `bst artifact push` of
`oci/krytis/image.bst`) and confirm blob
`45589bfb88a5e5d72aba50adb16bb0db4ef9ccdcd7fb994aa269734f6a54057f` (or
its current equivalent) pushes without `INVALID_ARGUMENT` before closing
this out as `fixed`.

## Cross-repo note

Surfaced from krytis while testing krytis#343 (artifact-cache wiring) and
krytis#350 (unrelated checksum-drift fix, same testing session) — see
krytis's `docs/skills/ci-runner.md` for the client-side context
(push/pull JWT wiring, why krytis's own `quadlet/buildbarn/` copy is
stale/local-dev-test-only and not authoritative for bow's real limits).
