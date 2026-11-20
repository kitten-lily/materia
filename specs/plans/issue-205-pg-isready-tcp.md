# Postgres sidecars: probe readiness over TCP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Notify=healthy` on every Postgres sidecar fires only once the
real server accepts TCP connections, never during the entrypoint's
socket-only init server.

**Architecture:** One-line `HealthCmd` change in three quadlets. Proven
first with a local fresh-volume race test, pre-checked read-only on bow,
then deployed by materia (each change restarts that postgres and its app).

**Tech Stack:** podman quadlets, official `postgres` images (16.16-alpine,
18.x).

**Spec:** GitHub issue #205 (found in the #192 final review).
Revised after a Codex review (2026-11-20).

## Global Constraints

- Command: `pg_isready -h 127.0.0.1 -U <user> -d <db>`; user and db stay
  as today (`silentsuite`, `mediamanager`, `pinepods`).
- String form is fine (no quoted arguments, so the podman 5.7.1 quote loss
  in AGENTS.md does not apply). No other health settings change.
- A failing health probe with `Notify=healthy` aborts bow's whole
  materia run, and a stuck start job also blocks the fix (AGENTS.md). So the
  bow pre-check in Task 2 is mandatory before the push.

## Review Focus

1. **Server listens only on the socket in production.** The official
   image sets `listen_addresses='*'` after init. If an `Exec=`/config override
   ever narrowed it, the TCP probe would never pass. Expected: Task 2 checks
   this on bow for all three servers.
2. **IPv6-only loopback.** `127.0.0.1` is used, not `localhost`, so a
   `::1`-first resolver can't change what is probed. Expected: the literal
   is in all three quadlets.
3. **The dependent app's restart.** A postgres restart also restarts its
   app (`Requires=`). Expected: after deploy, every app is `active` and
   healthy, and its Pangolin target is healthy too.

---

### Task 1: Reproduce the race locally, then fix all three quadlets

**Files:**
- Modify: `components/silentsuite/silentsuite-postgres.container.gotmpl:22`
- Modify: `components/mediamanager/mediamanager-postgres.container.gotmpl:41`
- Modify: `components/pinepods/pinepods-postgres.container.gotmpl:33`
- Test: scratchpad `pg-ready-race.sh` (not committed; results go in this plan)

- [ ] **Step 1: Write the race test, deterministic.** For each image
  (`postgres:16.16-alpine@…` and the 18.x pin), start it on a fresh
  anonymous volume with `POSTGRES_USER=t POSTGRES_DB=t POSTGRES_PASSWORD=t`
  and a test-only `/docker-entrypoint-initdb.d/hold.sh` that creates
  `/tmp/held` and then waits until `/tmp/release` exists. Init scripts run
  while the temporary server is up, so the hold freezes exactly the window
  in question. Wait for `/tmp/held`, then assert:
  - (a) `pg_isready -U t -d t` exits 0 (the socket probe passes: the bug);
  - (b) `pg_isready -h 127.0.0.1 -U t -d t` exits non-zero.

  Then `touch /tmp/release`, wait up to 60 s, and assert (c) the TCP probe
  exits 0.

  Remove the containers with `podman rm -f -v` (VOLUME leak, AGENTS.md).
- [ ] **Step 2: Run it.** Expected: (a), (b) and (c) hold for both images.
  (a) is the RED evidence that today's probe passes during init, and (b)
  shows the new probe doesn't. If (a) or (b) fails, stop: the issue's
  premise is wrong for that image, so record it in the issue and rethink.
- [ ] **Step 3: Change the three `HealthCmd=` lines** to
  `pg_isready -h 127.0.0.1 -U <user> -d <db>`. Reword or add the comment
  above each so it says why TCP is used.
- [ ] **Step 4: Verify.** Run
  `grep -n '^HealthCmd=pg_isready -h 127.0.0.1' components/*/*-postgres.container.gotmpl`.
  Expected: 3 lines. Run the same grep without `-h 127.0.0.1`.
  Expected: no line lacks it.
- [ ] **Step 5: Commit** `fix(postgres): probe readiness over TCP (#205)`.

### Task 2: Pre-check on bow, deploy, verify

- [ ] **Step 1: Read-only pre-check**, before pushing. For each of
  `silentsuite-postgres`, `mediamanager-postgres` and `pinepods-postgres`,
  run `sudo podman exec <ctr> pg_isready -h 127.0.0.1 -U <user> -d <user>; echo rc=$?`.
  Expected: `accepting connections`, `rc=0` for all three. Any other result
  stops the deploy.
- [ ] **Step 2: Push and run materia** on bow:
  `sudo systemctl start materia-update.service`.
- [ ] **Step 3: Verify.**
  - `journalctl -u materia-update.service --since -10min -o cat | grep -E 'FATA|steps completed'`
    Expected: no `FATA`.
  - For each postgres, `podman inspect <ctr> -f '{{json .Config.Healthcheck.Test}}'`
    shows the `-h 127.0.0.1` form and the container is `healthy`.
  - `silentsuite`, `mediamanager` and `pinepods` are `active`.
  - Pangolin reports each target healthy.
- [ ] **Step 4:** Tick the issue's box and close #205 with the race-test
  numbers.
