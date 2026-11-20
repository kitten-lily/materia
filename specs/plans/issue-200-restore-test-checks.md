# db:restore-test: tighter checks, named failures — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `mise db:restore-test`:
- picks the newest snapshot of the right path set;
- fails on an empty dump;
- names the check that failed instead of aborting or mislabelling.

**Architecture:** Edits inside the existing payload of
`.mise/tasks/db/restore-test`. To exercise the failure paths without bow, the
payload's host path constants become overridable env vars (with today's
values as defaults). A scratchpad harness then runs the payload rootless
against a local restic repo holding a crafted `systemd-db-dumps` tree.

**Tech Stack:** bash, restic (from the restic-backup image), podman.

**Spec:** GitHub issue #200 (deferred minors from the #194 final review).
Revised after a Codex review (2026-11-20).

## Global Constraints

- Output contract: `    ok    …` / `    FAIL  …` lines, final
  `restore test: passed|FAILED`, exit 1 on any FAIL. Nothing on the host is
  modified.
- Host defaults for `VOLS`, `RQ` and each DBS quadlet path stay exactly
  as today; the overrides exist only for the harness. Each override is one
  `${VAR:-default}`, with no other test-only branches.
- Snapshot filter: `--path /var/lib/containers/storage/volumes`, i.e. `$VOLS`.
  It is one of restic-backup's two `BACKUP_PATHS`, and the
  `--path` filter matches snapshots whose path set *contains* it.

## Decisions

- **Snapshot choice:** `restic snapshots --json --host "$RHOST" --path "$VOLS"
  --group-by host --latest 1`. `--path` keeps only snapshots that *include*
  that path (restic help, pinned image, 2026-11-20). `--group-by host` makes
  `--latest 1` return exactly one snapshot, so the existing `grep -o`
  extraction of the single `id`/`time` stays correct and there is no
  multi-entry JSON parsing or time sorting. Assert exactly one `"id"` in the
  output; anything else flunks "expected one snapshot, got N".
- **Empty dump:** flunk when `<name>.counts.pre` is empty (0 tables) or its
  row total is 0.
- **restic errors:** keep each `restic dump`'s stderr in `$work/<file>.err`.
  Only restic's "not found" message for the path (exact text pinned by the
  harness, case d1) reports as "missing from snapshot"; any other failure
  flunks "`<name>.<f>`: restic dump failed:" plus the first stderr line.
  Snapshot lookup errors (wrong password) already abort before step 2 with
  `no snapshot …`; that message changes to "snapshot lookup failed:" plus
  restic's first stderr line, instead of the misleading "no snapshot".
- **Garbled `.done`:** if `date -d` fails, flunk "`<name>.done` is not a
  timestamp: '<first 40 bytes>'" and skip the age check.
- **Live file vanishes mid-hash:** hash live files one by one. A file that
  `sha256sum` fails on *and* that no longer exists (`[[ ! -e ]]`) is
  skipped and counted as "changed since"; any other hashing failure
  (permission, I/O) flunks "`<vol>`: cannot hash live file <path>". A failing
  `find` flunks "`<vol>`: could not list the live copy". The existing
  "no files older than the snapshot" pass stays only for a volume whose
  `find` legitimately returned nothing.

## Review Focus

1. **Two snapshot groups for one host** (e.g. a manual run with other
   paths). Expected: the newest snapshot containing `$VOLS` is used.
2. **An app DB emptied or renamed.** Expected: `FAIL  <name>: dump has 0
   tables` or `0 rows`.
3. **Repository auth failure** (wrong password). Expected: "snapshot lookup
   failed: …" and exit 1, not "no snapshot for host".
4. **`restic dump` failing after a good lookup** (e.g. a pack file
   unreadable). Expected: "restic dump failed: …", not "missing from
   snapshot".
5. **Path defaults drift.** Expected: running with no overrides gives the
   same commands as today. Task 2's live bow run proves it.

---

### Task 1: Harness, then the four fixes (RED→GREEN per fix)

**Files:**
- Modify: `.mise/tasks/db/restore-test`
- Test: scratchpad `restore-test-harness.sh` (not committed; results go in
  the issue)

**Interfaces:**
- Produces: payload env overrides `VOLS`, `RQ`, `DBS_QUADLET_DIR` (prefix
  for the server quadlet paths; default `/etc/containers/systemd`),
  `DB_NAMES` (space-separated subset of the DBS names to test; default all
  four) and `APP_VOLUMES` (space-separated; default today's three).

- [ ] **Step 1: Write the harness.** Extract the payload
  (`sed -n "/<<'PAYLOAD_EOF'/,/^PAYLOAD_EOF/p"`). In a temp dir create a
  restic repo, a fake restic quadlet (`Environment=RESTIC_REPOSITORY=/repo`,
  `RESTIC_PASSWORD=x`, `RESTIC_HOST=harness`, `Volume=<tmp>/repo:/repo`,
  the real restic-backup `Image=`), fake server quadlets with the real
  `Image=` pins, and a dumps tree `<tmp>/vols/systemd-db-dumps/_data`
  holding a real `mariadb-dump` of a tiny grimmory-named DB and a real
  `pg_dump` of a tiny mediamanager-named DB (both made from throwaway
  servers on the pinned images). Run with `DB_NAMES="grimmory mediamanager"`.
  Back up `<tmp>/vols` with `--host harness`, mounted at the same absolute
  path inside the restic container. Run the payload rootless. Cases, each
  with its expected line asserted by grep:
  (a) good set → passes;
  (b) mediamanager's counts files empty, schema-only `.sql` → `dump has 0 tables`;
  (c) `.done` = `garbage` → `is not a timestamp`;
  (d1) grimmory's `.done` deleted before the backup → `missing from snapshot`
  (and record restic's exact stderr text for the matcher);
  (d2) wrong `RESTIC_PASSWORD` → `snapshot lookup failed`;
  (d3) after a good lookup, a dump failure: delete one `data/` pack file in
  the repo → `restic dump failed`;
  (e) two snapshots, the newer one with only `vols`, the older one with
  `vols` plus an extra path, then the reverse → each time the newest
  snapshot that includes `vols` is printed;
  (f) a `sha256sum` shim first on `PATH` that exits 1 for one named live
  file that still exists → `cannot hash live file`; the same shim deleting
  that file before failing → the file is skipped, the volume passes.
  (Permission bits can't produce the failure: the payload runs as root.)
- [ ] **Step 2: Add the env overrides** (`${VAR:-default}`) and run the
  harness. Expected: (a) passes; (b) wrongly "0 tables … ok"; (c) aborts with a
  `date` error; (d2) says "no snapshot for host"; (d3) says "missing from
  snapshot"; (f) passes or aborts. These are the RED results. (e) may already
  pass by luck; it pins the new query.
- [ ] **Step 3: Implement** the four decisions above, one at a time,
  re-running the harness after each. Expected: each case flips to its
  expected line and (a) stays green.
- [ ] **Step 4: Run** `shellcheck -s bash` on the extracted payload and on
  the task. Expected: no new warnings.
- [ ] **Step 5: Commit**
  `fix(db): restore-test names failed checks, rejects empty dumps (#200)`.

### Task 2: Live run on bow

- [ ] **Step 1:** Run `mise db:restore-test --target core@bow`. Expected:
  `restore test: passed`, with the snapshot id equal to the newest from
  `restic snapshots --host bow --path /var/lib/containers/storage/volumes`.
- [ ] **Step 2:** Tick #200's boxes and close it.
