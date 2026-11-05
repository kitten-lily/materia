# BUG-016: provisioned materia quadlets use literal `HostName=%q`

**Status:** fixed
**Severity:** P0
**Found:** 2026-11-05
**Epic:** issue-173-materia-upgrade

## Symptom

After BUG-015 isolated the incompatible v0.7 last-run file, bow's first v0.8
plan proposed stopping every service and removing every installed component.
The plan ended with disabling `restic-backup.timer`; the guarded sync task
rejected it without changing the host.

Read-only inspection of bow's live quadlet showed:

```ini
HostName=%q
```

Both Butane templates contain the same literal. The `mise ign` renderer only
substitutes `${SERVER_NAME}` and other `${...}` placeholders; it has no `%q`
formatting pass. `%q` therefore reaches Ignition, the host quadlet and the
container unchanged.

## Root cause

The templates used a shell `printf` formatting token in a plain YAML string.
Butane does not interpret `printf` tokens. v0.7 happened to identify the host
through its old facts implementation despite the bad container hostname. v0.8
reworked facts; with the container hostname `%q`, it finds no matching
`[Hosts.<name>]` entry and treats all installed components as unassigned drift.
The resulting plan is a destructive full-host removal, not a harmless no-op.

The #173 issue investigation explicitly called the unchanged hostname an
inference. The live v0.8 plan disproved it.

## Impact

Applying the image pin without correcting `HostName=` would make v0.8 stop and
remove every materia-managed service and resource on bow or flutterina. On the
edge host that includes Pangolin and would be a total public ingress outage.
Future hosts provisioned from either template would receive the same invalid
hostname.

## Fix

- Replace `HostName=%q` with `HostName=${SERVER_NAME}` in both Butane templates;
  `mise ign` already performs that substitution.
- `mise materia:sync-image` reads the target's real OS hostname, uses it for the
  guarded v0.8 plan, and rewrites the live quadlet's `HostName=` together with
  the image pin on `--apply`.
- The task prints both values and requires one live `HostName=` line, making
  future placeholder or duplication drift visible before any update starts.

## Regression verification

1. Render Ignition for both a Hetzner and bare-metal server and confirm no `%q`
   remains while each rendered quadlet contains that server's name.
2. Run the v0.8 dry-run plan on bow with its actual OS hostname. It must contain
   the expected initial permission-update wave, not component removals,
   `Unknown`, or service `Disable` actions.
3. Apply on one host at a time. Confirm the live `HostName=` equals `hostname`,
   the run has no `FATA`, and the managed services remain installed and active.
