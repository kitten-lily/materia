# Story e01s11 — Local verification: pull image + local-repo podman run

**type:** feat
**risk:** P1
**context:** infra
**epic:** e01-restic-backup
**source:** https://github.com/kitten-lily/materia/issues/2
**blocks_on:** e01s09 (needs secrets, manifest wiring, and known_hosts in
place, not just the image)

## Context

Pulled the digest pinned in `restic-backup.container.gotmpl` and ran the
wrapper against a local filesystem restic repo (not the real Storage Box —
avoids touching production secrets/infra from this environment; sftp
connectivity is a separate, real-deploy concern). Found and fixed two real
defects — exactly what this story exists to catch.

## Discovered Defect 1: pinned digest was a stale, pre-wrapper-logic build

Pulling `ghcr.io/kitten-lily/materia/restic-backup@sha256:dd42ac9516ee...`
(the digest e01s05 pinned) and running it against a local repo produced
**zero output and exit 0** — no init, no backup, nothing. `strings` on the
extracted `/usr/local/bin/wrapper` binary confirmed why: none of the
current `main.go`'s string literals (`RESTIC_REPOSITORY`, `ensureRepo`,
`is required`, etc.) exist in the binary. The image was built from an
earlier, incomplete state of `images/restic-backup/wrapper/main.go`.

Root cause: `gh run list --workflow=restic-backup-image.yml` showed **two**
successful runs on 2026-07-11 — `29161722813` (17:30 UTC, triggered by
"chore(renovate): track restic and openssh source version pins", predates
the wrapper's final logic) and `29163241617` (18:19 UTC, triggered by
"docs(specs): close out e01s04 wrapper binary", built *after* all wrapper
commits including `17bc374` "wire backup job and verify end-to-end"). e01s05
recorded the digest from the **earlier** run — a bookkeeping error, not a CI
failure. The later run's actual pushed digest (confirmed via `gh run view
29163241617 --log`, tag `sha-4ef48a3`):
`sha256:9bb02cef9f5c97f84294ca77f59b1feef642dda9ddf7b2653f34386f6c5479ee`

**Fix:** re-pinned `Image=` in `restic-backup.container.gotmpl` to the
correct digest.

## Discovered Defect 2: scratch has no writable /tmp — backup fails

With the correct digest, `restic init` succeeded, but `restic backup` failed:
`unable to save snapshot: failed to save blob from file ...: open
/tmp/restic-temp-pack-...: no such file or directory`. The scratch base
image has no `/tmp` directory at all (nothing creates one), and restic
stages pack files there during backup (`os.TempDir()`/`TMPDIR`, default
`/tmp`). Confirmed the fix with `podman run --tmpfs /tmp`: full backup +
forget + retention policy succeeded end-to-end.

**Fix:** added `Tmpfs=/tmp` to `restic-backup.container.gotmpl`'s
`[Container]` section (quadlet's tmpfs-mount directive) — ephemeral,
in-memory staging space, not part of any materia-managed path (avoids the
"data dir is fully managed" pitfall entirely since it's not a bind mount).

## Verification performed (local repo, not production Storage Box)

1. `podman pull` the (corrected) digest — succeeds, amd64/linux, no
   `Config.User` (runs as root — expected/fine for scratch), entrypoint
   `/usr/local/bin/wrapper`.
2. Fresh local repo: `restic init` runs automatically (`ensureRepo`), backup
   succeeds (2 test files, ~58B), forget/retention policy applies
   correctly (`keep 7 daily, 4 weekly, 6 monthly`).
3. Second run against the same repo: `ensureRepo` correctly skips
   re-init (finds existing `config`), incremental backup uses the parent
   snapshot, both snapshots retained (not yet past retention thresholds).
4. Guard clause: omitting `RESTIC_REPOSITORY` → `RESTIC_REPOSITORY is
   required` logged, exit 1 (matches source).
5. **Not verified here (needs real infra, out of scope for this
   environment):** actual sftp connectivity to the Storage Box,
   `ssh_config`'s `IdentityFile`/`UserKnownHostsFile` wiring against the
   real `known_hosts`, `HC_PING_URL` reachability. These require the
   production `resticRepository`/`storageBoxSshKey` secrets this
   environment doesn't have — first real `materia update` run on
   flutterina is the actual gate for that.

## Steps

1. Pull the pinned digest, run against a local filesystem repo (no
   network/production secrets needed). → verify: exit 0, `config` file
   created in the repo path, backup output shows files added.
2. If output is empty/wrong, extract the image filesystem
   (`podman create` + `podman export`) and `strings` the wrapper binary to
   check for expected log-message literals — confirms/denies a stale build.
3. If backup fails on temp file writes, add `--tmpfs /tmp` to the local
   `podman run` and re-verify.
4. Apply confirmed fixes to `restic-backup.container.gotmpl`, re-run the
   e01s05 grep verify suite to confirm no regressions.
5. Clean up local test images/containers/tmpdirs — no production data
   touched, nothing to leave behind.

## Out of scope

- Real sftp connectivity / production Storage Box verification — gated on
  the first real `materia update` on flutterina.
- Fixing the CI workflow's test gate (see Risks below) — flagged, not
  fixed, in this story.

## Risks

- **CI gate blind spot.** `restic-backup-image.yml`'s "Gate" steps only run
  `restic version` and `ssh -V` — they never invoke `/usr/local/bin/wrapper`
  at all. This is *why* a stale/broken wrapper build was able to publish
  successfully: the CI never actually exercises the wrapper binary. Flagging
  as a recommendation, not fixing here (touches e01s03/#17's already-shipped
  deliverable, needs a push + live CI run to validate) — recommend adding a
  `docker run --rm --entrypoint /usr/local/bin/wrapper <image>` gate step
  that exercises at minimum the guard-clause path (missing env → exit 1) as
  a smoke test, in a follow-up story.
