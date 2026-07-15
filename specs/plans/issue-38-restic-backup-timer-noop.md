# Implementation Plan — Issue #38: restic-backup.timer no-op (BUG-004)

**issue:** https://github.com/kitten-lily/materia/issues/38
**bug:** `specs/bugs/BUG-004-restic-backup-timer-remainaftereexit-noop.md`
**risk:** P2 (changes how restic-backup gets restarted; no change to
backup logic, image, secrets, or the daily cadence's intent — only how
reliably it's enforced)
**epic:** e01-restic-backup (already closed — post-ship discovered
defect fix)
**prerequisite (done):** BUG-005 — bow's `materia-update` needed to be
healthy to verify anything here; fixed 2026-07-15.

## Summary

Confirmed against `stryan/materia` source (not assumed from docs) that
BUG-004 cannot be fixed by touching `RemainAfterExit=yes` alone — fix
attempt #1 already proved that path broken (reverted, see BUG-004's
postmortem). There are actually **two independent materia bugs**
stacked on top of the original systemd timer/`RemainAfterExit=yes`
interaction, and both must be sidestepped, not fixed, since fixing them
requires upstream materia changes we don't control.

The fix: stop routing `restic-backup.service`'s restarts through
materia's tracked restart/health-check machinery at all. Add a small
materia-unmanaged wrapper `.service` + retarget the existing
`restic-backup.timer` at it. The wrapper's only job is `systemctl
restart restic-backup.service` — issued by systemd itself, invisible to
materia's `Executor.Execute`, so materia never waits on or asserts a
final state for `restic-backup.service` again.

## Root cause, confirmed in materia source

### Bug A (already known — issue #31): `RestartedBy`-triggered oneshot restarts

`pkg/planner/planner.go`'s `serviceActionWithMetadata` (used for
`RestartedBy`/`ReloadedBy`-triggered actions) correctly detects
`Oneshot = true` and sets `ActionMetadata.ServiceUntilState` to the
internal wildcard sentinel (`services.StateInternalWildcard`, i.e.
`"wildcard"`). But `pkg/services/service_state.go`'s `NewServiceState`
lookup table deliberately excludes `"wildcard"` — every place that
reconstructs it from the stored string gets `StateUnknown` instead, so
`Executor.Execute`'s final-state wait polls for `ActiveState=="unknown"`
(never legitimately true) until timeout. This is why `RestartedBy` was
already removed from `restic-backup.service`'s manifest entry.

### Bug B (newly found, 2026-07-15 — not previously documented):
default quadlet-restart trigger never checks `Oneshot` at all

With `RestartedBy` empty, materia falls back to its default "quadlet
`.container`/`.pod` file changed → restart" behavior
(`generateComponentServiceTriggers`, the loop over
`newComponent.Resources.List()` for `res.Kind ==
ResourceTypeContainer || ResourceTypePod`). This calls
`resourceActionWithMetadata`, **not** `serviceActionWithMetadata`.

For a plain registry-image container (like `restic-backup.container`,
`Image=ghcr.io/.../restic-backup@sha256:...` — not a local `.build`/
`.image` quadlet), `resourceActionWithMetadata`'s final return
(`pkg/planner/planner.go` ~line 750) is:

```go
return actions.Action{
    Todo:   a,
    Parent: parent,
    Target: parent.InstantiateResource(res),
}, nil
```

**No `Metadata` field at all** — it never looks up
`newComponent.ServiceConfigs` to check whether the target service is
`Oneshot`. (There's a separate, adjacent branch for `.build`/`.image`-
referencing containers that *does* look up `Oneshot` and compute the
wildcard sentinel correctly — but then discards it: its `return`
statement constructs a fresh `&actions.ActionMetadata{ServiceTimeout:
&timeout}` literal instead of returning the `metadata` variable it just
built. That's a second, narrower bug in the same function, irrelevant
to us since `restic-backup.container`'s image isn't `.build`/`.image`-
based — noted here only because it's easy to misread as "the Oneshot
check happens somewhere in this function" when it silently doesn't
survive to the return value either way.)

Back in `pkg/executor/execute.go`'s `Execute`, an action with nil
`Metadata` (or nil `ServiceUntilState`) falls into `lastAction[...] =
v.Todo`, and for `ActionRestart` this unconditionally sets
`expectedServices[serv.Name] = services.StateActive` — no `Oneshot`
check possible at this point, the information is already gone.

**Net effect:** any `.container`/`.pod` resource change to a plain-image
Oneshot service, restarted via materia's default trigger (no
`RestartedBy` involved), will always make materia wait for `active` and
fail once the service — correctly, per systemd oneshot semantics —
settles into `inactive` (without `RemainAfterExit=yes`) or stays
`active (exited)` in a way that still doesn't match what materia
expects at the right moment. This is exactly what fix attempt #1 hit
(`FATA Execute in unhealthy state: Expected map[restic-backup.service:active], Actual map[...:inactive]`),
confirmed independent of `Oneshot = true` in the component manifest —
that flag is never consulted on this code path.

### Conclusion

Neither known trigger path (`RestartedBy` nor the default auto-trigger)
can correctly restart a `Type=oneshot` service without materia either
timing out (Bug A) or asserting a state the service was never going to
be in (Bug B). **This repo cannot fix either bug locally** — both are
in materia's Go source. The only viable repo-side fix is to stop
letting materia issue *any* tracked restart action against
`restic-backup.service`.

## Design

1. **Stop materia from auto-restarting `restic-backup.service` on
   `.container` changes.** Add `[Settings] NoRestart = true` to
   `components/restic-backup/MANIFEST.toml`. Per
   `materia-manifest.5`: *"By default, materia will restart services
   belonging to `.container` and `.pod` resources when they are
   updated. Set to `true` to disable this behaviour."* This is
   component-scoped, and `restic-backup` has exactly one
   container-backed service, so there's no other service in this
   component to accidentally affect. File installation (the actual
   `.container` content on disk) is unaffected — only the auto-restart
   trigger is suppressed. Confirmed in source: this flag short-circuits
   `generateComponentServiceTriggers` before it reaches the
   `ResourceTypeContainer`/`ResourceTypePod` loop that calls the buggy
   `resourceActionWithMetadata` path.

2. **Add a materia-unmanaged wrapper service** —
   `components/restic-backup/restic-backup-trigger.service` (plain data
   resource, no `.gotmpl`, nothing to template):

   ```ini
   [Unit]
   Description=Restart restic-backup.service (RemainAfterExit=yes timer workaround, see BUG-004)

   [Service]
   Type=oneshot
   ExecStart=/usr/bin/systemctl restart restic-backup.service
   ```

   No `[Install]` section — timer-activated only, same pattern as
   `restic-backup.service` itself. Confirmed materia classifies `.service`
   files as `ResourceTypeService` (`pkg/components/component.go`), which
   the auto-restart trigger loop explicitly does **not** touch (it only
   fires for `ResourceTypeContainer`/`ResourceTypePod`) — so this wrapper
   is never subject to Bug B regardless of the `NoRestart` setting. It's
   also never referenced by any `RestartedBy`/`ReloadedBy`, so Bug A
   doesn't apply either. Materia will install this file and, if it ever
   changes, simply overwrite it on disk with no restart attempt — fine,
   since it's a stateless one-shot command wrapper, not a long-running
   process; a content change only affects the *next* timer-triggered
   invocation.

   `systemctl restart` (not `start`) is the whole point: it
   unconditionally re-runs `ExecStart` on the target unit regardless of
   its current `ActiveState`, sidestepping the original systemd
   `start`-on-already-`active`-is-a-no-op behavior that started this
   whole investigation.

3. **Retarget the existing timer.** Edit
   `components/restic-backup/restic-backup.timer.gotmpl`:

   ```diff
    [Timer]
    OnCalendar={{ m_default "resticOnCalendar" "daily" }}
    Persistent=true
   -Unit=restic-backup.service
   +Unit=restic-backup-trigger.service
   ```

   No other change to the timer — same `Static = true` manifest entry,
   same schedule attribute, same `Persistent=true` (still useful: a
   missed fire due to downtime still catches up and restarts the
   trigger on next boot).

4. **Manifest additions** to `components/restic-backup/MANIFEST.toml`:

   ```diff
    Secrets = ["resticPassword", "storageBoxSshKey"]
   +
   +[Settings]
   +NoRestart = true

    [Defaults]
    resticKeepDaily = "7"
    ...

    [[Services]]
    Service = "restic-backup.service"
    Stopped = true
    Oneshot = true

   +[[Services]]
   +Service = "restic-backup-trigger.service"
   +Stopped = true
   +
    [[Services]]
    Service = "restic-backup.timer"
    Static = true
   ```

   `restic-backup.service`'s existing entry (`Stopped = true, Oneshot =
   true`) is untouched — it's still correct: materia should never
   directly start/restart it (only the trigger wrapper does, via a raw
   `systemctl` call materia never sees), and `Oneshot = true` still
   correctly suppresses materia's *initial-install* start-check for it
   (a separate code path from the two bugs above, unaffected by this
   fix).

## Trade-off (deliberate, consistent with issue #31's precedent)

Image digest bumps (Renovate) and any future config resource changes to
`restic-backup.container`/`ssh_config`/`known_hosts` now **all** take up
to 24h to apply (next `restic-backup.timer` fire), not just the
`RestartedBy`-covered ones issue #31 already accepted this trade-off
for. This is a behavior change from today, where quadlet-file changes
*did* apply immediately (that was, in fact, the only thing keeping
backups running at all before today — see BUG-004). Accepting slower
propagation uniformly, in exchange for the daily schedule actually
being the real, reliable trigger mechanism instead of an accident, is
the point of this fix. Document this explicitly in the `AGENTS.md`
gotcha once implemented.

## Steps

1. Create `components/restic-backup/restic-backup-trigger.service`
   (content above).
2. Edit `components/restic-backup/restic-backup.timer.gotmpl`:
   `Unit=restic-backup.service` → `Unit=restic-backup-trigger.service`.
3. Edit `components/restic-backup/MANIFEST.toml`: add `[Settings]
   NoRestart = true` (top of file, before `[Defaults]` — TOML table
   ordering doesn't matter functionally here, but keep it near the top
   for visibility given the `Secrets` top-level-key gotcha already
   documented in `AGENTS.md`) and the new `[[Services]]` entry for
   `restic-backup-trigger.service`.
4. Preflight: `mise clean && mise ign --server-name flutterina` — as
   with the reverted attempt, this won't exercise the actual component
   template (no local materia renderer exists), but run it to confirm
   nothing else broke.
5. Commit as a single `fix:` commit.
6. Push, then trigger `materia-update` manually on **both** hosts
   (`sudo systemctl restart materia-update.service`) for fast feedback
   rather than waiting for the daily timer.
7. **Verification (this is the part that actually matters — there is no
   local renderer for this class of change):**
   - Confirm `materia-update` finishes clean on both hosts (no FATA) —
     this proves `NoRestart` actually suppressed the problematic
     trigger, i.e. Bug A/B are avoided.
   - Confirm the new files are installed: `systemctl cat
     restic-backup-trigger.service`, `systemctl cat
     restic-backup.timer | grep Unit=`.
   - Confirm `restic-backup.timer`'s `Trigger:` field is populated (not
     `n/a`) immediately after install.
   - Manually fire it once: `sudo systemctl start
     restic-backup-trigger.service` (note: `start`, not `restart` — this
     is the wrapper's *own* first-ever activation, which is fine since
     the wrapper itself has no `RemainAfterExit`/stuck-active problem).
     Confirm `restic-backup.service` actually ran (`ExecMainStartTimestamp`
     advances, `Result=success`) and settles back to whatever state
     `RemainAfterExit=yes` puts it in (`active (exited)` — expected and
     fine now, since nothing but the wrapper's `restart` command ever
     touches it again).
   - **The real proof needs 2+ real midnight `OnCalendar` fires without
     any manual intervention.** Check back ~24h and ~48h after deploy:
     `ExecMainStartTimestamp` on `restic-backup.service` should advance
     on its own each day, and `systemctl show restic-backup.timer -p
     NextElapseUSecRealtime` should stay populated throughout (never
     reverting to empty/`n/a`).
   - Confirm a `.container.gotmpl` change (wait for the next real
     Renovate digest-bump PR, or simulate by hand-editing the image tag
     temporarily) installs the new file but does **not** immediately
     restart the container — the change should only take effect at the
     next timer fire. This confirms `NoRestart` is working as intended
     and we're not accidentally still triggering Bug A/B some other way.
8. Once 2+ unattended timer cycles are confirmed on both hosts, update
   `specs/bugs/BUG-004-...md` status to `fixed`, close issue #38, and
   add an `AGENTS.md` gotcha summarizing the two materia bugs and the
   wrapper-timer workaround (supersedes/extends the existing BUG-004
   gotcha entry rather than duplicating it).

## Out of scope

- Fixing either materia bug upstream — needs explicit permission per
  `AGENTS.md`'s "no upstream issues without permission" rule. The root-
  cause writeup above (with exact file/line citations) is ready to hand
  off once permission is granted; until then it stays local
  documentation only.
- Re-adding `RestartedBy` for faster (<24h) propagation of image/config
  changes — deliberately not pursued; see "Trade-off" above.
- Any change to `restic-backup.service`'s own manifest entry
  (`Stopped`, `Oneshot`) — still correct as-is, untouched by this fix.
- Vendoring/patching a local materia build.
