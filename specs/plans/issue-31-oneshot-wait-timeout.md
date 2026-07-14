# Implementation Plan — Issue #31: materia's oneshot wait-timeout is spurious

**issue:** https://github.com/kitten-lily/materia/issues/31
**risk:** P2 (removes an automatic-restart trigger for one component; no
behavior change to the backup job itself, only to how quickly a resource
change takes effect)
**epic:** standalone

## Summary

`restic-backup.service`'s `RestartedBy` trigger causes a spurious FATA
timeout in `materia-update` whenever any of its watched resources change
(`restic-backup.container`, `ssh_config`, `known_hosts`) and the backup
takes more than materia's internal default wait window (~95s observed).
The backup itself always completes successfully underneath — this is a
false-positive failure signal only.

## Root cause (confirmed against upstream `stryan/materia`, not this repo)

Materia represents "oneshot service, don't bother waiting for a specific
end state" with an internal sentinel, `services.StateInternalWildcard`
(`"wildcard"`), set by the planner whenever a `[[Services]]` entry has
`Oneshot = true` (`pkg/planner/planner.go`, `serviceActionWithMetadata`).

That sentinel is stored as a plain string on `actions.ActionMetadata.
ServiceUntilState` (`*string`) and is meant to be reconstructed later via
`services.NewServiceState(string) ServiceState`. But
`pkg/services/service_state.go`'s `serviceStateMap` deliberately excludes
`"wildcard"` from its lookup table (comment: `// Note we don't put this in
the map since its internal`) — so every reconstruction of the sentinel
silently falls through to `StateUnknown` instead of
`StateInternalWildcard`.

Three call sites all hit this same lossy round-trip:
- `pkg/executor/execute.go`, `Executor.Execute` — builds
  `expectedServices[...] = services.NewServiceState(*v.Metadata.ServiceUntilState)`
  for the final post-plan health check.
- `pkg/executor/service_helpers.go`, `waitService` — same conversion for
  the inline post-action wait.
- (both then call `ServiceManager.WaitUntilState`, `pkg/services/services.go`,
  which only short-circuits immediately when
  `state == StateInternalWildcard` — a comparison that can never be true
  once the string has round-tripped through `NewServiceState`)

Net effect: `WaitUntilState` never takes its intended "no-op, oneshot
services don't have a stable end state" path. It always enters the real
polling loop, waiting for `ActiveState == "unknown"` — a state a systemd
service never legitimately reports — until `e.defaultTimeout` elapses,
then returns `ErrOperationTimedOut`. This is deterministic, not a race:
any `Oneshot = true` + `RestartedBy`-triggered restart will always take
the full timeout and then report failure, regardless of how fast the
underlying job actually runs. It only looked intermittent in this repo
because the trigger only fires when `restic-backup`'s watched resources
actually change (first real trigger since rollout was the `d6b4fbd`
`BACKUP_PATHS` quoting fix).

This is a materia bug, not a `restic-backup` component bug or a repo
config problem — nothing in `components/restic-backup/` can avoid it
while `RestartedBy` is set on an `Oneshot` service.

## Decision: repo-side workaround now, upstream fix deferred

Per `AGENTS.md`'s "no upstream issues without permission" rule, we are
not filing anything against `stryan/materia` yet. The root-cause writeup
above is posted as a comment on issue #31 so it's ready to hand upstream
once permission is granted.

In the meantime, work around it here:

**Drop `RestartedBy` from the `restic-backup.service` entry in
`components/restic-backup/MANIFEST.toml`.**

```diff
 [[Services]]
 Service = "restic-backup.service"
-RestartedBy = ["restic-backup.container", "ssh_config", "known_hosts"]
 Stopped = true
 Oneshot = true
```

Effect:
- Materia still templates/installs the updated `restic-backup.container`,
  `ssh_config`, and `known_hosts` to disk on every `materia update` run,
  same as today — only the *automatic restart trigger* is removed.
- Without a `RestartedBy` trigger, `generateComponentServiceTriggers`
  never builds a "Restart Service" action for `restic-backup.service`, so
  the buggy `WaitUntilState`/wildcard path is never entered for this
  component.
- `restic-backup.timer` (`Static = true`) is unaffected — timer units
  don't go through this restart/wait code path at all. The timer fires
  daily regardless, and when it does, systemd starts
  `restic-backup.service` fresh from whatever files are on disk at that
  moment (i.e. the latest templated resources), organically.

**Trade-off:** a resource change (new pinned image digest, ssh_config
tweak, rotated `known_hosts`) now takes up to 24h to actually apply
(next timer fire) instead of applying immediately on the next
`materia update`. This fits the repo's existing pull-based reconciliation
model (`AGENTS.md`: "Push-based deploys: materia is pull-based by
default") and is a reasonable trade for eliminating a guaranteed false
failure signal on every such change. If sub-24h propagation is ever
needed, the real fix has to happen upstream in materia — this workaround
doesn't and can't add it back.

## Steps

1. Edit `components/restic-backup/MANIFEST.toml`: remove the
   `RestartedBy` line from the `restic-backup.service` entry.
2. Add an `AGENTS.md` gotcha documenting the upstream bug and why
   `RestartedBy` was dropped for this service, linking issue #31.
3. Post the root-cause writeup as a comment on issue #31 (leave the issue
   open — upstream fix still pending, tracked separately).
4. Preflight: `mise clean && mise ign --server-name flutterina`.
5. Commit as a single focused `fix:` commit.

## Out of scope

- Filing anything against `stryan/materia` (needs explicit permission
  first).
- Vendoring/patching a local materia build — not something this repo
  currently does for any other component; would be a bigger architectural
  change than this bug warrants.
- Touching `restic-backup.timer`'s `RestartedBy`/trigger config — it has
  none (`Static = true`), not affected.
