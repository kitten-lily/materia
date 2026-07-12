# Story e01s08 — Ship known_hosts as a data resource

**type:** feat
**risk:** P2
**context:** infra
**epic:** e01-restic-backup
**source:** https://github.com/kitten-lily/materia/issues/2
**blocks_on:** e01s05 (the `.container.gotmpl` mount path already exists,
forward-referencing this resource)

## Context

e01s05 wired `Volume={{ m_dataDir "restic-backup" }}/known_hosts:/run/secrets/known_hosts:ro,Z`
and e01s06's `MANIFEST.toml` already lists `known_hosts` in
`restic-backup.service`'s `RestartedBy` — both forward-referencing this
resource before it existed. This story ships the file itself, closing the
ordering-risk gap flagged in e01s07.

## Requirements

#### ADDED: `components/restic-backup/known_hosts` (plain data resource)

A copy of `provisioning/storageboxes/backup/known_hosts` (committed,
non-secret — SSH host public keys). Not templated (`.gotmpl`) — static
content, installs verbatim to `{{ m_dataDir "restic-backup" }}/known_hosts`.

Covers both `u630269.your-storagebox.de` and `u630269-sub1.your-storagebox.de`
(bare account + the per-server subaccount from e01s01's
`hz:storagebox:subaccount`), each on port 22 (`mod_sftp`) and port 23
(`OpenSSH`) — the subaccount's `install-ssh-key` used port 23, and this
covers both without needing to parse `resticRepository` to determine which
port it encodes.

## Steps

1. Copy `provisioning/storageboxes/backup/known_hosts` to
   `components/restic-backup/known_hosts` verbatim. → verify: `diff -q
   provisioning/storageboxes/backup/known_hosts
   components/restic-backup/known_hosts`.

## Out of scope

- Renovate digest coverage — e01s09.
- AGENTS.md documentation — e01s10.
- Actually running `materia update` to confirm the mount resolves — e01s11.

## Risks

- **Duplication/drift.** `known_hosts` now lives in two places:
  `provisioning/storageboxes/backup/known_hosts` (source of truth, refreshed
  by `mise hz:storagebox:keyscan`) and `components/restic-backup/known_hosts`
  (this copy, what materia actually installs). If the Storage Box's host
  keys ever rotate, both need updating — not enforced by tooling. Same class
  of gotcha as e01s06's `hcPingURL` duplication (Proton Pass vs. vault).
