# Vault writers: secrets off argv, partial-run recovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No vault-writing task passes a secret value on a command line.
`silentsuite:init-secrets` also tells you how to recover from a run that
died halfway.

**Architecture:** Every `sops set`/`sops --set` call with a secret
argument becomes `printf %s "$v" | jq -Rs . | sops set --value-stdin <vault> <path>`
(sops 3.13.3 supports it; `tailscale/set-auth-key` uses `--value-stdin`
but still feeds jq through argv). Argv-recording `sops`/`jq` shims on
`PATH` prove it per task.

**Tech Stack:** bash, sops 3.13.3, jq.

**Spec:** GitHub issue #203 (deferred minors from the #192 final review).
Revised after a Codex review (2026-11-20).

## Global Constraints

- Call sites in scope:
  - `silentsuite/init-secrets` `put()`;
  - `buildbarn/secret-init:61,64`;
  - `buildbarn/server-cert-init:46`;
  - `hz/storagebox/install-key:75,79`;
  - `tailscale/set-auth-key:57`: it already pipes into `--value-stdin`, but
    builds the JSON with `jq -Rn --arg s "$secret…"`, which puts the secret
    on `jq`'s argv. Change it to `printf %s "…" | jq -Rs .`.

  Goal scope: no secret value on the argv of any process these tasks start
  (sops, jq or otherwise). Values the tasks *receive* as flags or from
  other tools (e.g. `fnox get`) are out of scope.

  `resticRepository` (`:79`) is not secret, but it is converted too, so
  there is one pattern throughout.
- Values stay JSON-encoded with `jq -Rs .` (BUG-003). The bytes stored must
  be identical to today's: same trailing newline handling.
- The tests never touch `attributes/*.yml`. They run against temp vault
  copies created from inside the temp dir, so `.sops.yaml` creation rules
  apply. This was the #192 harness lesson.

## Decisions

- **Partial init-secrets run:** recovery guidance is printed by the
  *rerun*, not only by a trap (a trap can't run after SIGKILL or power
  loss). The precheck classifies the mode's keys as all absent (proceed), all
  present (refuse, as today), or partial. Partial refuses and prints which
  keys exist and which are missing, plus the exact `sops unset` lines for
  the present ones. It also warns: only roll back if the DB password was
  never deployed, i.e. `podman secret ls` on the host has no
  `materia-silentsuiteDbPassword` and the silentsuite-db volume doesn't
  exist; otherwise the missing keys must be derived from the existing
  password, never regenerated. An EXIT trap additionally prints the same
  note immediately on an ordinary failure. No auto-rollback.

## Review Focus

1. **Trailing newline in `silentsuiteDbIni`.** Expected: decrypting it
   gives the same bytes as before (`[database]\npassword = …\n`).
2. **The storagebox private key keeps its final newline** (OpenSSH bug
   #3849, AGENTS.md). Expected: `tail -c1 | xxd` shows `0a` after the round
   trip.
3. **A failure between two `put`s.** Expected: the immediate note and the
   rerun's classification list only the keys that were actually written.

---

### Task 1: argv shim test, then convert all call sites

**Files:**
- Modify: `.mise/tasks/silentsuite/init-secrets`,
  `.mise/tasks/buildbarn/secret-init`,
  `.mise/tasks/buildbarn/server-cert-init`,
  `.mise/tasks/hz/storagebox/install-key`
- Test: scratchpad `argv-shim/sops` plus `argv-test.sh` (not committed)

- [ ] **Step 1: Write the test.**
  - The shim `sops` appends `"$@"` (NUL-separated) to `$ARGV_LOG` and then
    execs the real sops.
  - A `jq` shim logs argv the same way.
  - `silentsuite:init-secrets` takes `--vault`; run it against a temp vault.
    `buildbarn:secret-init` takes `--server-name` and builds
    `attributes/<name>.yml`, so run it from an isolated fixture tree (a temp
    dir with a copied `.sops.yaml`, an empty encrypted
    `attributes/fixture.yml` and the task) with `--server-name fixture`.
  - Decrypt every key written and assert that no *distinctive substring* of
    each value appears in `$ARGV_LOG`: for multi-line keys, a 32-character
    run from the base64 body (raw multi-line text won't match JSON-escaped
    argv, so a whole-value match would pass falsely). Also decode each argv
    element that parses as a JSON string and compare that too.
  - `server-cert-init` and `install-key` need external state (openssl
    output, or hcloud). For those, assert statically that no `sops` line in
    the file has a `${…_json}` argument. Also run a small extracted snippet
    of each write, through the shim, against a temp vault.
- [ ] **Step 2: Run it.** Expected: FAIL. Every value written by `put()`/
  `sops --set` appears in the log.
- [ ] **Step 3: Implement.**
  - `put() { printf %s "$2" | jq -Rs . | sops set --value-stdin "$_vault" "$(path "$1")"; }`
  - Apply the same shape at the other call sites. The path becomes a
    separate argument, not part of a `--set` string.
- [ ] **Step 4: Run again.** Expected: PASS. The round-trip bytes are
  identical to a run of the old version on a second temp vault: `cmp` per
  key, with random values replaced by fixed ones for the comparison through
  a `token()` override in the test copy.
- [ ] **Step 5: Commit** `fix(tasks): pass vault secrets to sops on stdin (#203)`.

### Task 2: init-secrets recovery note

**Files:** Modify `.mise/tasks/silentsuite/init-secrets`

- [ ] **Step 1: Test.** Run against a temp vault with a shim that fails
  the *second* `sops set`. Expected now: the run exits non-zero and prints
  nothing about the key it did write. A rerun says only "already exists".
  Also SIGKILL a run after the first `put` (shim sleeps on the second call)
  and rerun: the same "already exists" (RED).
- [ ] **Step 2: Implement** the three-way precheck and the trap. Keep
  `written=()` and append to it after each `put`. The trap fires on a
  non-zero exit with `written` non-empty, and prints:

  ```
  error: stopped after writing: silentsuiteDbPassword
  roll back with:
    sops unset attributes/bow.yml '["components"]["silentsuite"]["silentsuiteDbPassword"]'
  ```

  followed by the "only if never deployed" warning.
- [ ] **Step 3: Run the tests again.** Expected: the trap note lists
  exactly `silentsuiteDbPassword`; after the SIGKILL case the rerun prints
  `partial: present silentsuiteDbPassword; missing silentsuiteDbIni
  silentsuiteBootstrapToken` with the unset line and warning. Running the
  printed line, then rerunning the task (shim removed), succeeds.
- [ ] **Step 4: Commit**
  `feat(silentsuite): print rollback after a partial init (#203)`.
- [ ] **Step 5:** Tick #203's boxes and close it.
