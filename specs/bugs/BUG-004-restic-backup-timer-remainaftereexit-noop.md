# BUG-004 — restic-backup.timer can't re-trigger restic-backup.service (RemainAfterExit=yes no-op)

**issue:** https://github.com/kitten-lily/materia/issues/38
**status:** open — attempted fix reverted, see "Fix attempt #1 (reverted)"
below; root cause confirmed but no safe fix found yet. Blocked on bow's
unrelated audiobookshelf failure being resolved first (need a healthy
`materia-update` on bow to verify any real fix).
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
status` is a symptom of this. Confirmed empirically: a manual
`systemctl restart restic-backup.service` on both hosts immediately
fixed both symptoms at once — the backup ran, and
`NextElapseUSecRealtime` correctly populated with the next day's
midnight.

Recent run history on both hosts confirms actual backups have only been
happening when a `.container.gotmpl` image-digest bump forced an
auto-restart (Renovate bumping the pinned digest, or a manual repo
change) — not from the timer's own daily fire, which has been a no-op
since the first successful run after each host's last restart-triggering
change.

## Fix attempt #1 (reverted 2026-07-15) — do not retry without a real plan

**Change tried:** drop `RemainAfterExit=yes` from the `[Service]`
section (commit `0b2bb11`), reasoning: the unit would then return to
`inactive` after each run, letting the timer's `start` job behave
normally. See `specs/plans/bug-004-remainaftereexit-timer-fix.md`
(deleted by the revert, `git show 0b2bb11^:specs/plans/bug-004-remainaftereexit-timer-fix.md`
to recover it) for the full (incorrect) reasoning.

**Result: broke materia-update entirely, on both hosts, for every
future run — not just restic-backup.** Deployed via push + manual
`systemctl restart materia-update.service`:

- **flutterina:** the 3-step plan (`Update Container
  restic-backup.container` → `Reload Host` → `Restart Container
  restic-backup.container`) ran for ~95 seconds then failed:
  ```
  FATA Execute in unhealthy state: Expected map[restic-backup.service:active], Actual map[restic-backup.service:inactive]
  ```
  Materia's own post-restart health check unconditionally expects the
  service it just restarted to end up `active` — **regardless of the
  `Oneshot = true` manifest flag**, which per the manifest reference
  only "prevents materia from checking if this service started
  successfully" for a *different* code path (the one issue #31 patched
  around, `WaitUntilState`'s wildcard-sentinel handling for
  `RestartedBy`-triggered restarts). This is a *separate* health-check
  codepath — the one materia runs for its own default "quadlet
  `.container` file changed → always restart" behavior — that isn't
  covered by the `Oneshot` flag at all. Since `restic-backup.container`
  changes on every Renovate digest bump (routine, frequent), this isn't
  a one-off: it would fail identically on every future image update,
  permanently blocking reconciliation of every component on the host
  (same "one component's fatal error aborts the entire host" behavior
  documented elsewhere in this file for the `baseDomain`/beszel-hub
  incident).
- **bow:** never actually reached the restic-backup restart step — a
  separate, pre-existing, unrelated failure (`audiobookshelf.service`
  failing to become healthy on its first install on bow) aborted the
  plan earlier (step 8 of 9). Confirmed via direct file inspection that
  bow's on-disk `restic-backup.container` was never actually updated to
  the broken version — no regression risk from this attempt on bow, but
  bow's `materia-update` is independently broken by the audiobookshelf
  issue (see "Related, unrelated finding" below).

**Reverted:** `git revert 0b2bb11` (commit `0620018`), pushed, and
`materia-update.service` re-triggered manually on flutterina — confirmed
green (`Finished materia-update.service`, no FATA). `restic-backup.service`
is back to `RemainAfterExit=yes`, ran successfully as part of the revert's
restart, and today's healthcheck ping should have fired again.

**This means BUG-004's underlying no-op is still present on both hosts
as of this writing** — we're back to the pre-fix state, just no longer
actively broken by a bad fix attempt. Tomorrow's `OnCalendar` fire will
again be a no-op on both hosts, same as before this bug was first
found.

## Related, unrelated finding: bow's audiobookshelf install is broken

Discovered as a side effect of testing fix attempt #1, **not caused by
it** — `materia-update.service` on bow fails independently at:
```
FATA service audiobookshelf.service unhealthy: error applying service change for audiobookshelf.service: service state change failed
```
This blocks `materia-update` on bow entirely (any future repo change —
not just restic-backup — will fail to apply on bow until this is
fixed), same "one component blocks the whole host" pattern as other
documented incidents. Needs its own investigation; flagged here only
because it was discovered during this investigation, not because it's
related to the timer bug. Not yet filed as its own BUG-00X entry —
do that before starting work on it.

## Fix not yet decided — constraints now understood

Whatever the real fix is, it must NOT rely on `restic-backup.service`
ending up `inactive` after a materia-triggered restart, because
materia's default "quadlet file changed → restart" health check hard-
requires `active` afterward, and that path can't be skipped via any
currently-known manifest flag (`Oneshot = true` doesn't cover it). This
rules out fix attempt #1's approach as written. Candidates not yet
evaluated:

1. A separate, materia-unmanaged systemd timer/oneshot pair (not a
   quadlet resource materia restarts) whose only job is `systemctl
   restart restic-backup.service` on a schedule — sidesteps materia's
   restart-health-check entirely since materia never touches this new
   unit after initial install. Adds a second timer to reason about;
   needs the interaction with `restic-backup.timer` (`Static = true`)
   thought through (probably replaces it, doesn't coexist with it).
2. Confirm whether materia has any lower-level setting (undocumented or
   otherwise) that skips the post-quadlet-restart health check
   entirely, separate from `Oneshot`. Needs reading materia's actual
   source (`stryan/materia`) rather than assuming from the manifest
   reference docs, same as issue #31's investigation did.
3. Accept the daily no-op as a known limitation and rely on Renovate's
   routine digest bumps (which DO successfully restart the service, as
   observed) as the de facto backup cadence, formally documenting that
   `resticOnCalendar` is aspirational, not actual, until a real fix
   lands. Not recommended — too fragile/opaque for something as
   important as backup cadence.

## Follow-up

- Needs a `specs/plans/` writeup for whichever candidate above is chosen
  — do not implement directly against `components/restic-backup/`
  again without one, per this attempt's outcome.
- File bow's audiobookshelf failure as its own bug entry before
  investigating it.
- Once a real fix lands, re-verify on both hosts across at least two
  real midnight `OnCalendar` fires (not just a manual restart) to
  confirm the timer actually re-triggers on its own, AND re-verify a
  `.container.gotmpl` change (e.g. next Renovate digest bump) still
  applies cleanly via `materia-update` without tripping the restart
  health check.
- Consider whether `specs/plans/issue-31-oneshot-wait-timeout.md` needs
  a corrective addendum noting its "fires daily regardless... starts
  fresh... organically" assumption was wrong.
