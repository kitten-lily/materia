# BUG-010 — postgres v17→v18 bump landed without the volume wipe: 4 days of blocked reconciliation on bow

**status:** fixed (remediated live on bow 2026-09-21 16:15 UTC)
**found:** 2026-09-21, investigating failed services on bow
**severity:** P1 (`materia-update` failed on every run from 2026-09-18
onward — reconciliation of *every* component on bow blocked, not just
mediamanager)
**epic:** mediamanager (surfaced by issue #104 / commit `612f8c3`)

## Symptom

`systemctl --failed` on bow:

```
materia-update.service           failed
mediamanager-postgres.service    failed
mediamanager.service             failed
systemd-sysupdate-reboot.service failed   ← unrelated, see "Not a bug" below
```

`mediamanager-postgres.service` crash-looped to `start-limit-hit`:

```
PostgreSQL Database directory appears to contain a database; Skipping initialization
FATAL:  database files are incompatible with server
DETAIL: The data directory was initialized by PostgreSQL version 17,
        which is not compatible with this version
```

`materia-update.service` then aborted its whole plan on the dependent step:

```
WARN 0/8 steps completed
FATA service mediamanager-postgres.service unhealthy: error ...
```

Failure dates from the journal — `materia-update` succeeded
`2026-09-17T05:00:08Z`, then failed identically on
`09-18`, `09-19`, `09-20`, `09-21`. Four consecutive days during which no
commit reached bow, including `1ce9be7` (BUG-009 pod fix), `34b860f`
(healthchecks), `424ca4e` (beszel D-Bus), and every Renovate digest bump.

## Root cause

Commit `612f8c3` ("feat(mediamanager): bump postgres 17 -> 18 via
rebuild-in-place", closes #104) changed the image pin from
`reg.mini.dev/postgres:v17.11` to `v18.6`. Postgres refuses to start
against a `PGDATA` initialized by a different major version, so the bump
was only valid **paired with a wipe of `mediamanager-db.volume`**.

That wipe existed only as prose — in the commit message ("`mediamanager-db.volume`
gets wiped … at deploy time") and in the quadlet's comment block. Nothing
in the repo performs it: materia installs the new `.container` file and
restarts the service, and has no concept of "also destroy this volume
first". The host still held the v17 cluster
(`/var/lib/containers/storage/volumes/systemd-mediamanager-db/_data/PG_VERSION`
= `17`, 63 MB).

The blast radius is the real defect. materia's plan is all-or-nothing: one
service that can't reach its expected state aborts the run, so a
single-component data-migration miss silently froze the entire host — the
same failure mode AGENTS.md already records for a missing attribute key
(`baseDomain`) and a wrong expected state (BUG-004's `RemainAfterExit`
revert).

## Remediation applied

The commit's premise was verified before acting rather than trusted: a
throwaway v17 container was started against the volume and the live row
counts read —

```
apscheduler_jobs  6
alembic_version   1
user              1
```

No rows in `show`, `movie`, `episode`, `season`, `*_request`, `torrent`,
`indexer_query_result`. "Not in production use" held.

1. `pg_dumpall` from a temporary v17 container →
   `/home/core/mediamanager-pg17-2026-09-21.sql` (35 KB, 15 `CREATE TABLE`).
   Written to `/home/core`, not `/tmp` — `/tmp` is tmpfs on Flatcar.
2. `systemctl stop mediamanager.service mediamanager-postgres.service`
   `mediamanager-db-volume.service`; `reset-failed`.
3. `podman volume rm systemd-mediamanager-db`.
4. Start `mediamanager-db-volume.service` → `mediamanager-postgres.service`
   → `mediamanager.service`.
5. `systemctl start materia-update.service`.

The dump was **not** restored: the only content was one admin user and
apscheduler's job rows, both of which the app recreates (the fresh-install
banner creates a default admin, and apscheduler re-registers its jobs on
boot).

## Verification

- `PG_VERSION` on the recreated volume = `18`.
- `mediamanager-postgres` → `Up (healthy)`, `pg_isready` passing.
- `mediamanager` ran `alembic upgrade head` cleanly through
  `2c61f662ca9e` and started uvicorn.
- `materia-update` → `Nothing to do`, `Deactivated successfully`, exit 0.
- Recent commits confirmed present on the host after the run:
  `beszel-agent.container` has
  `Volume=/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro`
  (`424ca4e`), `newt.container` has
  `HealthCmd=test -f /tmp/newt-health` (`34b860f`).
- `systemctl --failed` reduced to `systemd-sysupdate-reboot.service` only.

## Not a bug: `systemd-sysupdate-reboot.service`

Stock systemd unit, not configured by this repo. Flatcar ships a single
placeholder transfer definition, `/usr/lib/sysupdate.d/noop.transfer`, whose
`MatchPattern=invalid@v.raw` is designed never to match. So
`/usr/lib/systemd/systemd-sysupdate reboot` exits 1 with `Couldn't find any
suitable installed versions.` daily at ~04:10. Flatcar's real updater is
`update-engine.service` (`active`, `UPDATE_STATUS_IDLE`, OS at 4757.2.0).
Harmless, but it is permanent noise in `systemctl --failed`, which is
exactly where a real failure would otherwise be visible — masking risk, not
functional risk. Masking `systemd-sysupdate-reboot.timer` in the `.bu`
templates would clear it; not done here, out of scope for this
investigation.

## Prevention

- A major database version bump is **not** a Renovate-class change and must
  not be landed as one. If the bump requires destroying state, the
  destruction has to be an executed step (a `mise` task, or a documented
  runbook line actually run against each host), not a sentence in the commit
  body — see the AGENTS.md gotcha added alongside this record.
- After landing any change that needs a host-side manual step, confirm the
  next `materia-update` on the affected host actually succeeded. Four days
  of red went unnoticed because nothing watches bow's materia-update
  result; the healthchecks.io ping in the `.bu` covers the *service* ping,
  and this run did fail loudly there — worth re-checking that bow's
  `materia-update-bow` check is registered and alerting.

## Unrelated observation

`/var/lib/materia-data` is at **96 %** (5.0T of 5.5T, 229 G free). BUG-006
sized buildbarn's CAS at 150 G against 357 G free; the margin has since
halved. Not actioned here.
