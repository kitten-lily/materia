# Plan: upgrade live hosts to materia v0.8.0 (#173)

## Problem

The provisioning templates pin materia
`v0.8.0@sha256:7276f4a7f759c1fab2016dd438fd910b982dbc436513dd36fe44936fda6d532d`,
but Ignition is first-boot-only. Existing hosts still have a floating `:stable`
reference in `/etc/containers/systemd/materia-update.container`; bow is known to
be running v0.7.0. The adopted-host renderer also still emits `:stable`, and the
Renovate custom manager scans only Butane templates. A template bump therefore
neither reaches existing hosts nor updates future adopted-host installs.

This drift already exposed bow to the v0.7.0 phantom service-action bug during
#86. The fix must cover both repository sources and make the live host mutation
an executable, guarded operation rather than a prose-only deployment step.

## Baseline

Before implementation:

- `mise clean && mise ign --server-name flutterina` passes.
- `git status --short` is empty after the render (the generated Ignition file is
  ignored).
- The two Butane templates use the same v0.8.0 digest.
- `.mise/tasks/server/adopt-render` uses `ghcr.io/stryan/materia:stable`.
- Renovate's materia custom manager matches only
  `provisioning/templates/*.bu`.
- Both Butane templates use literal `HostName=%q`; the renderer does not
  substitute `%q`.

Two guarded bow plans exposed additional migration blockers before any live
mutation:

- v0.8 cannot unmarshal v0.7's `output/lastrun.toml` (`plan.Plan: expected
  table but found []any`); see BUG-015.
- With the old output isolated but literal `HostName=%q`, v0.8 finds no matching
  host and plans removal of every installed component; see BUG-016.


## Decisions

### One image pin in every repository-managed installer

Change `adopt-render` to the exact image reference already used by both Butane
templates. Extend the existing Renovate custom manager's file patterns to match
both the templates and `.mise/tasks/server/adopt-render`; keep one regex and one
dependency definition so a Renovate PR updates all three pins together.

### Explicit live-host migration task

Add `mise materia:sync-image --target <user@host> [--apply]`.

The task reads the pin from the two templates and adopted-host renderer, and
fails if those repository sources differ. It then uses one SSH session and runs
as root on the host. Every invocation:

1. Reads the live `Image=` and `HostName=` values.
2. Reads the actual OS hostname from the target.
3. Reports the current `materia` container image ID and that image's creation
   timestamp when the oneshot container still exists.
4. Runs `materia plan` from the pinned v0.8.0 image with the live environment,
   host network, security-label setting and bind mounts, but with the actual OS
   hostname.
5. Overlays a temporary empty `/var/lib/materia/output` for the plan. This keeps
   the read-only mode non-mutating while hiding v0.7's incompatible
   `lastrun.toml` from v0.8 facts collection.

The default is read-only. `--apply` proceeds only after that plan succeeds, then:

1. Replaces only the live quadlet's `Image=` and `HostName=` lines, preserving
   all other content and the file's owner/mode.
2. When `output/lastrun.toml` contains v0.7's top-level `plan = [...]`,
   removes that file and its paired `lastplan.toml`. Re-running the task after
   v0.8 writes the structured `[plan]` table preserves both diagnostics.
3. Runs `systemctl daemon-reload` and starts `materia-update.service`.
4. Prints and checks only the journal entries from that invocation for `FATA`.
5. Verifies the local image digest and generated service command use the
   repository pin; if the oneshot container remains, also verifies its image ID.
6. Waits for restart-time health probes to settle, then verifies the run added
   no failed units. Failures that disappeared during reconciliation are allowed.

The wrapper enables SSH keepalives. If a managed network-path service restart
drops the apply connection, it reconnects and repeats the idempotent
plan/apply/verification path; the second plan is expected to report no changes.

The task requires exactly one `Image=` line for the materia image. A missing or
ambiguous line fails before mutation. Remote host details are supplied through
`--target`; no deployment-specific addresses enter the repository.

### Host rollout order

Run the task without `--apply`, inspect the plan, then apply, one host at a time:

1. bow — widest component coverage and known v0.7.0.
2. flutterina — edge node; inspect the plan before accepting the expected v0.8
   initial file-update/restart wave.
3. krytis-runner — adopted host and direct proof of the renderer gap.

For every dry run, reject the rollout if the plan contains an `Unknown` action,
a service `Disable` action, or unexpected content changes in resources rendered
from `m_facts "hostname"`.

Do not change the six hostname fact calls in this change. v0.7.0 cannot resolve
the v0.8 `host.hostname` namespace, so that cleanup is safe only after every live
host has upgraded.

## Changes

- `.mise/tasks/server/adopt-render`: use the v0.8.0 digest pin.
- `provisioning/templates/{hetzner,bare-metal}.bu`: render
  `HostName=${SERVER_NAME}` instead of the destructive literal `%q`.
- `.mise/tasks/materia/sync-image`: new guarded plan/apply migration task.
- `renovate.json5`: include the adopted renderer in the materia image manager.
- `specs/bugs/BUG-015-*`, `BUG-016-*` and the registry: document the migration
  defects found by the live dry run.
- `specs/bugs/BUG-017-*`: log bow's independently broken Newt identity found by
  the post-upgrade failed-unit smoke check.
- `AGENTS.md` and `specs/state.yaml`: record migration constraints, live rollout
  state and the pending unattended timer proof.

## Verification

Repository checks after each logical change:

```sh
mise clean && mise ign --server-name flutterina
git status --short
```

Renderer smoke test:

```sh
mise server:adopt-render --server-name krytis-runner
grep -F 'Image=ghcr.io/stryan/materia:v0.8.0@sha256:7276f4a7f759c1fab2016dd438fd910b982dbc436513dd36fe44936fda6d532d' \
  provisioning/servers/krytis-runner/bootstrap/materia-update.container
```

The bootstrap directory is ignored and contains an age private key; remove it
with `mise clean` after verification and never include it in status output.

Task smoke test against each host:

```sh
mise materia:sync-image --target core@HOST
mise materia:sync-image --target core@HOST --apply
```

Observed evidence required per host:

- dry-run plan exits zero, with no `Unknown`, `Disable`, or unexpected hostname
  resource diffs;
- post-apply journal for the new run contains no `FATA`;
- local image digest and generated service command match the repository pin;
- the live `HostName=` equals the target's OS hostname;
- no new failed units remain after restart-time health probes settle;
- the next scheduled 05:00 run exits green with no `FATA` and no failed-unit
  change.

## Rollout evidence (2026-11-05)

- **bow:** initial plan contained only the expected v0.8 permission updates,
  host reload and four service restarts. The first run completed successfully
  on the pinned digest and rewrote `HostName=bow`; a second v0.8 plan reported
  `No changes made`. Restarting `tailscale-gateway` dropped the SSH transport,
  so the original client missed its post-check even though the remote service
  finished green. The task now detects that apply-stage disconnect and
  reconnects idempotently. The failed-unit smoke exposed BUG-017: Newt's
  persisted ID no longer existed in Pangolin (failing streak 2319). Bow's
  obsolete Newt was subsequently removed; its healthy Tailscale gateway now
  owns `newt-net`, all forward targets passed, and `systemctl --failed` is empty.
  A restart-time gateway health probe also exposed a verification race; the task
  now waits for probes to settle and rejects only newly failed units.
- **flutterina:** first run completed successfully; digest and generated
  service matched the pin; failed-unit set was unchanged. `pangolin-pod`,
  `app`, `gerbil`, `traefik`, `beszel-hub`, `newt` and `tailscale` were active;
  pod state was `Running`; app and gerbil were healthy; the HTTPS listener
  answered. A second v0.8 plan reported `No changes made`.
- **krytis-runner:** first run completed successfully; digest and generated
  service matched the pin; failed-unit set was unchanged. A second v0.8 plan
  reported `No changes made`.

Remaining live proof: inspect the next unattended 05:00 timer run on all three
hosts. This is time-gated; repository and first/second manual-run acceptance is
complete.

## Rollback

Before applying, retain the original live `Image=` value printed by the task.
If v0.8.0 cannot complete its first plan, the task makes no mutation. If the
service fails after the image-line update, restore that exact line, run
`systemctl daemon-reload`, and start `materia-update.service`; do not reuse a
floating tag inferred from repository state.

## Out of scope

- Self-managing the materia-update quadlet through materia.
- Reworking the six deprecated top-level hostname fact calls.
- Reintroducing a declared service entry for `usb-drive`.
