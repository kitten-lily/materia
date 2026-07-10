# Plan: Storage Box provisioning for restic-backup

Source: [issue #4](https://github.com/kitten-lily/materia/issues/4) — "Provision
Hetzner Storage Box for restic-backup via hcloud CLI". The issue body is the
approved design; this file breaks it into subagent-driven-development tasks
and pins down two implementation details the issue leaves open.

## Context

Companion to the `restic-backup` component (issue #2, separate work, out of
scope here). This issue is the **provisioning side only**: create a Hetzner
Storage Box via the `hcloud` CLI (GA `storage-box` subcommand, same tool/auth
as the existing `hz:*` server tasks), lock it down, and print the connection
details an operator hands off to #2 by hand. No component/attributes/secrets
work happens in this repo as part of this plan — #2 owns consuming the
output.

This branch is `feat/storagebox-provisioning`, based on
`feat/multi-server-flutterina` (not `main`) — issue #4 explicitly depends on
the `server.toml` / `--server-name` / `yq`-TOML-read conventions that only
exist on that branch (`b54b587`, unmerged to `main` as of this writing). Every
task below mirrors those conventions exactly; read
`.mise/tasks/hz/create`, `.mise/tasks/hz/delete`, `.mise/tasks/hz/ssh`, and
`.mise/tasks/hz/_server-id` before writing any task file — they are the
canon this plan copies, not just inspiration.

## Two decisions this plan makes (not left to implementers)

**1. Task location and naming.** The issue says "New mise tasks under
`.mise/tasks/hz/storagebox/`" — that nests them under the existing `hz`
namespace, giving mise commands `hz:storagebox:create`, `hz:storagebox:delete`,
`hz:storagebox:access` (mise derives command names from the file tasks
directory tree, same as `hz/create` → `hz:create`). Exactly these three
files, matching the issue's "New mise tasks" list one-for-one. Subaccount
creation, delete-protection, snapshot-plan, and host-key scanning (issue
items 3–5) are **not** separate task files — they're steps inside
`hz:storagebox:create`, because a box with no scoped subaccount yet is
useless, unprotected state; splitting them would let a task fail halfway
into an insecure intermediate box. `access` remains separately callable so
an operator can re-assert SSH-only lockdown later without re-running create.

**2. The SSH-key-to-subaccount gap.** The issue says (step 3): "Generate a
dedicated SSH keypair... public key registered via `hcloud ssh-key` and
attached to the subaccount." Verified against the installed CLI
(`hcloud 1.66.0`):

- `hcloud storage-box subaccount create --help` and `subaccount
  update-access-settings --help` have **no `--ssh-key` flag at all** — only
  `--password` (required), `--home-directory`, `--readonly`, samba/webdav/ssh
  toggles.
- `hcloud storage-box create --help` **does** have `--ssh-key stringArray`
  ("SSH public keys in OpenSSH format or as the ID or name of an existing SSH
  key") — but that's on the box's primary-account create call, not any
  subaccount call.
- There is no `storage-box update --ssh-key` or other post-create way to add
  a key to the box either.

So per-subaccount SSH key attachment, as the issue describes it, does not
exist in this CLI version. Storage Box SSH keys are registered at the **box**
level only; subaccount usernames are a home-directory/permission scope on
top of that shared key set, not an independent auth boundary. Resolution:
`hz:storagebox:create` generates the dedicated keypair and passes its public
half to `hcloud storage-box create --ssh-key`, registering it box-wide, then
creates the subaccount scoped to a backup-only home directory. Document this
explicitly in AGENTS.md's Gotchas so nobody goes looking for a subaccount
`--ssh-key` flag that isn't coming. This is a documented deviation from the
issue's literal wording, forced by tool capability — not a scope change to
flag to the human separately, since the issue's own framing already
anticipates the CLI being new/evolving.

## Global Constraints (bind every task)

- **Mirror existing `hz/*` task style exactly**: `#!/usr/bin/env bash`,
  `#MISE description="..."`, `#USAGE flag "--x <val>" help="..."` blocks,
  `set -euo pipefail`, `${usage_x:?x required, use --x}` for required flags,
  `${usage_x:-default}` for optional ones, `gum style --foreground N` for
  output (1=red/error, 2=green/success, 3=yellow/warn, 8=gray/info),
  `gum spin --spinner dot --title "..." -- <cmd>` around slow calls, every
  `hcloud` invocation prefixed `fnox exec --` (resolves `HCLOUD_TOKEN`).
  Files executable (`chmod +x`), no shebang deviations.
- **Config file**: `provisioning/storageboxes/<name>/storagebox.toml`,
  committed, non-secret — read the same way `server.toml` is:
  `yq -o=json -p=toml "$_toml" | jq -r '...'`. Missing-file and
  wrong-shape errors follow `hz:create`'s pattern exactly (red `gum style`
  message naming the missing file, non-zero exit, no bash stack traces).
- **Never write private key material into the git working tree** — not even
  a gitignored path. The dedicated restic SSH keypair is generated with
  `ssh-keygen` inside a `mktemp -d` directory guarded by
  `trap 'rm -rf "$_tmpdir"' EXIT` (same idiom `hz:create` already uses for
  its response tempfile), and the private key is printed to the terminal
  for the operator to move into SOPS by hand. This is stricter than the
  existing `*.ign` handling (which is gitignored but does touch the tree) —
  do not relax it.
- **No live provisioning as part of this work.** These tasks call a real,
  billed Hetzner API. Do not run `hz:storagebox:create` (or `delete`)
  against the real account to "test" it — verification is `mise tasks`
  discovery, `--help` output, required-flag enforcement (clean error, no
  crash, matching `hz:create`/`server:new`'s existing test bar from issue
  #1's Phase A), TOML parsing of a scratch `storagebox.toml` fixture, and
  `bash -n`/shellcheck syntax checks. If a task needs to exercise an actual
  `hcloud` call to verify plumbing, use a read-only, free command (e.g.
  `hcloud storage-box-type list`, `hcloud ssh-key list`) — never `create`
  or `delete`.
- **Least privilege**: the subaccount's `--home-directory` scopes it to a
  backup-only subdirectory (not box root); box primary account stays
  unused by restic.
- **Defense in depth**: `hz:storagebox:create` always calls
  `enable-protection <box> delete` after creation (not optional — the issue
  states this as a should, and it's free/reversible). `enable-snapshot-plan`
  is an **opt-in flag** (`--enable-snapshot-plan`, default off) — the issue
  only says "consider" it, and it's a standing cost/complexity tradeoff the
  operator should choose per-box, not a default.
- **Access lockdown**: SSH only. `create` passes `--enable-ssh
  --enable-samba=false --enable-webdav=false` on the box create call (no
  `--enable-ftp` flag exists in this CLI — FTP is not a toggle Hetzner
  exposes here, don't invent one); `access` (the standalone task) reasserts
  the same via `update-access-settings` for re-locking after any manual
  changes.
- **Host key capture**: after the box exists, `create` runs `ssh-keyscan`
  against the box's SSH hostname and prints the result plus a one-line note
  that issue #2 turns it into the `restic-backup` component's `known_hosts`
  resource. Do not write any file for this — printing is the full scope
  here.
- **Handoff output, not handoff action**: `create`'s final output block
  (mirror `server:new`'s "Next steps" gum block) prints: subaccount
  username, box SSH hostname, backup home directory, the scanned host key,
  and the private key material — with a comment pointing at `sops edit
  attributes/<name>.yml` for wiring it into #2. Do not write to
  `attributes/` or `MANIFEST.toml` from these tasks — that's #2's job.
- **Docs**: AGENTS.md's "Hetzner tasks" table and Gotchas section are part
  of the deliverable (issue explicitly calls out the table addition since
  it didn't exist when the issue was first drafted). Repo layout section
  should gain `provisioning/storageboxes/` alongside `provisioning/servers/`.
- **Commit style**: focused semantic commits per AGENTS.md conventions
  (`feat:`, `docs:`, Conventional Commits, ≤50-char subject).

## Task 1: `storagebox.toml` convention + `hz:storagebox:create`

Create the config file format and the main provisioning task.

**`provisioning/storageboxes/<name>/storagebox.toml`** — analogous to
`provisioning/servers/<name>/server.toml`. Fields:

```toml
# Storage box config for "<name>", read by `mise hz:storagebox:*`.
# Committed — non-secret.

[hetzner]
type = "bx11"
location = "fsn1"

[subaccount]
home_directory = "/restic"
```

(`type = "hetzner"` at the top level like `server.toml` is unnecessary here —
storage boxes have no bare-metal equivalent — so this file has no top-level
`type` key, just `[hetzner]` and `[subaccount]`.) Do not commit a concrete
instance of this file for a real box name — no live box exists yet and
provisioning one is explicitly out of scope (see Global Constraints). The
task's missing-file error message should tell the operator to hand-author
`provisioning/storageboxes/<name>/storagebox.toml` (there is no scaffold
task for this, unlike `server:new` — the issue doesn't ask for one and one
box is all that's needed right now; don't add one).

**`.mise/tasks/hz/storagebox/create`** flags:
- `--box-name <name>` (required)
- `--box-type <type>` (optional override of `storagebox.toml`'s
  `hetzner.type`)
- `--location <location>` (optional override of `hetzner.location`)
- `--home-directory <path>` (optional override of `subaccount.home_directory`)
- `--enable-snapshot-plan` (opt-in, default off — see Global Constraints)
- `-v/--verbose` (mirror `hz:create`'s verbose flag)

Sequence (mirror `hz:create`'s structure: resolve config → validate →
tempdir+trap → API calls → validate response → print result):
1. Resolve `storagebox.toml`, error if missing (per Global Constraints).
2. Generate the dedicated ed25519 keypair in a `mktemp -d`
   (`ssh-keygen -t ed25519 -N "" -C "restic-backup@<box-name>" -f
   "$_tmpdir/key"`).
3. `hcloud storage-box create` with `--name`, `--type`, `--location`,
   `--password` (random, e.g. `openssl rand -base64 32` — not meant for
   human use since SSH key auth is the real access path, but the API
   requires one), `--ssh-key "$(cat "$_tmpdir/key.pub")"`, `--enable-ssh`,
   `--enable-samba=false`, `--enable-webdav=false`. Handle API error
   responses the same way `hz:create` does (check for `.error` in JSON,
   print and exit non-zero).
4. `hcloud storage-box enable-protection <id> delete`.
5. If `--enable-snapshot-plan`: `hcloud storage-box enable-snapshot-plan
   <id>` with reasonable defaults (once daily, low `--max-snapshots`) —
   pick specific values and document them in a comment; this is a default
   for the flag, not a new flag surface.
6. `hcloud storage-box subaccount create <id> --home-directory <path>
   --password <random> --enable-ssh --description "restic-backup"`.
7. `ssh-keyscan` the box's SSH hostname (from the `describe` response),
   capture the result.
8. Print the "Next steps" block per Global Constraints (username, hostname,
   home directory, host key, private key content, `sops edit
   attributes/<name>.yml` pointer). Clean up the tempdir via the `trap`
   (private key must not survive the process).

Write a report to `.superpowers/sdd/task-1-report.md` (path handed to you in
the dispatch) covering: files created, the two design decisions applied
(task naming/nesting, SSH-key box-level registration), and test output
(`mise tasks` listing, `--help`, missing-flag/missing-toml error output,
`bash -n` result). No live `hcloud storage-box create` run — see Global
Constraints.

## Task 2: `hz:storagebox:delete`

Mirror `.mise/tasks/hz/delete` almost exactly: `--box-name <name>`,
`--confirm` (required to actually delete), `--noninteractive` (exit 1
instead of 0 when `--confirm` missing, for scripting). Resolve the box id via
`hcloud storage-box describe <name> --output json` (no `_server-id`-style
helper needed — `describe` takes the name directly, unlike servers which
need the two-value id+ip helper). If the box doesn't exist, print the
"nothing to delete" info message and exit 0 (same as `hz:delete`). Does not
need to touch the subaccount or keypair — deleting the box removes
everything under it.

Test the same way as `hz:delete` was presumably tested for #1: `--help`,
missing `--box-name` error, missing `--confirm` warning path,
`--noninteractive` exit code. No live delete call.

## Task 3: `hz:storagebox:access`

Mirror the issue's description directly: `hcloud storage-box
update-access-settings` to (re-)assert SSH-only. Flags: `--box-name <name>`
(required). No other flags — this task has one job, locking to SSH-only; it
is not a general access-settings editor. Body: resolve box id via
`describe`, call `update-access-settings <id> --enable-ssh --enable-samba=false
--enable-webdav=false`, print a green success line. This task is intentionally
much shorter than `create` — resist adding flags or options beyond what's
needed to re-run the lockdown.

## Task 4: AGENTS.md documentation

- Repo layout: add `provisioning/storageboxes/<name>/storagebox.toml` under
  `provisioning/` next to `servers/`.
- "Hetzner tasks" table: add rows for `hz:storagebox:create`,
  `hz:storagebox:delete`, `hz:storagebox:access` with one-line descriptions
  (pull the `#MISE description` strings verbatim from Task 1–3's files —
  don't diverge from what the tasks actually say).
- Gotchas: add an entry documenting the SSH-key-to-subaccount CLI gap (this
  plan's decision 2, condensed) — the next person reading this repo should
  not waste time hunting for a subaccount `--ssh-key` flag.
- Cross-reference issue #2 for the consuming side (attributes/secrets/
  `known_hosts`), matching how other sections already point at related
  issues/repos.

This task has no code to test — verify by reading the rendered Markdown for
internal consistency (table formatting matches existing rows, no dangling
references) and confirm the three `#MISE description` strings quoted match
Task 1–3's actual files byte-for-byte.
