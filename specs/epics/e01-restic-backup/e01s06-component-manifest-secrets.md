# Story e01s06 — Component MANIFEST.toml: Secrets, Services, Defaults

**type:** feat
**risk:** P1
**context:** infra
**epic:** e01-restic-backup
**source:** https://github.com/kitten-lily/materia/issues/2
**blocks_on:** e01s05 (quadlet resources must exist to name in `RestartedBy`)

## Context

Wires `components/restic-backup/MANIFEST.toml` per the confirmed semantics in
the [materia manifest reference](https://primamateria.systems/documentation/latest/reference/materia-manifest.5.html):

- `Stopped = true` — "Prevents materia from starting the service." This is
  the correct field for a timer-activated oneshot job (materia must never
  start `restic-backup.service` directly; only the timer does). Supersedes
  e01s05's note that `Stopped` was build/image-only — it isn't, it's the
  general "don't auto-start" flag and applies here.
- `Oneshot = true` — "Prevents materia from checking if this service started
  successfully. Useful for containers that don't stay running."
- `Static = true` on the `restic-backup.timer` entry — quadlet-generated
  service.
- `Secrets = [...]` must be the first line, before any table header (TOML
  gotcha, ce520f1) — verified by parsing with `python3 -c
  "import tomllib; tomllib.load(...)"`.

## Requirements

#### ADDED: `components/restic-backup/MANIFEST.toml`

`Secrets = ["resticPassword", "storageBoxSshKey"]`. `[Defaults]` carries
`resticKeepDaily`/`resticKeepWeekly`/`resticKeepMonthly`/`resticOnCalendar`
matching the `m_default` fallbacks already inline in e01s05's `.gotmpl`
files (belt-and-suspenders: Defaults is the discoverable/overridable source,
the inline `m_default` fallback is a safety net if Defaults is ever
removed). Two `[[Services]]` entries: `restic-backup.service`
(`Stopped = true`, `Oneshot = true`, `RestartedBy` listing the container,
`ssh_config`, and `known_hosts` — the last forward-references e01s08's
not-yet-shipped resource, same forward-reference pattern e01s05 used for
the mount path) and `restic-backup.timer` (`Static = true`).

#### DEFERRED: attribute values for `resticPassword` and `hcPingURL`

`Secrets = ["resticPassword", ...]` has nothing to source without a
`resticPassword` value in a vault, and the `.container.gotmpl`'s
`{{ .hcPingURL }}` (no `m_default` fallback — it's meant to hard-fail if
unset) needs a `globals.hcPingURL` entry in `attributes/vault.yml`. Both
require the age private key / Proton Pass access this environment does not
have — **the user must run these manually**:

```sh
# resticPassword — a NEW repo-encryption password (not the same as any
# existing secret; losing it makes existing snapshots unrecoverable, so
# generate and store it somewhere durable, e.g. Proton Pass, in addition
# to the vault):
sops edit attributes/flutterina.yml
# add under components.restic-backup:
#   resticPassword: <generated secret>

# hcPingURL — reuse the SAME value already stored in Proton Pass under
# materia/healthchecks/ping-url (the one fnox injects as HC_PING_URL for
# the Butane template):
sops edit attributes/vault.yml
# add under globals:
#   hcPingURL: <same value as the healthchecks/ping-url Proton Pass field>
```

Until both are set, `materia plan`/`materia update` will fail to resolve
`resticPassword` (secret creation) and `{{ .hcPingURL }}` (template render)
on the `restic-backup` component. This component isn't assigned to any host
yet (e01s07), so it doesn't block flutterina's current `materia update`
runs — but it does block e01s11 (local verification).

## Steps

1. Create `components/restic-backup/MANIFEST.toml` with `Secrets` as the
   first line. → verify: `python3 -c "import tomllib; d=tomllib.load(open('components/restic-backup/MANIFEST.toml','rb')); assert d['Secrets'] == ['resticPassword','storageBoxSshKey']"`.
2. Add `[Defaults]` with the four restic tuning attributes. → verify:
   `grep -q 'resticKeepDaily' components/restic-backup/MANIFEST.toml`.
3. Add the `restic-backup.service` `[[Services]]` entry with
   `Stopped = true` + `Oneshot = true`. → verify: `grep -A4 'Service = "restic-backup.service"' components/restic-backup/MANIFEST.toml | grep -q 'Stopped = true' && grep -A4 'Service = "restic-backup.service"' components/restic-backup/MANIFEST.toml | grep -q 'Oneshot = true'`.
4. Add the `restic-backup.timer` `[[Services]]` entry with `Static = true`.
   → verify: `grep -A2 'Service = "restic-backup.timer"' components/restic-backup/MANIFEST.toml | grep -q 'Static = true'`.
5. Hand off the two `sops edit` commands above to the user (cannot be run
   in this environment — no age key / Proton Pass access).

## Out of scope

- Repo-level `[Hosts.flutterina]` component assignment — e01s07.
- The `known_hosts` data resource itself — e01s08.
- Renovate digest coverage — e01s09.

## Risks

- **`resticPassword` is generate-once, lose-once.** Unlike `storageBoxSshKey`
  (recoverable by reinstalling the key), losing `resticPassword` after the
  repository is initialized makes every snapshot permanently unreadable.
  Store it in Proton Pass alongside the vault entry, not just in SOPS.
- **`hcPingURL` duplication.** The same base URL now lives in two places
  (Proton Pass `healthchecks/ping-url`, used directly by the `.bu` at
  transpile time, and `attributes/vault.yml globals.hcPingURL`, used by
  materia at runtime). If the Proton Pass value ever rotates, both need
  updating — not enforced by tooling, a manual gotcha for future sessions.
