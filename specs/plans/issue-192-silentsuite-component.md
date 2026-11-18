# SilentSuite on bow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run SilentSuite (E2E-encrypted calendar/contacts/tasks sync) on
bow at `silentsuite.<baseDomain>`, backed up by `db-dump`, with upgrades
gated on published releases.

**Architecture:** Component `silentsuite` with two standalone containers on
`newt-net`: the server and Postgres 16. Clients reach the server through the
existing Pangolin edge: Pangolin → flutterina site → bow tailnet IP:3735 →
`tailscale-gateway` TCP forward → `silentsuite:3735`. Secrets come from
`attributes/bow.yml`, written by a mise task. The nightly dump is one more
`db-dump` unit.

**Tech Stack:** materia quadlets, SOPS/age vault, bash mise tasks, GitHub
Actions, Renovate.

**Spec:** `specs/plans/silentsuite-investigation.md` (decisions, local test
results, client support) and issue #192. Hostname confirmed
`silentsuite.<baseDomain>` (2026-11-18).

## Global Constraints

- Server image `ghcr.io/silent-suite/silentsuite-server:v0.5.20-beta@sha256:6a5ab47d21feeed4fc05379258e8c2686e1fa67138dbd6570900eea732b0c7bb`
  (published release, digest = `server-image.json` `indexDigest`, checked
  2026-11-18).
- Postgres `docker.io/library/postgres:16.16-alpine@sha256:81e77a4833487b8132fe4b00bedd39dc3f74b8641e387f19312a48f7de218c2e`.
  PG 16 uses the default PGDATA `/var/lib/postgresql/data` (no override).
- Server env: `ETEBASE_EASY_CONFIG_PATH=/run/secrets/db.ini`,
  `TRUSTED_PROXY_IPS=10.89.0.0/16`, `ETEBASE_DISABLE_DJANGO_ADMIN=true`.
  `ETEBASE_BOOTSTRAP_ADMIN_TOKEN` comes from a secret, and
  `ETEBASE_REGISTRATION_TOKEN` from a secret behind
  `{{ if exists "silentsuiteRegistrationToken" }}`.
- ini: `[global]` with `secret_file=/data/secret.txt`, `debug=false`, and
  `media_root`/`static_root` under `/data`. `[allowed_hosts]` is
  `silentsuite.{{ .baseDomain }}` and `localhost`. `[database]` has no
  password; host is `silentsuite-postgres`, name/user `silentsuite`.
- Health: `GET /api/v1/authentication/is_etebase/` must return exactly 200,
  plus `Notify=healthy`.
- Vault keys (`components.silentsuite.*` in `attributes/bow.yml`):
  `silentsuiteDbPassword` (bare), `silentsuiteDbIni`
  (`[database]\npassword = <same>\n`), `silentsuiteBootstrapToken`, and
  later `silentsuiteRegistrationToken`. Values are generated and written
  with `sops --set`, never pasted by hand (BUG-003).
- No real domain in tracked files: `{{ .baseDomain }}` only.
- Quadlet comments on their own lines. Conventional Commits, each commit
  signed (the user touches the key).

## Review Focus

1. **Server starts before the registration token exists**: the
   `{{ if exists }}` guard must render no `Secret=` line, or the container
   fails (missing podman secret) and so does materia on bow. Covered by
   Task 2 Step 3 (render without the key).
2. **A wrong Host header or proxy peer**: 400, or a redirect loop, must
   not pass the healthcheck. Covered by Task 2 Step 4.
3. **Re-running `init-secrets` against existing keys** must refuse to
   overwrite: a new DB password locks the server out of an initialised
   cluster. Covered by Task 1 Step 3.
4. **A Renovate PR to an image tag with no published release**
   (`v0.5.21-beta` existed on GHCR before its release) must fail CI.
   Covered by Task 4 Step 2.
5. **Signups left open**: after `--close` and an immediate materia run,
   a second signup must be rejected. Covered by Task 5 Step 6.

---

### Task 1: `mise silentsuite:init-secrets`

**Files:** Create `.mise/tasks/silentsuite/init-secrets`.

**Interfaces:** `mise silentsuite:init-secrets [--vault <path>] [--close]`.
The default vault is `attributes/bow.yml`. The age key comes from
`SOPS_AGE_KEY` (`fnox get`, as the other tasks do). Without `--close`: write
`silentsuiteDbPassword`, `silentsuiteDbIni` and `silentsuiteBootstrapToken`,
and print the bootstrap token once (the user needs it for the first
signup). With `--close`: write `silentsuiteRegistrationToken` only. Either
mode refuses (exit 1) if a key it would write already exists.

- [ ] **Step 1: Test harness first** (scratch). Create a throwaway age key
  and a throwaway SOPS file with one existing key, and run the task with
  `--vault <tmp>` and `SOPS_AGE_KEY=<tmp key>`. Assertions:
  - the three keys decrypt;
  - `silentsuiteDbIni` equals `[database]\npassword = <silentsuiteDbPassword>\n`;
  - the token is ≥ 32 characters, alphanumeric only;
  - a second plain run exits 1 and changes nothing (sha256 of the file is
    unchanged);
  - `--close` adds only the registration token, and a second `--close`
    exits 1.
- [ ] **Step 2: Run it → FAIL** (the task doesn't exist).
- [ ] **Step 3: Implement.** Generate values with
  `head -c 32 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 40`, and
  JSON-encode the ini with `jq -Rs .`. Before writing, check for existing
  keys with `sops decrypt --extract`.
- [ ] **Step 4: Harness → PASS.** Commit
  `feat(silentsuite): add init-secrets task`.

### Task 2: The `silentsuite` component

**Files:** Create `components/silentsuite/` containing `MANIFEST.toml`,
`silentsuite.container.gotmpl`, `silentsuite-postgres.container.gotmpl`,
`etebase-server.ini.gotmpl`, `silentsuite-data.volume` and
`silentsuite-db.volume`.

**Interfaces:**
- `Secrets = ["silentsuiteDbPassword", "silentsuiteDbIni", "silentsuiteBootstrapToken", "silentsuiteRegistrationToken"]`.
  A declared secret with no attribute is skipped by materia
  (`SecretInjectorStage`).
- The `silentsuite.service` entry has `RestartedBy =
  ["silentsuite.container", "etebase-server.ini"]`.
- The `silentsuite-postgres.service` entry has `RestartedBy =
  ["silentsuite-postgres.container"]`.
- Containers: `silentsuite` (port 3735) and `silentsuite-postgres`.

- [ ] **Step 1: Harness first** (scratch). Render the templates with `sed`
  (`baseDomain=example.test`, `m_dataDir`, `secretEnv` → `Secret=` lines),
  once *without* and once *with* the registration token. Install the result
  as rootless user units on a local `newt-net`, with podman secrets under
  the materia names and Caddy (`tls internal`) proxying
  `silentsuite.example.test` to `silentsuite:3735`. Assertions:
  - quadlet generates both services and both volumes;
  - without the token, no `materia-silentsuiteRegistrationToken` line
    appears (Review Focus 1), and the server becomes healthy;
  - through Caddy, `is_etebase` returns 200 and `/` returns 200 (no loop);
  - a signup without a token gets 403 `bootstrap_token_required`, and one
    with the token gets 200;
  - after re-rendering *with* the token and restarting, a second signup
    without the header gets 403 `registration_token_required`;
  - `secret.txt` and the accounts survive the restart.
- [ ] **Step 2: Run it → FAIL** (no component).
- [ ] **Step 3: Implement** to the Global Constraints. The server unit has
  `Requires=`/`After=silentsuite-postgres.service`, and Postgres
  `Notify=healthy` with `pg_isready`, `ShmSize=128m`, and
  `Exec=postgres -c max_connections=200`. The DB-password secret mount is
  hand-written (`Secret=materia-silentsuiteDbIni,type=mount,target=/run/secrets/db.ini`),
  because `secretMount` can't set the mode and the default 0444 is what
  the non-root `etebase` user needs.
- [ ] **Step 4: Healthcheck strictness (Review Focus 2).** From inside the
  server container, `is_etebase` with `Host: evil.test` must not count as
  healthy. Verify that `HealthCmd` uses `localhost` and requires exactly
  200, and that a probe forced onto a 301 path would fail.
- [ ] **Step 5: Harness → PASS.** Commit
  `feat(silentsuite): add component`.

### Task 3: Backups — `db-dump` and the restore test

**Files:**
- Create `components/db-dump/db-dump-silentsuite.container.gotmpl`, copied
  from the mediamanager one with silentsuite values and the 16.16 image.
- Modify `components/db-dump/db-dump-trigger.service.gotmpl` (add the unit)
  and `components/db-dump/MANIFEST.toml` (`Stopped`+`Oneshot` entry).
- Modify `.mise/tasks/db/backup` and `.mise/tasks/db/restore-test` (`DBS`
  entries; add `systemd-silentsuite-data` to `APP_VOLUMES`).

- [ ] **Step 1: Harness first:** quadlet dry-run generates
  `db-dump-silentsuite.service`; against Task 2's local Postgres it writes
  all four files with pre == post. → FAIL first, then implement, then PASS.
- [ ] **Step 2:** `bash -n` both mise tasks. Commit
  `feat(db-dump): dump the silentsuite database`.

### Task 4: Upgrade gate — Renovate rule and CI check

**Files:** Modify `renovate.json5`. Create
`.github/workflows/silentsuite-release.yml`.

- [ ] **Step 1: Renovate rule** for
  `ghcr.io/silent-suite/silentsuite-server`:
  `versioning: "regex:^v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)(-beta(\\.(?<build>\\d+))?)?$"`,
  `automerge: false`, `minimumReleaseAge: "3 days"`, and a comment
  pointing at the gate. Verify with `npx --yes --package renovate --
  renovate-config-validator` (or the repo's existing check).
- [ ] **Step 2: CI gate, test first.** The workflow step reads `tag@digest`
  from `silentsuite.container.gotmpl` and fails unless the GitHub release
  for that tag is published and its `server-image.json` `indexDigest`
  equals the pinned digest. Write it as a script in the workflow and run it
  locally three ways:
  - the current pin → pass;
  - a tag with no release, e.g. `v0.5.21-beta@<its digest>` → fail
    (Review Focus 4);
  - the right tag with a wrong digest → fail.

  Triggers: PR and push on that file and the workflow itself.
- [ ] **Step 3:** Commit `ci: gate silentsuite image on published release`.

### Task 5: Deploy on bow and first run

Every step here touches the vault, bow, Pangolin or `main`. Confirm with
the user before Step 1.

- [ ] **Step 1:** `mise silentsuite:init-secrets` against the real
  `attributes/bow.yml`. Give the printed bootstrap token to the user (it
  stays in the vault too). Commit `chore(vault): add silentsuite secrets`.
- [ ] **Step 2:** In one commit: `Hosts.bow.Components` += `"silentsuite"`;
  `serve.json` `"3735": { "TCPForward": "silentsuite:3735" }`; AGENTS.md
  repo layout. Push (secrets commit first, or in the same push: the
  missing-attribute gotcha only bites if the component lands without the
  keys).
- [ ] **Step 3:** `materia update` on bow now. Expected: no `FATA`, both
  services active, `is_etebase` 200 from inside the container, `/data`
  owned `100:101` (rootful check, carried over from #192).
- [ ] **Step 4: Pangolin (user, dashboard).** Resource
  `silentsuite.<baseDomain>`, site **flutterina**, target
  `<bow-ts-ip>:3735`, **SSO off**, health check path
  `/api/v1/authentication/is_etebase/` with the Host header set. Verify from
  the workstation: `curl -s -o /dev/null -w '%{http_code}'
  https://silentsuite.<baseDomain>/api/v1/authentication/is_etebase/` → 200.
  Also check the `app` container's traefik config (the retarget gotcha).
- [ ] **Step 5: First signup (user).** In the Android or web app, use the
  server URL `https://silentsuite.<baseDomain>/?bootstrap_token=<token>`.
- [ ] **Step 6: Close signups at once (Review Focus 5).** Run
  `mise silentsuite:init-secrets --close`, commit, push, then
  `materia update` on bow. Verify: a raw signup (the msgpack harness)
  against the public URL gets 403 `registration_token_required`, and the
  user's account still logs in.
- [ ] **Step 7:** Next morning, check `db-dump` and `db:restore-test` for
  silentsuite. Tick #192 and record the results in the investigation doc.
