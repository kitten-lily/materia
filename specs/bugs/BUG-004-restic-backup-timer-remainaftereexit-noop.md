# BUG-004 — restic-backup.timer can't re-trigger restic-backup.service (RemainAfterExit=yes no-op)

**status:** open (workaround applied: manual restart on both hosts,
2026-07-15)
**found:** 2026-07-15, investigating healthchecks.io showing
`restic-backup-bow` and `restic-backup-flutterina` both down
**severity:** P1 (daily backups silently stopped running on both
production servers; no data loss, but backups were stale — bow's for
~22h, flutterina's for ~35h — before this was caught)
**epic:** e01-restic-backup (already closed — post-ship discovered
defect)

## Symptom

Healthchecks.io flagged both `restic-backup-bow` and
`restic-backup-flutterina` as down. `systemctl status
restic-backup.timer` on both hosts showed:

```
Active: active (running) since ...
Trigger: n/a
```

`systemctl list-timers` showed a `LastTriggerUSec` of that day's midnight
(the timer *had* fired, right on schedule) but no corresponding new
journal entries or podman container activity for `restic-backup.service`
around that time — the service's `ExecMainStartTimestamp`/
`ExecMainExitTimestamp` were stuck on an earlier run, over a day old on
both hosts (bow: last real run 2026-07-14 17:48; flutterina: last real
run 2026-07-14 05:00).

## Root cause

`restic-backup.container.gotmpl`'s generated unit sets:

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=900
```

Once a `Type=oneshot` service with `RemainAfterExit=yes` completes
successfully, it settles into `active (exited)` and **stays there** —
that's the point of the setting (lets `systemctl status`/materia inspect
`Result=success` after the fact instead of the unit vanishing back to
`inactive`).

But `restic-backup.timer`'s `OnCalendar=daily` fires by issuing a plain
`systemctl start restic-backup.service` job. Per systemd job semantics,
`start` on a unit that is already `active` is a no-op — it does **not**
re-run `ExecStart`. Only `restart` (or first manually stopping the unit)
forces re-execution.

Net effect: **the very first successful run permanently blocks the timer
from ever triggering the service again**, until something else (a
manual `restart`, or materia auto-restarting the service because its
`.container.gotmpl` changed — quadlet `.container` resource changes
always trigger a restart, independent of any `RestartedBy` config)
happens to cycle it through `inactive`. `Trigger: n/a` in `systemctl
status` is a symptom of this: the timer's next-elapse calculation
appears to get stuck when its target unit's job silently no-ops instead
of completing a normal start transition. Confirmed empirically: a manual
`systemctl restart restic-backup.service` on bow immediately fixed both
symptoms at once — the backup ran, and `NextElapseUSecRealtime`
correctly populated with the next day's midnight.

Recent run history on both hosts confirms actual backups have only been
happening when a `.container.gotmpl` image-digest bump forced an
auto-restart (Renovate bumping the pinned digest, or a manual repo
change) — not from the timer's own daily fire, which has been a no-op
since the first successful run after each host's last restart-triggering
change.

## Relationship to issue #31 / BUG's workaround

This is a **different bug** from the already-documented issue #31
(materia's own `WaitUntilState` polling for oneshot services during a
materia-triggered restart — see `specs/plans/issue-31-oneshot-wait-timeout.md`).
That fix removed `RestartedBy` from `restic-backup.service` specifically
so materia-managed resource changes (like `known_hosts`) wouldn't force
a restart materia then hangs waiting on.

Issue #31's plan explicitly assumed removing `RestartedBy` was safe
because *"`restic-backup.timer` fires daily regardless, and when it
does, systemd starts `restic-backup.service` fresh from whatever files
are on disk at that moment ... organically."* **That assumption is
false** — this bug shows the timer's own daily fire has been silently
inert since the first successful run. The two bugs compound: with
`RestartedBy` removed (issue #31's fix) *and* the timer unable to
re-trigger (this bug), the only remaining path that actually re-runs
`restic-backup.service` is an incidental `.container.gotmpl` image
change — i.e., backups now only happen when Renovate bumps the pinned
digest, not on any predictable schedule.

## Workaround applied (not a fix)

`sudo systemctl restart restic-backup.service` run manually on both bow
and flutterina (2026-07-15) to unblock the current day's backup and
clear the healthchecks.io alerts. This does **not** prevent tomorrow's
`OnCalendar` fire from hitting the identical no-op once today's run
settles back into `active (exited)`.

## Fix not yet decided

Options considered, none implemented yet — needs a plan before any repo
change per the workflow mandate:

1. Drop `RemainAfterExit=yes` so the unit returns to `inactive` after
   each run, letting the timer's plain `start` job behave normally.
   Trade-off: loses `systemctl status`'s post-hoc `Result=`/`ActiveState`
   introspection for the service between runs (Result may still be
   visible transiently — needs verification). Healthchecks.io pings
   already report external status per-run, so this may be an acceptable
   trade.
2. Add some other resource/mechanism that forces a `stop` (not `start`)
   between the container's exit and the next timer fire, so the unit is
   back in `inactive` by the time `OnCalendar` fires. Unclear if quadlet
   supports this cleanly.
3. Investigate whether materia's `Oneshot = true` service flag (which
   likely drives the `RemainAfterExit=yes` generation) can be changed
   without losing whatever materia-side behavior depends on it — needs
   checking materia's manifest reference / source before assuming
   option 1 is side-effect-free.

## Follow-up

- Needs a `specs/plans/` writeup before implementing any of the above.
- Once fixed, re-verify on both hosts across at least two real midnight
  `OnCalendar` fires (not just a manual restart) to confirm the timer
  actually re-triggers on its own.
- Consider whether `specs/plans/issue-31-oneshot-wait-timeout.md` needs
  a corrective addendum noting its "fires daily regardless" assumption
  was wrong.
