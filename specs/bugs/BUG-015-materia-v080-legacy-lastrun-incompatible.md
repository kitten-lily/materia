# BUG-015: materia v0.8.0 cannot read v0.7 `lastrun.toml`

**Status:** fixed
**Severity:** P1
**Found:** 2026-11-05
**Epic:** issue-173-materia-upgrade

## Symptom

The first guarded v0.8.0 dry run on bow failed before producing a plan:

```text
FATAL unable to get facts: failed to collect facts materia: toml: line 2
(last key "plan"): type mismatch for plan.Plan: expected table but found []any
```

The live quadlet was not changed.

## Root cause

materia v0.7 writes `/var/lib/materia/output/lastrun.toml` with `plan` as an
array of display strings:

```toml
plan = ["1. (...) Update ...", "2. (...) Restart ..."]
```

v0.8.0's facts collector reads last-run state using the new structured
`plan.Plan` type. The v0.7 array cannot unmarshal into that table, so fact
collection aborts every `plan`, `update`, or `facts` command before normal
planning begins.

This migration requirement is in the upstream v0.8.0 release notes: existing
`lastrun.toml` files must be removed before running the new facts collector.
It was not mentioned by the earlier #173 investigation, which only considered
resource and facts-name changes.

## Impact

Directly changing a live host's image pin from v0.7 to v0.8 leaves the host
unable to run materia. Because materia is the reconciler for every component,
that blocks all future GitOps updates on the host. The existing service may
also record the failed invocation through its healthchecks.io dead-man switch.

## Fix

`mise materia:sync-image` handles the state transition explicitly:

1. Its read-only v0.8 plan overlays a temporary empty directory at
   `/var/lib/materia/output`, so the old file is invisible to the new image
   without mutating host state.
2. Only after that plan succeeds and `--apply` is set, it detects v0.7 by the
   top-level `plan = [...]` in `output/lastrun.toml`, then removes that file and
   its paired `lastplan.toml` before starting v0.8. The files are diagnostics,
   not reconciliation input; v0.8 recreates its own new-format output after the
   run. The paired v0.8 `lastplan.toml` still uses an array, so it is never used
   alone as the legacy-format signal.

The task does not delete wildcard matches. Future v0.8 rotation files use the
new format and must remain available to facts.

## Regression verification

- On bow with the v0.7 file still present, the task's v0.8 dry run completes
  and leaves the host file unchanged.
- With `--apply`, the legacy file is absent before service start, the v0.8 run
  completes without `FATA`, and v0.8 writes a parseable new-format last-run
  file.
- A repeated v0.8 apply preserves the structured `lastrun.toml` and its paired
  `lastplan.toml`.
- A second v0.8 dry run succeeds against the newly generated state.

## Source

- Materia v0.8.0 release notes:
  <https://github.com/stryan/materia/releases/tag/v0.8.0>
