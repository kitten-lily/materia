# Implementation Plan — BUG-004: restic-backup timer can't re-trigger the service

**bug:** `specs/bugs/BUG-004-restic-backup-timer-remainaftereexit-noop.md`
**risk:** P2 (changes how a oneshot service reports its own state between
runs; no change to backup logic, image, secrets, or scheduling cadence)
**epic:** e01-restic-backup (already closed — post-ship discovered defect
fix)

## Summary

Drop `RemainAfterExit=yes` from `restic-backup.service`'s generated
`[Service]` section in `restic-backup.container.gotmpl`. Confirmed root
cause (BUG-004): this setting keeps the oneshot unit `active (exited)`
forever after its first successful run, which makes systemd treat every
subsequent `OnCalendar` timer fire's `start` job as a no-op (`start` on an
already-`active` unit does not re-run `ExecStart`). Removing it lets the
unit return to `inactive` after each run, so the timer's next fire behaves
like a normal `start` again.

## Why this is safe to remove

`RemainAfterExit=yes` was added in the original story
(`specs/epics/e01-restic-backup/e01s05-quadlet-resources.md`) for one
stated reason only: *"so the service status is inspectable after the job
exits."* Checked what actually depends on that:

- **materia** — `Oneshot = true` in `components/restic-backup/MANIFEST.toml`
  already tells materia to skip checking whether the service "started
  successfully" (materia manifest reference: "prevents materia from
  checking if this service started successfully"). Materia doesn't rely
  on `ActiveState=active` persisting for this service.
- **healthchecks.io** — the actual success/failure signal is the
  wrapper's own `HC_PING_URL` ping (`/start`, `/success`/`/fail`), not
  systemd unit state. Unaffected either way.
- **Human inspection** — without `RemainAfterExit=yes`, `systemctl
  status restic-backup.service` immediately after a run still shows
  `Active: inactive (dead) since <timestamp>` plus the last exit code
  (standard systemd behavior — the unit's last-run info isn't wiped
  until the *next* start). `journalctl -u restic-backup.service` is
  unaffected regardless. The only thing lost is the unit staying
  `active` indefinitely between runs — which is exactly the
  misleading-if-stale signal that caused this bug to go unnoticed for
  over a day on two hosts. Losing it is a net improvement for
  debuggability, not a regression.

No other component or gotcha in this repo depends on
`RemainAfterExit=yes` for `restic-backup` specifically (grep confirms
this string only appears in the one `.container.gotmpl`, the bug/plan
docs, and `specs/state.yaml`'s handoff note added while diagnosing this).

## Change

```diff
 [Service]
 Type=oneshot
-RemainAfterExit=yes
 TimeoutStartSec=900
```

## Steps

1. Edit `components/restic-backup/restic-backup.container.gotmpl`: remove
   the `RemainAfterExit=yes` line from `[Service]`.
2. Preflight: `mise clean && mise ign --server-name flutterina` — this
   only renders Butane/Ignition templates and won't touch component
   `.gotmpl` files (materia renders those at deploy time; there is no
   local materia template renderer — per AGENTS.md's `Environment=`
   quoting gotcha, this class of change "only surfaces as a runtime
   failure on the actual host"). Run it anyway to confirm nothing else
   broke; it's expected to stay green regardless since this file is out
   of its scope.
3. Commit as a single `fix:` commit.
4. **Real verification requires a live host**, since there's no local
   materia renderer for component resources. After push + a
   `materia-update` cycle picks up the change on both bow and
   flutterina (either via the next daily timer, or manually triggered
   via `sudo systemctl restart materia-update.service` for faster
   feedback):
   - Confirm the installed unit no longer has `RemainAfterExit=yes`:
     `systemctl cat restic-backup.service | grep RemainAfterExit`
     (expect empty).
   - Force a run: `sudo systemctl restart restic-backup.service` (or
     wait for the timer). Confirm `Result=success` and, critically,
     confirm `ActiveState=inactive` afterward (not `active`) — this is
     the actual proof the fix works, since an `active (exited)` state
     here would mean the bug is still present.
   - The real proof only comes from a *second* natural timer fire
     without any manual restart in between — confirm `systemctl show
     restic-backup.timer -p NextElapseUSecRealtime` stays populated
     (not empty) across at least one full `OnCalendar` cycle, and that
     `ExecMainStartTimestamp` actually advances to the next day's
     midnight on its own. This can't be confirmed same-day; needs a
     follow-up check ~24h after deploy.
5. Update `specs/bugs/BUG-004-...md` status from `open` to `fixed` (and
   `specs/bugs/registry.yaml`) once the 24h follow-up in step 4 confirms
   a real unattended timer re-trigger.
6. Update `AGENTS.md`'s BUG-004 gotcha entry to reflect the fix (or add a
   short follow-up note) once confirmed.

## Out of scope

- Any change to the backup schedule, image, secrets, or retention
  policy — this is purely a `[Service]` unit-state fix.
- Re-litigating issue #31's `RestartedBy` removal — that decision stands
  independently of this fix; both changes are compatible (the service
  can still lack `RestartedBy` and correctly self-trigger via its own
  timer once this fix lands).
- Filing anything upstream against `stryan/materia` or Podman — this
  bug is entirely in this repo's own `.container.gotmpl`, not a
  materia/quadlet defect.
