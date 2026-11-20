# DB tooling: per-DB database name, image-pin parity check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `db:backup` stops assuming the Postgres DB name equals the user
name, its `--compare` path fails clearly on a missing image, and CI
rejects a db-dump quadlet whose `Image=` differs from its server's.

**Architecture:** One more `DBS` field in `.mise/tasks/db/backup`. A new
`mise check:db-dump-images` task does the parity check. It derives each
pair from the dump quadlet's own `After=<server>.service` line, so there is
no hand-kept map. A preflight job runs the same logic, inline as the
known_hosts job does.

**Tech Stack:** bash, GitHub Actions.

**Spec:** GitHub issue #201 (deferred minors from the #194 final review).
Revised after a Codex review (2026-11-20).

## Global Constraints

- The `DBS` row becomes
  `name|kind|container|db service|app service|secret|volume|db user|db name|server quadlet`.
  The `db name` values today: `grimmory` (unused, mariadb dumps
  `--all-databases`), `mediamanager`, `silentsuite`, `pinepods`.
- Parity rule: for each `components/db-dump/db-dump-*.container.gotmpl`,
  take its `After=` units minus `network-online.target`. Exactly one must
  name a `.service` whose quadlet is `components/*/<unit>.container.gotmpl`.
  The `Image=` lines must be byte-identical. Zero or more than one match is
  an error, not a skip.
- Output style follows `check:known-hosts`: `::error::` lines in CI and
  exit 1.

## Review Focus

1. **A new dump quadlet without `After=`** (copy-paste mistake). Expected:
   the check fails with "no server unit in After=", rather than passing
   silently.
2. **Renovate bumping only one of the pair** (e.g. a package rule split).
   Expected: the preflight check fails on the PR.
3. **`--compare` on a host where a quadlet is missing.** Expected:
   `FAIL <name>: no Image= in <quadlet>`, with that DB skipped and rc 1, not
   a podman error.

---

### Task 1: `db:backup` database-name field and `--compare` image guard

**Files:** Modify `.mise/tasks/db/backup`

- [ ] **Step 1: Failing test with user != database.** A scratchpad
  harness runs the extracted payload's `counts`/`dump` functions (sourced
  from a copy of the payload with the top-level code cut after the function
  definitions) against a local throwaway postgres on the pinned image with
  `POSTGRES_USER=u POSTGRES_DB=appdb` and one table holding 3 rows. Expected
  now: `counts` fails (`database "u" does not exist`) — RED.
- [ ] **Step 2: Implement.**
  - Add the `db name` field to every row and to both `read` lines.
  - Pass `db` to `counts`/`dump`. `pg_dumpall` takes `-l "$db"` as its
    initial database, and `psql` takes `-d "$db"`.
  - In `--compare`, guard both failures, since `set -e`/`pipefail` would
    otherwise exit inside the command substitution on a missing file:
    `[[ -r $quadlet ]] || { echo "    FAIL  $name: $quadlet missing"; rc=1; continue; }`,
    then `img=$(image_of "$quadlet")` and
    `[[ -n $img ]] || { echo "    FAIL  $name: no Image= in $quadlet"; rc=1; continue; }`.
    Apply the same readable-file guard on the backup path.
- [ ] **Step 3: Verify.** The Step 1 harness now reports `public.t	3`.
  The harness also runs the `--compare` guard snippet against a missing
  quadlet path and against a quadlet with no `Image=`: each prints its own
  FAIL line and the loop continues. `bash -n` is clean. Live, run `mise db:backup --target core@bow --compare <latest
  /var/lib/db-backups dir>`. Expected: `ok` for all four DBs. That run
  re-counts only; it doesn't stop services.
- [ ] **Step 4: Commit** `fix(db): backup takes a per-DB database name (#201)`.

### Task 2: `check:db-dump-images` + preflight job

**Files:**
- Create: `.mise/tasks/check/db-dump-images`
- Modify: `.github/workflows/preflight.yml` (new job `db-dump-image-parity`)
- Modify: `AGENTS.md` (task list entry)

- [ ] **Step 1: Write the check, run it on a deliberately broken tree.** In
  a scratch copy of the repo, change one hex digit of
  `db-dump-pinepods.container.gotmpl`'s digest. Run the task there.
  Expected: exit 1 and
  `::error::db-dump-pinepods: Image= differs from pinepods-postgres`. In a
  second copy, delete that file's `After=` line. Expected: exit 1 and
  "no server unit in After=".
- [ ] **Step 2: Run on the real tree.** Expected: `OK — 4 db-dump quadlets
  match their servers`, exit 0.
- [ ] **Step 3: Preflight job.** The job runs
  `bash .mise/tasks/check/db-dump-images` directly (it uses only bash, grep
  and sed, so CI needs no mise), with no inline copy to drift. Push a
  branch. Expected: the job is green.
- [ ] **Step 4: Commit** `ci: check db-dump image pins match servers (#201)`.
- [ ] **Step 5:** Tick #201's boxes and close it.
