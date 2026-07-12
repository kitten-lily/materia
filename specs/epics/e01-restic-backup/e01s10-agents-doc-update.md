# Story e01s10 — AGENTS.md: document restic-backup component + gotchas

**type:** docs
**risk:** P3
**context:** infra
**epic:** e01-restic-backup
**source:** https://github.com/kitten-lily/materia/issues/2
**blocks_on:** e01s07 (repo wiring), e01s09 (Renovate coverage) — both done

## Context

Rolls up every non-obvious constraint discovered across e01s05–e01s11 into
`AGENTS.md` (symlinked from `CLAUDE.md` — one file, both names) per
CONVENTIONS.md's "AI sessions: always update this file" rule.

## Requirements

#### ADDED: `restic-backup` in the Repo layout tree

`components/restic-backup/` (manifest, container/timer templates,
`ssh_config`, `known_hosts`) and `images/restic-backup/` (Dockerfile +
wrapper source), plus `provisioning/storageboxes/<box>/` — none of these
existed in the tree diagram before this epic.

#### ADDED: Two design-decision bullets in "Architecture decisions (locked)"

Role-based host assignment (`[Roles.base]`, host-generic components opt in
via `Roles = [...]` rather than per-host `Components`) and the
oneshot+timer pattern (`Stopped = true` + `Oneshot = true` +
`Static = true` on the timer, no `[Install]` on the `.container.gotmpl`).

#### ADDED: Six new Gotchas

1. `RESTIC_SFTP_ARGS` isn't real — `ssh_config` mount instead (e01s05
   discovery).
2. Scratch needs `Tmpfs=/tmp` for restic (e01s11 discovery).
3. `Stopped = true` semantics — general "never auto-start", not
   build/image-only (e01s06 discovery, corrects e01s05's original note).
4. CI can publish multiple images per push — verify digest against the
   actual run log, not inferred ordering (e01s11's root-cause finding).
5. A CI gate only proves what it invokes — `restic-backup-image.yml` never
   tests the wrapper binary itself (e01s11's flagged-not-fixed risk).
6. Duplicated source-of-truth pairing (`hcPingURL`, `known_hosts`) — no
   tooling enforces sync, flag it explicitly (e01s06 + e01s08 risks).

#### ADDED: Two restic doc reference links

`restic.readthedocs.io` scripting/env-vars and sftp-backend pages — cited
repeatedly during e01s05/e01s11 investigation, worth having on hand.

## Steps

1. Add `components/restic-backup/`, `images/restic-backup/`, and
   `provisioning/storageboxes/<box>/` to the Repo layout tree. → verify:
   `grep -q 'restic-backup/                 # restic-backup component'
   AGENTS.md`.
2. Add the two Architecture decisions bullets. → verify: `grep -q
   'Host-generic components are assigned via' AGENTS.md`.
3. Add the six Gotchas bullets. → verify: six individual `grep -q` checks,
   one per gotcha (see commit for exact strings).
4. Add the two restic doc reference links. → verify: `grep -q
   'restic.readthedocs.io' AGENTS.md`.
5. Confirm `CLAUDE.md` (symlink to `AGENTS.md`) resolves identically —
   no separate edit needed. → verify: `diff <(cat CLAUDE.md) <(cat
   AGENTS.md)` — empty.

## Out of scope

- Fixing the CI gate blind spot itself (flagged in e01s11 and again here,
  not fixed in either story).
- Any code change — this story is documentation-only.

## Risks

None — documentation-only change, verified against the current state of
every resource it describes (all six gotchas were derived from this
epic's actual, confirmed findings, not speculation).
