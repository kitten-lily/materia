# Implementation Plan — Issue #144: Adopt krytis-runner for beszel-agent

**issue:** https://github.com/kitten-lily/materia/issues/144
**paired with:** starlit-os/krytis#1154 (decision M5 of starlit-os/krytis#1145)
**risk:** P3 (additive host entry; no change to any existing host or component)
**epic:** standalone

## Summary

krytis's self-hosted CI runner moved from Contabo (`krytis-build`, #99) to a
one.com Cloud server L on 2026-10-09. L had neither materia nor beszel-agent.
This repeats #99's adoption for the new box under the server name
`krytis-runner`, with `beszel-agent` as its only component.

Everything follows `specs/plans/issue-99-krytis-build-beszel.md`; nothing in
the adopted-host path changed. Only the names and the secrets differ.

## Changes

- `provisioning/servers/krytis-runner/server.toml` — `type = "adopted"`, from
  `mise server:new --server-name krytis-runner --type adopted --components beszel-agent`.
- `MANIFEST.toml` — `[Hosts.krytis-runner] Components = ["beszel-agent"]`, next to
  `krytis-build`, which stays until Contabo is decommissioned.
- `attributes/krytis-runner.yml` — `components.beszel-agent.beszelKey` (the hub's
  public key, same value as every other host) and `beszelToken`, a new token for
  a new `krytis-runner` system in the hub. Attributes and `Components` land in
  the same commit, so the "map has no entry for key" abort cannot happen.

The hub system was created through the hub's PocketBase API exactly as the UI's
Add System dialog does it: a `systems` record, then a `fingerprints` record
holding a random UUID token (beszel `internal/site/src/components/add-system.tsx`,
v0.21.0). The token is also in the krytis vault's "Krytis Build VPS" item.

## Deployment (on L, over SSH)

1. `hostnamectl set-hostname krytis-runner`, plus the cloud-init
   `preserve_hostname: true` drop-in if cloud-init is installed.
2. `systemctl enable --now podman.socket`; `mkdir -p /var/lib/materia`.
3. Install the four files from `mise server:adopt-render --server-name krytis-runner`.
4. After this PR merges: `systemctl start materia-update.service`.

## Verify

- verify: `ssh <L> 'systemctl is-active materia-update.timer beszel-agent.service'` → `active` twice
- verify: `ssh <L> 'systemctl show -p Result materia-update.service'` → `Result=success`
- verify: hub API `systems` record `krytis-runner` has `status = "up"`
- verify: healthchecks slug `materia-update-krytis-runner` received a success ping

## Out of scope

- Removing `krytis-build` (host entry, attributes, server.toml, hub system):
  after Contabo's rollback window, tracked in starlit-os/krytis#1145 step 7.
