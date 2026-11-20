# db-dump hardening (atomic set, boot ordering, SIGTERM) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three small gaps left by #194: a half-renamed dump set
that still looks fresh, a boot-time catch-up run that races the network
and MariaDB, and a comment that is wrong about SIGTERM.

**Architecture:**
- `dump.bash` removes `<name>.done` before its renames.
- The trigger orders after `network-online.target`.
- `grimmory-mariadb` gets the image's own `healthcheck.sh --connect` plus
  `Notify=healthy`, so `After=grimmory-mariadb.service` means "accepting
  connections".
- The SIGTERM comment is corrected, with no `--init`.

**Tech Stack:** bash, podman quadlets, official `mariadb:12.3.3`.

**Spec:** GitHub issue #199 (deferred minors from the #194 final review).
Revised after a Codex review (2026-11-20).

## Global Constraints

- `dump.bash` keeps its interface: env `DB_KIND/DB_HOST/DB_NAME/DB_USER`,
  and output files `<name>.{sql,counts.pre,counts.post,done}` in `/dumps`.
- `db-dump` has `NoRestart = true`, so these changes apply at the next
  23:30 run. grimmory-mariadb *does* restart (its `RestartedBy`), and that
  restart takes the grimmory app down with it briefly.
- HealthCmd uses the JSON-array form (podman 5.7.1 quote loss, AGENTS.md).
- A health probe that never passes plus `Notify=healthy` aborts bow's
  whole materia run (AGENTS.md). Pre-check on bow before pushing Task 2.

## Decisions

- **SIGTERM: fix the comment, no `PodmanArgs=--init`.** The next run
  already deletes stale `.tmp` files, and restores ignore them. `--init` would
  change PID 1 in every dump container for no observable gain.
- **`healthcheck.sh --connect` only, not `--innodb_initialized`.** `--connect`
  connects over TCP to `localhost` and counts *access denied* as success
  (verified in the image's `healthcheck.sh`, 2026-11-20). So it needs no
  credentials. bow's datadir was initialised by minimus and has no
  `healthcheck@localhost` user or `.my-healthcheck.cnf`, which
  `--innodb_initialized` would need. The entrypoint's init server runs with
  `--skip-networking`, so `--connect` cannot pass during init either. That
  is the #205 race, avoided by construction.

## Review Focus

1. **Kill between `rm .done` and the last `mv`.** Expected: no `.done`, so
   `db:restore-test` flunks "`<name>.done` missing" instead of passing a
   mixed set.
2. **First run on a host with no previous set.** Expected: `rm -f` of a
   missing `.done` is a no-op; the run succeeds.
3. **`healthcheck.sh` on bow's real datadir.** Expected: the Task 2
   pre-check shows rc 0 against the live server before anything is pushed.
4. **Boot without network.** Expected: the trigger waits for
   `network-online.target`; the curl pings use `--retry 5` as today.

---

### Task 1: Atomic dump set and the SIGTERM comment

**Files:**
- Modify: `components/db-dump/dump.bash`
- Test: scratchpad `dump-atomic.sh` (local podman, not committed)

- [ ] **Step 1: Write the failing test.**
  - Run a local `postgres:16.16-alpine` server (a throwaway network and a
    password secret) with `dump.bash` mounted into a second container, as the
    quadlet does.
  - Run 1 completes and records `.done`'s mtime.
  - Run 2 is killed between the `.sql` rename and the `.counts.post` rename.
    To hit that window deterministically, use a copy of the script with
    `kill -9 $$` inserted after `mv "$out.sql.tmp" "$out.sql"`.
  - Assert unconditionally that `<name>.done` is absent after the killed
    run. Between runs, insert a marker row so the two generations' `.sql`
    differ, and assert the surviving `.sql` is run 2's (the kill point is
    after its rename).
- [ ] **Step 2: Run it.** Expected: FAIL. Last night's `.done` sits next to
  the new `.sql`.
- [ ] **Step 3: Implement.** Add `rm -f "$out.done"` immediately before the
  first `mv`. Correct the header ("a failed or killed run leaves the previous
  set untouched") to say a run killed during the renames leaves no `.done`.
  Reword the cleanup comment to say: "SIGTERM as well as SIGKILL: bash is
  PID 1 (the entrypoints `exec`), ignores SIGTERM, and `podman stop` kills it
  after 10 s, so the EXIT trap may not run; the next run cleans up".
- [ ] **Step 4: Run the test again**, plus an uninterrupted run. Expected:
  PASS; the uninterrupted run writes all four files and prints `dumped …`.
- [ ] **Step 5: Commit** `fix(db-dump): drop .done before renaming a set (#199)`.

### Task 2: Boot ordering (trigger + grimmory-mariadb health)

**Files:**
- Modify: `components/db-dump/db-dump-trigger.service.gotmpl` ([Unit]:
  `Wants=network-online.target`, `After=network-online.target`)
- Modify: `components/grimmory/grimmory-mariadb.container.gotmpl`. Add
  `Notify=healthy`, `HealthCmd=["healthcheck.sh","--connect"]`,
  `HealthInterval=10s`, `HealthRetries=12`, `HealthStartPeriod=30s`, and in
  [Service] `TimeoutStartSec=300`. Add a comment explaining why
  `--connect` only.

- [ ] **Step 1: Local test of the probe on a datadir like bow's.**
  - Initialise a mariadb:12.3.3 volume and delete
    `/var/lib/mysql/.my-healthcheck.cnf` plus the `healthcheck@%`/`@localhost`
    users. This mimics a datadir with no healthcheck credentials.
  - Restart the server on that volume and poll
    `podman exec <ctr> healthcheck.sh --connect` from container start.
  - Expected: non-zero until the server listens, then 0. Also run a fresh
    volume and confirm it is non-zero throughout the init phase.
  - Clean up with `podman rm -f -v`.
- [ ] **Step 2: Local quadlet render check.** Run
  `/usr/libexec/podman/quadlet -dryrun` on the rendered `grimmory-mariadb.container`.
  The materia template has only `secretEnv`, so substitute those lines
  by hand. Expected: `--health-cmd '["healthcheck.sh","--connect"]'` and
  `--sdnotify=healthy`.
- [ ] **Step 3: bow pre-check (read-only).** Run
  `sudo podman exec grimmory-mariadb healthcheck.sh --connect; echo rc=$?`.
  Expected: `rc=0`. Anything else stops the deploy.
- [ ] **Step 4: Commit**
  `fix(db-dump): order dumps after network and MariaDB health (#199)`.
- [ ] **Step 5: Push, run materia on bow, and verify.**
  - No `FATA` in the run.
  - `podman inspect grimmory-mariadb -f '{{.State.Health.Status}}'` shows
    `healthy`.
  - `grimmory.service` is active.
  - `systemctl show db-dump-trigger.service -p After` includes
    `network-online.target` once the unit is reloaded.
  - The next morning, `db-dump-trigger` succeeded and all four `.done` files
    carry tonight's time.
- [ ] **Step 6:** Tick #199's boxes and close it.
