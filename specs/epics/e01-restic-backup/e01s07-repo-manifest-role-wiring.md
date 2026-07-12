# Story e01s07 — Repo MANIFEST.toml: [Roles.base] + flutterina roles assignment

**type:** feat
**risk:** P2
**context:** infra
**epic:** e01-restic-backup
**source:** https://github.com/kitten-lily/materia/issues/2
**blocks_on:** e01s06 (secrets + manifest must exist before the component is
assignable to a host)

## Context

Wires `restic-backup` into the repo-level `MANIFEST.toml` as a **role**
component rather than a direct per-host `Components` entry — the backup
scope (`/var/lib/materia/components`, `/var/lib/containers/storage/volumes`)
is host-generic, so every server in the fleet should get it automatically,
not just flutterina. Matches the documented pattern (materia manifest
reference, `[Roles.base] Components = [...]` + `Hosts.<name>.Roles =
[...]`).

## Requirements

#### ADDED: `[Roles.base]` role owning `restic-backup`

```toml
[Roles.base]
Components = ["restic-backup"]
```

#### ADDED: `flutterina` gets `Roles = ["base"]`

`[Hosts.flutterina]` keeps its existing `Components = ["pangolin"]` and adds
`Roles = ["base"]` — flutterina now gets `pangolin` directly plus
`restic-backup` via the role.

## Steps

1. Add `Roles = ["base"]` to `[Hosts.flutterina]` and a new `[Roles.base]`
   table with `Components = ["restic-backup"]`. → verify: `python3 -c
   "import tomllib; d=tomllib.load(open('MANIFEST.toml','rb'));
   assert d['Hosts']['flutterina']['Roles']==['base'];
   assert d['Roles']['base']['Components']==['restic-backup']"`.

## Out of scope

- The `known_hosts` data resource — e01s08.
- Renovate digest coverage — e01s09.
- Local verification / actually running `materia update` — e01s11.

## Risks

- **Ordering risk: this assigns `restic-backup` to flutterina before
  `known_hosts` (e01s08) exists.** The `.container.gotmpl`'s
  `Volume={{ m_dataDir "restic-backup" }}/known_hosts:...` bind-mount source
  won't exist on the host data dir until e01s08 ships, and the component's
  `restic-backup.timer` (`WantedBy=timers.target`) WILL be enabled/started by
  materia on the next `materia update` even though the `.service` itself has
  `Stopped = true` (that flag only stops *materia* from starting the
  service directly — it doesn't stop systemd from starting it when the timer
  fires). If the timer fires before e01s08 lands, the container fails to
  start (missing bind-mount source) — a **non-fatal, self-healing failure**:
  the daily timer retries automatically (Always Green / Discovered Defects §
  retry semantics — same discipline as `materia-update.timer`), and the
  `HC_PING_URL`/fail ping (once `hcPingURL` propagates — this run doesn't
  reach the wrapper's ping code, since the container never starts; only
  systemd's own unit-failed state is visible via `systemctl status`) means
  the failure is at worst silent until e01s08 ships. **Land e01s08 before
  this branch reaches a real `materia update` run** (i.e., before pushing to
  `origin`/triggering the timer on flutterina) to avoid the failed-start
  window entirely.
