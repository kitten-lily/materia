# Scheduled DB dumps on bow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every night, write a logical dump of each bow application
database into a podman named volume that the existing restic job carries
off-host. Alert when a dump fails, and prove that a restore from the restic
copy reproduces the data.

**Architecture:** A new bow-only component, `db-dump`. Each database gets
one oneshot `.container` quadlet. It runs the official client image (same
pin as its server) on `newt-net` and writes `<name>.sql` plus evidence files
into the `db-dumps` named volume. A trigger service, fired by a 23:30 timer,
restarts the dump units and pings healthchecks.io. restic already backs up
`/var/lib/containers/storage/volumes`, so dumps reach the Storage Box at its
00:00 run with no restic change. A `mise db:restore-test` task restores one
pinned snapshot into throwaway containers and checks it against the
evidence.

**Tech Stack:** materia quadlets (`.container.gotmpl`, `.volume`,
`.service.gotmpl`, `.timer.gotmpl`), official `mariadb`/`postgres` images,
bash mise tasks, restic via the existing `restic-backup` image.

**Spec:** GitHub issue #194, plus the decisions below. Scope is bow only
(2026-11-18). flutterina's SQLite databases are #195. Revised after a Codex
review (same day): the review's 8 points are folded in and marked
**[review]**.

## Decisions

- **Destination: a named volume, not the materia data dir** (data-dir
  drift deletes anything materia didn't install). `db-dumps.volume` →
  `/var/lib/containers/storage/volumes/systemd-db-dumps/_data/`, which is
  already in restic's `BACKUP_PATHS`.
- **Dump the application database only, not the server.**
  **[review]** grimmory: `mariadb-dump --databases grimmory`. mediamanager:
  `pg_dump mediamanager`. No `mysql` system schema, no cluster roles.
  This matches how a real rebuild works: a fresh server container creates
  the app user and empty database from its `MARIADB_*`/`POSTGRES_*` env,
  then the dump is loaded into it. It also avoids restoring system tables
  over a fresh server and "role already exists" errors. Grants and users
  live in the component env and vault, not in the dump.
- **Consistency.** **[review]** `--single-transaction` is only a consistent
  snapshot for InnoDB tables. Task 3 Step 1 checks bow's engines; any
  non-InnoDB table in `grimmory` must be listed in the plan before deploy
  (accept or add `--lock-tables`). `pg_dump` is always a consistent
  snapshot. Concurrent DDL (an app migration, or a materia-driven DB restart
  during catch-up or a manual update) makes the dump error out. **An overlap
  is a failed backup:** the dump exits non-zero, the check alerts, and the
  next night's run (or a manual `systemctl start db-dump-trigger.service`)
  retries. The 23:30 schedule keeps clear of the 05:00 materia run but
  doesn't guarantee it.
- **Evidence written with each dump.** **[review]** In the same unit,
  in order:
  1. `<name>.counts.pre.tmp` (exact per-table row counts);
  2. the dump to `<name>.sql.tmp`;
  3. `<name>.counts.post.tmp`;
  4. on success, `mv` the three into place without `.tmp`;
  5. `<name>.done` last, holding the UTC completion time
     (`date -u +%FT%TZ`).

  A restore is valid only if `<name>.done` is fresh. Each restored table's
  count must lie within `[pre, post]`. At 23:30 these are almost always
  equal.
- **Files and permissions.** **[review]** The dump shell runs
  `umask 077`, `chmod 0700 /dumps`, and a `trap` that removes
  `/dumps/<name>.*.tmp` on any exit. A `.tmp` file restic happens to capture
  mid-run is ignored at recovery. Dumps hold application data, including
  password hashes. They stay root-only on bow, and restic encrypts them
  off-host. On deploy, check the host path permissions (Task 3 Step 4).
- **One file set per database, overwritten nightly.** History comes from
  restic retention (7 daily, 4 weekly, 6 monthly). Plain SQL dedups well.
  Local cost is one dump per DB on the root SSD.
- **Schedule:** dump timer `*-*-* 23:30:00`, `Persistent=true`. restic is
  `daily` (00:00) and materia-update is 05:00 on bow (`bare-metal.bu`).
- **Client image = server image pin, in a quadlet**, so Renovate's quadlet
  manager bumps it in the same PR as the server. **[review]** The mise tasks
  stop carrying their own pins. They read `Image=` from the installed
  server quadlet on the host
  (`/etc/containers/systemd/<component>/<db>.container`), so they can't
  drift.
- **Secrets are referenced, not declared.** `mariadbRootPassword` and
  `mediamanagerDbPassword` live in the grimmory/mediamanager vault scopes,
  which `db-dump` can't see. Their podman secrets already exist host-wide,
  so the quadlets hand-write `Secret=materia-<name>,type=env,target=…`, as
  `db:backup` does. **[review]** This depends on materia v0.8 not pruning a
  secret that another component on the host still declares, and on the
  producer components being on the host. Task 1 Step 0 is the gate.
- **restic-backup's oneshot pattern, copied exactly** (BUG-004, #31). Dump
  units are `Type=oneshot` + `RemainAfterExit=yes` with no `[Install]`. The
  manifest sets `Settings.NoRestart = true` and `Stopped = true` +
  `Oneshot = true`, with no `RestartedBy`. The timer targets a trigger that
  runs `systemctl restart`.
- **Shared volume label `:z`**, not `:Z`. **[review]** Both dump units run at
  the same time and share the volume (AGENTS.md, SELinux relabels).
- **Bounded connects.** **[review]** `mariadb-dump --connect-timeout=10`,
  `PGCONNECT_TIMEOUT=10`, unit `TimeoutStartSec=1h`.
- **A stopped DB fails its dump.** Dump units use `After=` but not
  `Requires=` on the DB service, so a dump never starts a stopped DB.
- **One alert check**, slug `db-dump-<hostname>`: the trigger pings `/start`,
  then success or `/fail`, with host-side `curl` (Flatcar ships it). Every
  ping is `-` prefixed, the same shape as `materia-update.container`.

## Global Constraints

- Quadlet comments on their own lines, never after a value.
- `Environment=` values containing spaces must be quoted. `$` in an
  `ExecStart*`/`Exec=` that systemd would expand is written `$$`.
- No real domain, IP or secret in tracked files. `hcPingURL` comes from
  vault `globals`.
- Images pinned `tag@sha256:…`, identical to the server quadlet's line.
- `db-dump` joins `Hosts.bow.Components` only after Tasks 1–2 verify
  locally. A bad unit fails materia-update for the whole host.
- Conventional Commits, subject ≤ 50 chars, one logical change per commit.

## Review Focus

1. **DB stopped or restarted at 23:30**: the dump must fail without
   starting the DB, the previous files must be untouched, and the trigger
   must ping `/fail`. Covered by Task 1 Step 4.
2. **Dump killed part-way**: no `.tmp` left behind, previous `.sql`/`.done`
   unchanged. Covered by Task 1 Step 4.
3. **Both dumps run at once and one fails**: the other completes (shared
   label), and the trigger exits non-zero. Covered by Task 2 Step 3.
4. **Fresh snapshot, stale dump** (dumps failing for a week while restic
   keeps running): the restore test must fail on `<name>.done` age, not
   pass on snapshot age. Covered by Task 4 Step 2.
5. **Root disk filling**: measure before enabling. Covered by Task 3
   Step 1.

---

### Task 1: Dump quadlets + volume

**Files:**
- Create: `components/db-dump/db-dumps.volume`
- Create: `components/db-dump/db-dump-grimmory.container.gotmpl`
- Create: `components/db-dump/db-dump-mediamanager.container.gotmpl`
- Smoke-test harness: session scratchpad only, never committed

**Interfaces:**
- Produces: units `db-dump-grimmory.service` and
  `db-dump-mediamanager.service`; volume `systemd-db-dumps` mounted at
  `/dumps`. Per database `<name>` ∈ {`grimmory`, `mediamanager`}, the files
  `<name>.sql`, `<name>.counts.pre`, `<name>.counts.post` (lines
  `<schema>.<table>\t<count>`, sorted) and `<name>.done` (one line,
  `YYYY-MM-DDTHH:MM:SSZ`).

- [ ] **Step 0: Secret-lifecycle gate.** **[review]** In materia v0.8.1's
  source (the pinned version), find where podman secrets are removed. Record
  in this plan the file and function, and confirm that a secret is only
  removed when *no* assigned component declares it. If that isn't so, stop
  and redesign: declare the secrets in `db-dump` with host-scoped vault
  copies.
  **Result (2026-11-18): passes.** v0.8.1 (`4304e19`): a component's host-side
  secret resources come only from its own manifest `Secrets`
  (`pkg/loader/secret.go`, `SecretDiscoveryStage.Process` checks existence
  of the component's own declared names). A secret is removed only by that
  component's resource diff (`pkg/planner/planner.go`,
  `generateUpdatedComponentResources`, `toRemove`) or by removing that
  component. A component that declares no secrets can't remove anyone's.
  Consequence: removing grimmory or mediamanager from bow removes its secret,
  and that dump then fails and alerts.
- [ ] **Step 1: Write the units.** `db-dumps.volume`: `[Volume]` only.
  Each `.container.gotmpl` has `[Unit] After=<db>.service`. Its
  `[Container]` section has:
  - `Image=` copied verbatim from the server quadlet;
  - `Network=newt-net`;
  - `Volume=db-dumps.volume:/dumps:z`;
  - `Secret=` lines per the decisions;
  - `PGCONNECT_TIMEOUT=10` (postgres only);
  - `Exec=sh -c '…'` implementing the evidence sequence from the
    decisions (umask, chmod, trap, pre counts, dump, post counts, mv,
    `.done`).

  Commands: grimmory runs `mariadb-dump -h grimmory-mariadb -uroot
  --connect-timeout=10 --databases grimmory --single-transaction --routines
  --events --triggers` with `MYSQL_PWD`. mediamanager runs `pg_dump -h
  mediamanager-postgres -U mediamanager mediamanager` with `PGPASSWORD`. The
  count queries are `db:backup`'s existing `counts` SQL, scoped to the one
  database. `[Service]`: `Type=oneshot`, `RemainAfterExit=yes`,
  `TimeoutStartSec=1h`. No `[Install]`.
- [ ] **Step 2: Verify quadlet syntax.** **[review]** Copy the three files
  into a temp dir, renaming `*.container.gotmpl` to `*.container` (no
  template expressions are expected in them), and run
  `QUADLET_UNIT_DIRS=<dir> /usr/libexec/podman/quadlet -dryrun -user=false`.
  Expected: `db-dump-grimmory.service`, `db-dump-mediamanager.service` and
  `db-dumps-volume.service`, no errors. Run `systemd-analyze verify` on each
  generated unit. Expected: clean, apart from the absent `<db>.service`
  dependency.
- [ ] **Step 3: Smoke test against throwaway DBs** (rootless, local). Start
  both servers with the same pins on a test network named `newt-net`,
  initialise them through the same `MARIADB_*`/`POSTGRES_*` env as
  production, seed two tables each, and create the podman secrets under
  their materia names. Run each dump container with the exact
  `Exec`/`Volume`/`Secret` flags, **both at the same time**. Expected: all
  four files per DB present, `.done` parses as a UTC time, pre == post,
  file mode 0600, directory mode 0700, no `.tmp`.
- [ ] **Step 4: Failure cases (Review Focus 1, 2).**
  (a) Stop one DB and run its dump. Expected: non-zero exit in ≤ 15 s,
  sha256 of the previous `.sql` and `.done` unchanged, and no `.tmp` files.
  (b) Run a dump against a seeded slow table and `podman kill` it
  mid-dump. Expected: same as (a).
- [ ] **Step 5: Commit** `feat(db-dump): add bow DB dump quadlets`.

### Task 2: Trigger, timer, manifest, alerting

**Files:**
- Create: `components/db-dump/MANIFEST.toml`
- Create: `components/db-dump/db-dump-trigger.service.gotmpl`
- Create: `components/db-dump/db-dump.timer.gotmpl`

**Interfaces:**
- Consumes: Task 1's unit names.
- Produces: `db-dump.timer` (static, `WantedBy=timers.target`) and
  `db-dump-trigger.service`. Manifest default `dbDumpOnCalendar`.

- [ ] **Step 1: Manifest.** `[Settings] NoRestart = true` and
  `[Defaults] dbDumpOnCalendar = "*-*-* 23:30:00"`. `[[Services]]`
  entries: both dump units `Stopped = true`, `Oneshot = true`; the trigger
  `Stopped = true`; the timer `Static = true`. No `Secrets`, no
  `RestartedBy`.
- [ ] **Step 2: Trigger and timer.**
  Trigger, `Type=oneshot`:
  - `ExecStartPre=-/usr/bin/curl -fsS -m 10 --retry 5 -o /dev/null {{ .hcPingURL }}/db-dump-{{ m_facts "host.hostname" }}/start`
  - `ExecStart=/usr/bin/systemctl restart db-dump-grimmory.service db-dump-mediamanager.service`
  - `ExecStopPost=`: a success or `/fail` ping keyed on `$$EXIT_STATUS`,
    copied in shape from `materia-update.container`.

  Timer:
  - `OnCalendar={{ m_default "dbDumpOnCalendar" "*-*-* 23:30:00" }}`
  - `Persistent=true`
  - `Unit=db-dump-trigger.service`
  - `[Install] WantedBy=timers.target`
- [ ] **Step 3: Concurrent partial failure (Review Focus 3).**
  **[review]** Install the generated Task 1 units and this trigger as
  **user** units locally (`~/.config/containers/systemd/`, with `systemctl
  --user` in the trigger and the ping URL pointed at a local `nc -l`).
  Stop only the postgres test DB, then start the trigger. Expected: the
  grimmory dump completes, the trigger fails, and the listener receives
  `/start` then `/fail`. Then restore the DB and start the trigger again.
  Expected: exit 0, and a success ping.
- [ ] **Step 4: `systemd-analyze verify`** the trigger and timer, with
  the template expressions substituted by hand. Expected: clean.
- [ ] **Step 5: Commit** `feat(db-dump): add trigger, timer and manifest`.

### Task 3: Deploy to bow

**Files:**
- Modify: `MANIFEST.toml` (`Hosts.bow.Components` += `"db-dump"`)
- Modify: `AGENTS.md` (repo-layout entry for `components/db-dump/`; a
  gotcha only if deploy turns up something non-obvious)

- [ ] **Step 1: Measure and check engines (Review Focus 5).** On bow:
  - `sudo du -sh` of each DB volume's `_data`, and `df -h /`. Expected:
    combined size well under 10% of free root space. If not, stop and
    revisit (compression, or the data LV).
  - `SELECT engine, count(*) FROM information_schema.tables WHERE
    table_schema='grimmory' GROUP BY engine`. Expected: InnoDB only. If
    not, record it in this plan's decisions first.
- [ ] **Step 2: Create the healthchecks.io check:**
  `curl "$(fnox get HC_PING_URL)/db-dump-bow?create=1"`, then set period
  1 day and grace 2 h in the UI.
- [ ] **Step 3: Wire up and push** the `Hosts.bow` change, then run
  `sudo systemctl start materia-update.service` on bow. Expected:
  `journalctl -u materia-update.service --since -10min | grep FATA` is
  empty, and `systemctl list-timers db-dump.timer` shows the next 23:30.
- [ ] **Step 4: First run by hand:** `sudo systemctl start
  db-dump-trigger.service`. Expected: exit 0; all eight files present;
  `stat -c '%a %U' _data _data/*` shows `700 root` and `600 root`; the
  healthchecks check is green.
- [ ] **Step 5: Commit** `feat(db-dump): deploy to bow` (MANIFEST and
  AGENTS.md), and push.

### Task 4: Restore test + `db:backup` cleanup

**Files:**
- Create: `.mise/tasks/db/restore-test`
- Modify: `.mise/tasks/db/backup` (per-DB user field; images read from
  the installed quadlets)
- Modify: `AGENTS.md` (task-list line: `db/restore-test`)

**Interfaces:**
- `mise db:restore-test --target <user@host> [--snapshot <id>]`: exit 0
  only if every check passes. `--snapshot` replaces the resolved latest ID
  (used to test the freshness check). It prints the snapshot ID and time and
  each `.done` time.

- [ ] **Step 1: `db:backup`.** Add `user` to each `DBS` entry (`root`,
  `mediamanager`) and use it instead of the hardcoded `-U mediamanager
  -d mediamanager`. Replace the `MDB`/`PG` constants with `Image=` read
  from the installed server quadlet. Verify: `bash -n`, then a real run
  followed by `--compare` against it on bow. Expected: `ok` for both.
- [ ] **Step 2: Write `db:restore-test`.** One ssh session as root, the
  same structure as `db:backup`. Take restic's env, secrets and mounts from
  the installed `/etc/containers/systemd/restic-backup/restic-backup.container`
  and run that image with `--entrypoint restic`. **[review]** Resolve the
  snapshot once:
  `restic snapshots --host <host> --path /var/lib/containers/storage/volumes --latest 1 --json`,
  and use that **ID** for every later `dump`/`restore`, never `latest`.
  Checks, each printed and each failing the task:
  - every `<name>.done` in the snapshot is ≤ 36 h old (Review Focus 4);
  - per DB, load `<name>.sql` into a throwaway server container (same image
    as the installed quadlet, private network, initialised by the same env
    with throwaway passwords, no volume) using fail-fast loading: `psql -v
    ON_ERROR_STOP=1`, or the `mariadb` client's default (stop at the first
    error). Then: the restored table set equals the `.counts.pre` table
    set, and each table's restored count lies within `[pre, post]`;
  - per app volume (`systemd-grimmory-data`, `systemd-mediamanager-images`),
    `restic restore <ID> --include <path> --target <tmp>`. Then compare
    sha256 sums of the files whose live mtime is older than the snapshot
    time with the restored copies. Expected: identical. Report the number
    of files compared. Delete the restore afterwards.
- [ ] **Step 3: Run it on bow** after the first 00:00 restic run that
  follows Task 3. Expected: exit 0, snapshot and `.done` times from the
  last 24 h. Then re-run it with a deliberately old `.done`, by restoring
  from an older snapshot ID passed via a `--snapshot` override flag.
  Expected: it fails on freshness.
- [ ] **Step 4: Commit** `feat(db): add restore test, per-DB backup user`,
  push, tick #194's boxes, and note on #192 what SilentSuite has to add
  (below).

## Adding a database later (SilentSuite)

1. `db-dump-<name>.container.gotmpl`, copied from the matching kind.
2. Append the unit to the trigger's `systemctl restart` line.
3. Add a `DBS` entry in `db:backup` and `db:restore-test`, and an app
   volume to the restore test (`silentsuite-data`).
