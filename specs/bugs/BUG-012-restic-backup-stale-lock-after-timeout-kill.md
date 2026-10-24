# BUG-012 — restic jobs killed at TimeoutStartSec leave stale locks; every later run fails

**status:** fixed (2026-10-24; commits `2102da1`, `362ce3d`, `c1e805b`)
**found:** 2026-10-24, during #163 phase 1 (`systemctl --failed` on flutterina)
**severity:** P1 (flutterina: no backup since 2026-10-15; bow: retention not
applied since 2026-10-13; both alerting only via healthchecks.io)
**epic:** restic-backup

## Symptom

- **flutterina:** last snapshot `e9c24abc` (2026-10-15 00:01). Every run since
  2026-10-16 logs `restic cat config failed (exit status 11), initializing
  repository`, then `Fatal: create repository ... config file already exists`,
  and exits 1 after ~3 s. No backup is taken.
- **bow:** the backup itself succeeds every night (`snapshot ... saved`), but
  `forget --prune` fails with `unable to create lock in backend: repository is
  already locked by PID 32 on 19a173287f03` since 2026-10-13. The job exits
  non-zero and retention never runs.
- The wrapper sent `/fail` to healthchecks.io on every run (no
  `ping (non-fatal)` errors in the journal), so the checks went down. Nobody
  acted on it; the notification channels are outside this repo.

## Root cause

1. `restic-backup.container.gotmpl` sets `TimeoutStartSec=900`. When a run
   takes longer, systemd terminates the unit and podman kills the container.
   restic dies without removing its lock file from the repository.
   - flutterina, 2026-10-15: backup (8 min) + `forget --prune` (6.5 min).
     Prune printed `done` at 00:14:59; the kill came at 00:15:01, before it
     released its **exclusive** lock (created 00:08:23, `hostname
     0d0cc7c7182f`, PID 27; `restic cat lock`).
   - bow, 2026-10-13: the backup alone ran past 15 min and was killed,
     leaving a **shared** lock (container `19a173287f03`, PID 32).
2. restic does not ignore stale locks when acquiring one; only `restic unlock`
   removes them. A stale exclusive lock blocks every command (flutterina); a
   stale shared lock still allows `backup` but blocks the exclusive lock
   `prune` needs (bow). Every container has a random hostname, so restic
   cannot even use its same-host dead-PID check.
3. The wrapper's `ensureRepo` treats **any** non-zero `restic cat config` as
   "repository does not exist" and runs `restic init`. restic ≥0.17 reports
   that case as exit **10** and a lock failure as exit **11**. On flutterina
   the init then fails with a misleading "config file already exists", which
   buries the real lock error.

Related, found during the same investigation:
`.github/workflows/restic-backup-image.yml` passes `resticVersion=v0.18.0` as
a build-arg in both build steps, overriding the Dockerfile's `ARG
resticVersion=v0.19.1`. Renovate's restic bump (#18) changed the Dockerfile
only, so every image since has shipped restic 0.18.0 (`restic version` in the
deployed image).

## Fix

- Wrapper: run `restic unlock` before the job. Without `--remove-all` it only
  removes stale locks (live restic processes refresh theirs every 5 min, so a
  lock older than 30 min belongs to a dead process). Each host has its own
  repository and one timer, so no live job is ever in another container.
- Wrapper: `ensureRepo` runs `restic init` only on exit 10; any other failure
  is returned with its exit code.
- Quadlet: `TimeoutStartSec=4h`, so a long but healthy run is not killed in
  the first place. The daily timer leaves plenty of headroom.
- Workflow (separate commit): drop the hardcoded `resticVersion` /
  `opensshVersion` build-args so the Dockerfile `ARG`s, which Renovate
  maintains, are what gets built. restic 0.19.1 needs Go ≥ 1.25.8, so the
  builder moves from `golang:1.23-alpine` to `golang:1.25-alpine` (1.25.14).
- One-off: `restic unlock` on flutterina's repository now, then run the job.

## Verify

- verify (flutterina): `restic list locks --no-lock` → empty; a new snapshot
  dated today in `restic snapshots`
- verify (bow): the next run logs no `already locked`, and `forget --prune`
  completes
- verify: `systemctl show -p Result restic-backup.service` → `Result=success`
  on both hosts
- verify: the deployed image's `restic version` → 0.19.1

## Results (2026-10-24)

| Check | flutterina | bow |
|---|---|---|
| Stale lock | removed by hand (`restic unlock`: `successfully removed 1 locks`) before the fix shipped | removed by the new wrapper's `restic unlock` on the first run (`successfully removed 1 locks`, 11 days old) |
| Run with new image | snapshot `eea09c2d`, prune `done` | snapshot `4eb8b5d8`, 13 overdue snapshots forgotten, prune `done` |
| `Result` | `success` | `success` |
| Locks left / `systemctl --failed` | 0 / empty | — / empty |
| `restic version` in deployed image | 0.19.1 (go1.25.14) | same digest |

Image `sha256:21670b45…` = `sha-362ce3d` from run 40079325000, all gates
green including the new bootstrap gate.

Local reproduction with the old image (`c0e7bcc`): a `backup --stdin`
container killed with `podman kill` left a shared lock, and the old wrapper
then ended `backup exit 0, forget exit 11`, matching bow. The new image
kept a fresh (<30 min) lock in place (same exit 11, correct: it could
belong to a live run), failed a wrong password at exit 12 without
attempting `init`, and bootstrapped a missing repository via exit 10.

Open, outside the repo: healthchecks.io received `/fail` from both hosts
every night (no `ping (non-fatal)` errors), yet nobody was notified. Check
the `restic-backup-<host>` checks' notification channels.
