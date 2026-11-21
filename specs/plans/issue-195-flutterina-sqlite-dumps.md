# Nightly consistent SQLite copies on flutterina — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every night, write a consistent copy of each of flutterina's
SQLite databases (Pangolin's and Beszel's) into a named volume that the
existing restic job carries off-host. Alert when it fails, and prove that a
restore from the restic copy is intact.

**Architecture:** A new flutterina-only component, `sqlite-dump`, the
SQLite counterpart of bow's `db-dump` (#194).
- One oneshot `.container` per database runs a shared Node script on the
  **pinned Pangolin image**, which already ships Node 24 and `better-sqlite3`
  11.9.1. The script opens the live database read-only and runs
  `VACUUM INTO` (a consistent copy in one statement, safe while the app
  writes). It then checks the copy, records its row counts and writes
  `.done`, using atomic renames.
- A trigger service, fired by a 23:30 timer, restarts the dump units and
  pings healthchecks.io `db-dump-flutterina`.
- restic already backs up `/var/lib/containers/storage/volumes` at 00:00, so
  there is no restic change.
- `mise db:restore-test` grows a `sqlite` kind and per-host database lists,
  so `--target core@flutterina` works.

**Tech Stack:** materia quadlets, `docker.io/fosrl/pangolin` (Node +
better-sqlite3), bash mise tasks, restic via the restic-backup image.

**Spec:** GitHub issue #195. Option 2 chosen by the user, 2026-11-20 (the
options are in the conversation and the issue comment). Revised after a
Codex review (same day); its six points are marked **[review]**.

## Facts (checked 2026-11-20)

- Pangolin: `/app/config/db/db.sqlite` in the `pangolin-config` volume
  (`path.join(APP_PATH, "db", "db.sqlite")` in `dist/server.mjs`, with
  `APP_PATH = "config"` and cwd `/app`), `journal_mode = WAL`. The image
  runs as root (uid 0) and has no `sqlite3` CLI.
- Beszel: PocketBase in `/beszel_data` (the `beszel-data` volume). WAL is
  PocketBase's default. **[review]** A fresh pinned hub (0.21.2, run locally)
  creates:
  - `data.db`: every app table (`systems`, `system_stats`, `alerts`,
    `users`, `_superusers`, …);
  - `auxiliary.db`: only `_logs`;
  - `id_ed25519`: the hub's SSH key. It is static, so restic's volume copy
    already holds it, but a recovery must keep it.
- **Spike** (local, the pinned Pangolin image):
  - Setup: container A wrote continuously in WAL mode; container B, on the
    same volume, opened the DB `{readonly: true, fileMustExist: true}` and
    ran `VACUUM INTO` 5 times.
  - Result: every copy passed `integrity_check` and held a growing row
    count, so each was a point-in-time snapshot. Each copy is in `delete`
    journal mode, a single self-contained file.
  - `NODE_PATH=/app/node_modules` makes `require('better-sqlite3')`
    resolve for a script outside `/app`.
- flutterina's restic runs daily at 00:00 (`resticOnCalendar = "daily"`).

## Global Constraints

- **Output per database** in the `sqlite-dumps` volume (`/dumps`):
  - `<name>.sqlite`: the `VACUUM INTO` copy;
  - `<name>.counts`: `<table>\t<rows>`, sorted with `LC_ALL=C`, user tables
    only (`sqlite_master` where `type='table'` and name not like
    `'sqlite_%'`);
  - `<name>.done`: written last. Line 1 is the UTC time (`%FT%TZ`); lines 2
    and 3 are `sha256  <name>.sqlite` and `sha256  <name>.counts`. **[review]**
    restic can read the files while a run replaces them (a boot catch-up or
    manual run near 00:00), so an old `.sqlite` can sit next to a new
    `.done`. Equal row counts wouldn't catch changed values. The hashes do:
    the restore test verifies them first.

  Everything goes through `.tmp` names and is renamed. `<name>.done` is
  removed before the first rename (the #199 lesson). Mode is `umask 077`;
  `/dumps` is 0700.
- **Names:** `pangolin` (`/src/db/db.sqlite`) and `beszel`
  (`/src/data.db`). `auxiliary.db` holds only `_logs` (verified above), so
  it is not dumped. Each source volume is mounted at `/src`. A read-only
  connection still uses the WAL index: it may write `-shm`, and create
  `-wal`/`-shm` if absent. So the mount is read-write and the plan makes no
  "never writes" claim. **[review]** The label (`:z` or none) is decided
  from the live labels in Task 4 Step 1: the app mounts `pangolin-config`
  with none today.
- **Image:** byte-identical to `components/pangolin/app.container.gotmpl`'s
  `Image=`, so Renovate bumps it in the same PR. Extend
  `check:db-dump-images` (#201) with that rule.
- **Compatibility gate [review]:** parity can't notice a Pangolin image that
  drops or changes `better-sqlite3`. A committed workflow,
  `sqlite-dump-compat.yml`, runs on every PR and push touching
  `components/pangolin/app.container.gotmpl` or `components/sqlite-dump/`. It
  runs `dump.cjs dump` and `check` against a WAL fixture on the pinned image.
  Pangolin digest/patch/minor bumps automerge with `ignoreTests: true`,
  so this check reports after the merge, not before it. **Decision (user,
  2026-11-20): option (a), keep automerge.** A red check on main plus the
  next night's `/fail` ping is the alert; only the dump tool is at risk,
  never the edge. (Option (b), taking Pangolin out of automerge so the
  check gates the bump, was not chosen.)
- **Restart workarounds:** same as db-dump (BUG-004, #31).
  - `[Settings] NoRestart = true`.
  - Dump services: `Stopped` + `Oneshot`, and no `RestartedBy`.
  - Trigger: `Stopped`.
  - Timer: `Static`.
  - Dump units are `Type=oneshot`, `RemainAfterExit=yes`, and
    `After=<app>.service` with **no** `Requires=` (a dump must never start
    or stop the app; stopping `app` takes the whole edge down).
- **Script name:** `dump.cjs`, not `.js`/`.sh` (`.sh` is a materia Script
  resource; `.cjs` keeps `require` regardless of package type).
- **Blast radius:** any failure on flutterina's materia run blocks every
  component there, Pangolin included. Nothing in this plan may start, stop
  or restart `app`, `gerbil`, `traefik` or `beszel-hub`.

## Review Focus

1. **The Pangolin app is writing during `VACUUM INTO`.** Expected:
   - the copy is a consistent snapshot (spike);
   - the writer keeps committing throughout;
   - the run finishes within a bound (60 s locally on the fixture);
   - WAL growth during the run stays bounded: a reader holds back
     checkpoints only while it runs.

   **[review]** None of these is a guarantee from the read-only flag: the
   Task 1 test measures each, with a busy timeout on the writer that logs
   any `SQLITE_BUSY`.
2. **The source DB is missing** (fresh host, or a renamed path after a
   Pangolin upgrade). Expected: the unit fails with "no database at …",
   the trigger reports `/fail`, the previous set stays, and the restore
   test flunks it as stale after 36 h.
3. **A Pangolin image bump that drops or changes `better-sqlite3`.**
   Expected: the dump fails loudly (`Cannot find module`) at the next
   23:30, not silently. Task 1's script test runs against the pinned image.
4. **Sidecar files.** A read-only connection may create `-wal`/`-shm` when
   they are absent (app stopped). Expected: the source's logical content
   is unchanged; a dump of it before and after the run hashes the same.
   The app then starts normally on that directory. Assert that, not an
   unchanged listing. **[review]**
5. **The restore test on flutterina.** Expected: the `sqlite` kind checks
   freshness, the `.done` hashes, `integrity_check` and exact row counts.
   Beszel's copy also starts a throwaway hub that answers `/api/health`.
   bow's run is unchanged.
6. **Recovery, not only integrity [review].** Integrity and counts taken
   from the same copy prove it is self-consistent, not that the app
   recovers from it. Expected: the documented procedure (Task 4 Step 6)
   brings each app up on a restored copy in isolation.

---

### Task 1: `dump.cjs` (dump and check modes)

**Files:**
- Create: `components/sqlite-dump/dump.cjs`
- Test: scratchpad `sqlite-dump-test.sh` (local podman, pinned Pangolin
  image; not committed)

**Interfaces:**
- Produces:
  - `node /dump.cjs dump <name> <source path>` writes the three files to
    `/dumps`, exits 0 on success and non-zero on any failure, and prints
    `dumped <name>: <bytes> bytes, <n> tables`.
  - `node /dump.cjs check <copy> <counts>` exits 0 only if
    `integrity_check` is `ok` and the copy's counts equal the file's
    exactly; it prints `ok <n> tables` or the first mismatch.

- [ ] **Step 1: Write the test.**
  - Set up a WAL source DB with 2 tables, plus a writer container
    inserting in a loop that logs any `SQLITE_BUSY`.
  - Run `dump` 3 times during the writes.
  - Assert, each time: rc 0; `.done` matches
    `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$`; `check` passes on the copy; and
    `.counts` has both tables.
  - Assert the writer logged no busy error and kept committing (its row
    count rose during every dump); each dump finished within 60 s; the
    `-wal` size after the runs is below a stated bound (record it).
  - Sidecars: stop the writer, checkpoint, and delete `-wal`/`-shm`, then
    dump. Expected: rc 0, and `check` passes. Record whether sidecars were
    created. The source's own `VACUUM INTO` copy before and after hashes
    the same (logical content unchanged). Then the writer reopens the DB
    and commits.
  - The `.done` hash lines equal `sha256sum` of `.sqlite` and `.counts`.
  - Negative: a missing source path gives rc 1, the previous set stays
    byte for byte, and stderr contains `no database at /src/…`.
  - Negative: kill between renames (the #199 harness approach: inject
    `process.kill(process.pid, 'SIGKILL')` after the `.sqlite` rename),
    which must leave no `.done`.
  - Negative: a counts file edited by one row makes `check` exit 1 with
    `counts differ: <table>`; a copy truncated by one page exits 1 with
    `integrity_check failed`.
  - Every negative asserts its exact diagnostic and exit status, not just
    "non-zero". **[review]**
- [ ] **Step 2: Run it.** Expected: FAIL (`dump.cjs` doesn't exist).
- [ ] **Step 3: Implement `dump.cjs`.** Synchronous better-sqlite3 calls
  only. Order:
  1. remove stale `.tmp` files;
  2. check the source exists;
  3. `VACUUM INTO` the `.tmp` copy;
  4. open the copy, `integrity_check`, write the `.counts.tmp`;
  5. `rm .done`;
  6. rename `.sqlite`, then `.counts`;
  7. write `.done.tmp`, then rename it.
- [ ] **Step 4: Run the test.** Expected: all PASS.
- [ ] **Step 5: Commit the test too.** Move the fixture part of the test
  into `components/sqlite-dump/test/compat.bash` (runs `dump` + `check` on
  a WAL fixture against a given image; exit 0/1) and add
  `.github/workflows/sqlite-dump-compat.yml`, which runs it on the pinned
  Pangolin image (paths filter per Global Constraints). The concurrency,
  sidecar and kill cases stay in the scratchpad harness. Expected: the
  workflow is green on the branch. Commit
  `feat(sqlite-dump): consistent SQLite copy script (#195)`. The test dir
  is a materia data resource too: it installs into the data dir, which is
  harmless. It is `.bash`, not `.sh`, so materia never types it as a
  Script (AGENTS.md gotcha).

### Task 2: The `sqlite-dump` component

**Files:**
- Create in `components/sqlite-dump/`:
  - `MANIFEST.toml` (`[Defaults] sqliteDumpOnCalendar = "*-*-* 23:30:00"`);
  - `sqlite-dump-pangolin.container.gotmpl`;
  - `sqlite-dump-beszel.container.gotmpl`;
  - `sqlite-dumps.volume`;
  - `sqlite-dump-trigger.service.gotmpl` (the bow trigger's shape:
    `Wants=`/`After=network-online.target`, healthchecks.io `db-dump-<host>`
    `/start` then success or `/fail`, and
    `systemctl restart sqlite-dump-pangolin.service sqlite-dump-beszel.service`);
  - `sqlite-dump.timer.gotmpl` (`Persistent=true`).
- Modify: `MANIFEST.toml` (`Hosts.flutterina.Components` gains
  `"sqlite-dump"`), `.mise/tasks/check/db-dump-images`, `AGENTS.md` (layout
  entry, task list unchanged).

Each dump quadlet:
- `Image=` is the Pangolin pin;
- `Network=none`;
- `Volume=<source>.volume:/src:z`, `Volume=sqlite-dumps.volume:/dumps:z`,
  and `Volume={{ m_dataDir "sqlite-dump" }}/dump.cjs:/dump.cjs:ro,z`;
- `Environment=NODE_PATH=/app/node_modules`, `Entrypoint=node` (one
  mechanism only, the quadlet key) and
  `Exec=/dump.cjs dump <name> /src/<path>`. **[review]** `Entrypoint=` is
  in podman 6.1.4's `podman-systemd.unit(5)`; Task 4 Step 1 confirms
  flutterina's podman version supports it (quadlet added it in 5.0);
  if not, fall back to `PodmanArgs=--entrypoint=node` and record why;
- `Type=oneshot`, `RemainAfterExit=yes`, `TimeoutStartSec=15min`.

- [ ] **Step 1: Failing check.** Extend `check:db-dump-images` so that
  every `components/sqlite-dump/*.container.gotmpl` `Image=` must equal
  `components/pangolin/app.container.gotmpl`'s, with the message
  `<unit>: Image= differs from pangolin app`. Run it on a copy with the
  quadlets present but one digest changed. Expected: exit 1. On the real
  tree before Task 2's files exist, it should pass (no files) — then add
  the files.
- [ ] **Step 2: Write the files.** Render each `.gotmpl` by hand (no
  materia renderer) into a temp dir and run
  `/usr/libexec/podman/quadlet -dryrun`. Expected: no errors; the generated
  `ExecStart` has `--entrypoint` set to node (once), `--network none`, both
  volume mounts and `/dump.cjs dump pangolin /src/db/db.sqlite`.
- [ ] **Step 3: Local unit-level test.** Run the dryrun-generated podman
  command lines by hand against local volumes holding the Task 1 fixture.
  Expected: the same results as Task 1.
- [ ] **Step 4: Run** `bash .mise/tasks/check/db-dump-images`. Expected:
  `OK`, now counting the sqlite-dump units too.
- [ ] **Step 5: Commit**
  `feat(sqlite-dump): nightly SQLite copies on flutterina (#195)`. Not
  pushed until Task 4.

### Task 3: `db:restore-test` for flutterina (`sqlite` kind)

**Files:**
- Modify: `.mise/tasks/db/restore-test`
- Test: the #200 harness (scratchpad `d200/restore-test-harness.sh`),
  extended with sqlite cases

**Interfaces:**
- Consumes: `dump.cjs check` from Task 1, mounted from
  `/var/lib/materia/components/sqlite-dump/dump.cjs` on the host. The
  image comes from the installed `sqlite-dump-pangolin.container`.

Design:
- `DBS`, `APP_VOLUMES` **and `DUMPS`** are chosen by `RHOST` (from the
  restic quadlet). **[review]** `DUMPS` is hardcoded to
  `systemd-db-dumps` today.
  - bow: today's lists, unchanged.
  - flutterina:
    - `DBS`: `pangolin|sqlite|<sqlite-dump-pangolin quadlet>|-` and
      `beszel|sqlite|<sqlite-dump-beszel quadlet>|-`;
    - `APP_VOLUMES`: `systemd-pangolin-config systemd-letsencrypt`;
    - `DUMPS`: `$VOLS/systemd-sqlite-dumps/_data`;
  - any other host: `error: no restore-test config for host <h>`.
- For the `sqlite` kind, the files are `sqlite counts done`, with the same
  freshness rule (≤36 h). The `.done` hashes are checked against the
  restored files first (`hash mismatch: <file>`). Step 3 runs `dump.cjs
  check` in a throwaway `--network none` container instead of a DB server,
  and passes only on `ok`. For `beszel` it also starts a throwaway hub
  (the installed `beszel-hub.container`'s `Image=`, `--network none`) on a
  temp dir holding the restored copy as `data.db`, and requires
  `/beszel health --url http://localhost:8090` to pass within 60 s.
- Harness overrides: the existing `DB_NAMES`, `VOLS`, `RQ`,
  `DBS_QUADLET_DIR`, `APP_VOLUMES`, plus `DUMP_SCRIPT` (path of `dump.cjs`;
  default `/var/lib/materia/components/sqlite-dump/dump.cjs`). Host
  selection comes from the fake quadlet's `RESTIC_HOST`. **[review]**
  - The existing 11 cases switch their fake quadlet to `RESTIC_HOST=bow`
    (they used `harness`, which the new host check would reject).
  - The sqlite cases use `RESTIC_HOST=flutterina` and
    `DB_NAMES="pangolin beszel"`.
  - A case with `RESTIC_HOST=harness` must exit 1 with
    `no restore-test config for host harness`.

- [ ] **Step 1: Extend the harness with failing cases.**
  - (s1) a good sqlite set passes;
  - (s2) the copy truncated by one page: `integrity_check` fails, giving
    `FAIL pangolin: copy failed check`;
  - (s3) a counts row changed: `FAIL beszel: … rows, expected …`;
  - (s4) `.done` 40 h old: stale;
  - (s5) an old `.sqlite` beside a new `.done` (the overlap case):
    `FAIL pangolin: hash mismatch: pangolin.sqlite`;
  - (s6) Beszel's restored copy with `systems` dropped: the hub check
    fails or the counts differ, with a named diagnostic;
  - (s7) unknown host: `no restore-test config for host harness`, rc 1.

  Every case asserts its exact line and the exit status.

  Then re-run all 11 existing cases.
- [ ] **Step 2: Run.** Expected: s1–s7 FAIL as RED (no sqlite kind, no
  host check), and the 11 existing cases still pass with
  `RESTIC_HOST=bow`.
- [ ] **Step 3: Implement.** Expected: all 18 pass.
- [ ] **Step 4: Commit**
  `feat(db): restore-test covers flutterina's SQLite copies (#195)`.

### Task 4: Deploy on flutterina, then prove it end to end

- [ ] **Step 1: Read-only pre-checks on flutterina** (tailnet ssh):
  - `podman --version` (Entrypoint= support, see Task 2).
  - `getenforce`; `ls -Z` on both volumes' `_data` and `db/`. If SELinux is
    enforcing and the labels are not already shared (`s0` without
    categories), use no label option on the sidecar's `pangolin-config`
    mount, and run it with `SecurityLabelDisable=true` instead of
    relabelling a volume the app owns. Record the choice. **[review]**
  - `ls -la` of `…/systemd-pangolin-config/_data/db/` and
    `…/systemd-beszel-data/_data/`. Expected: `db.sqlite` and `data.db`,
    each with `-wal`/`-shm`.
  - `df -h /`: free space of at least 3× the two DB sizes.
- [ ] **Step 2: healthchecks.io.** Create `db-dump-flutterina` with
  `curl "$(fnox get HC_PING_URL)/db-dump-flutterina?create=1"`. The user
  sets period 1 day and grace 2 h in the UI (as for #198).
- [ ] **Step 3: Inspect the plan before applying [review].** Run the
  read-only plan the way `mise materia:sync-image` does (empty output
  overlay, `materia plan`) against the pushed commit. Expected: only
  `sqlite-dump` install steps, plus the timer enable. Any `Restart` or
  `Stop` of `app`, `gerbil`, `traefik`, `beszel-hub` or `pangolin-pod`
  stops the deploy.
- [ ] **Step 3b: Push and run materia on flutterina.**
  - `journalctl -u materia-update.service` shows no `FATA`, and the plan
    has only `sqlite-dump` steps: no Restart of `app`/`beszel-hub`.
  - `systemctl --failed` is empty.
  - Pangolin's dashboard and every public route still answer.
- [ ] **Step 4: First run by hand:**
  `sudo systemctl start sqlite-dump-trigger.service`. Expected: rc 0,
  both units print `dumped …`, the healthchecks.io check goes up, and
  Traefik/Pangolin logs show no `SQLITE_BUSY` during the run.
- [ ] **Step 5: Restore test, after the next 00:00 restic run.** Run
  `mise db:restore-test --target core@<flutterina tailnet IP>`. Expected:
  `passed`, both copies `ok`, and the unchanged files in the two volumes
  identical. Then run it on bow too: unchanged, passed.
- [ ] **Step 6: Recovery procedure and drill [review].** Add a "Restoring
  a SQLite app" runbook to `AGENTS.md` (or `specs/runbooks/`), and run it
  once in isolation from restic, never on flutterina's live volumes.
  - **Beszel:**
    1. restore `systemd-beszel-data` (for `id_ed25519` and the rest);
    2. stop `beszel-hub`;
    3. replace `data.db` with the restored copy;
    4. delete `data.db-wal` and `data.db-shm`; they belong to the old file
       and would corrupt the new one. Keep `auxiliary.db` or drop it
       (logs only);
    5. start the hub.

    Drill: the restore test's throwaway hub does this already.
  - **Pangolin:** the same file swap for `db/db.sqlite` and its
    `-wal`/`-shm`, with the whole pod stopped (`app` stop takes
    `gerbil`/`traefik` down anyway). Drill:
    1. start a throwaway `app` container from the pinned image, on a temp
       config dir holding the restored `db.sqlite` plus the rendered
       `config.yml`/`privateConfig.yml`, with `--network none`;
    2. require its internal API (`localhost:3001`) to answer and report
       the same resource count as the live dashboard.

    Record both results here.
- [ ] **Step 7:** Tick #195's boxes and close it with the evidence.
  Record the deploy in this plan. File a follow-up for bow: its
  `db-dump` `.done` has the same restic-overlap gap that item 1 of the
  review found here.

## Deployed (2026-11-20/21)

- Branch `195-sqlite-dump` (d75c866, d43c0d9, f23f97d) on main.
  - Task 1 local test: 3 dumps during writes and 0 `SQLITE_BUSY`; `-wal`
    4.1 MB at 20 tx/s, the same as the writer alone. Flat out it reached
    208 MB, because growth is write rate x dump time.
  - Kill test: a kill after the `.sqlite` rename leaves no `.done`.
  - Restore harness: 18 cases; the 7 sqlite cases were RED before the
    change and GREEN after.
- **Rulings:**
  - Source volumes are mounted by podman name, not `.volume`, so the dump
    units have no `Requires=` on the apps' volume units.
  - s6 tests a hub image that cannot start, not a dropped table: PocketBase
    migrates an incomplete DB on start.
  - The WAL bound is tested at 20 tx/s, not flat out.
  - The compat workflow cannot run on a branch; it runs on main.
- **flutterina pre-checks:**
  - podman 5.7.1, which accepts `Entrypoint=` (quadlet dry-run on the host);
  - SELinux Permissive, so `pangolin-config` stays unlabelled as the app
    mounts it;
  - 11 GB free.
  - Pangolin's live DB has no `-wal`, i.e. it runs in rollback-journal mode.
    Tested locally on a 21 MB DB with better-sqlite3's default timeout:
    5 dumps of about 1.1 s each, 0 `SQLITE_BUSY`, slowest commit 54 ms.
- **Plan before apply:** only the 13 `sqlite-dump` install steps and the
  timer enable. The apply matched it. Pod, `app`, `gerbil`, `traefik` and
  `beszel-hub` stayed active, with no failed units.
- **First manual run (18:18Z):** pangolin 147 tables, beszel 25 tables, files
  0600, no busy or locked lines in the app logs.
- **Nightly 23:30 run:** both dumps done in 2 s. restic snapshot `1412a832`
  at 00:00. `mise db:restore-test` passed on flutterina: both copies ok,
  the Beszel hub answers on its copy, and the unchanged files are identical.
  It also passed on bow (`12436e88`), unchanged.
- **Pangolin recovery drill** on `1412a832`: the restored copy's hash matches
  `.done`, and a throwaway `app` (`--network none`) generated the same
  Traefik config shape as the live app (20 routers, 10 services). The
  runbook is in AGENTS.md ("Restoring a SQLite app").
- healthchecks.io `db-dump-flutterina`: created, with period 1 day and grace
  2 h.
- Not reproduced: the once-off `NeedDaemonReload` warning at the first manual
  run (`no` on all three units the next day).
