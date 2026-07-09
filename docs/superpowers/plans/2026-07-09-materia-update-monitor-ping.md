# Materia-Update Monitor Ping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a healthchecks.io-style dead-man's-switch ping (start / success / fail) to the `materia-update` timer-driven service, so a silently-failing or silently-stopped update timer gets noticed. Closes [kitten-lily/materia#3](https://github.com/kitten-lily/materia/issues/3).

**Architecture:** The `materia-update.container` quadlet is inlined in `provisioning/templates/hetzner.bu` (Butane → Ignition), not a Materia component — Materia can't monitor the thing that runs Materia, so the ping URL cannot be a vault attribute. Instead it rides the existing transpile-time substitution path (Proton Pass → fnox → `mise ign` sed → Butane): one new secret (`HC_PING_URL`, the slug-mode base URL `https://hc-ping.com/<ping-key>`) plus a per-server slug derived from the already-substituted `${SERVER_NAME}`. The pings themselves are two `[Service]` lines on the quadlet: `ExecStartPre=` curls `<base>/materia-update-<server>/start`, and `ExecStopPost=` curls the bare URL (success) or `/fail`, branching on systemd's `$EXIT_STATUS`.

**Tech Stack:** Butane/Ignition (Flatcar), systemd quadlets (podman), curl (ships with Flatcar), fnox + Proton Pass, mise file tasks, healthchecks.io slug-mode pings.

## Global Constraints

- Pings must NEVER fail or block the update itself: every ping Exec line carries systemd's `-` failure-tolerance prefix, and curl gets `-m 10 --retry 5` (healthchecks.io's documented incantation) so a down monitoring endpoint costs at most a bounded delay.
- Ping-URL slug convention is `<unit-name>-<server-name>` (here: `materia-update-flutterina`). Issue #2's `restic-backup` component must use the same convention (`restic-backup-<host>`) when it lands — do not invent a second scheme.
- `HC_PING_URL` is a secret (anyone holding it can spoof pings). It is fetched at transpile time only; it must never be committed. Rendered `.ign` files are already gitignored (`*.ign`) and must stay uncommitted.
- In the `.bu` template, `$$` is systemd escaping (literal `$` for the exec'd shell) — the `mise ign` sed only touches `${SERVER_NAME}`-style placeholders explicitly listed in the script, so `$$EXIT_STATUS` / `$$url` pass through untouched. Do not "fix" them to single `$`.
- Butane changes don't reach the running host (Ignition runs once, at first boot — see AGENTS.md "Butane changes don't reach a running host"). Task 4's rollout (hand-edit on host + mirror in template) is part of shipping, not optional.
- The healthchecks.io check's period/grace must be sized for the **daily** `OnCalendar` cadence (period 1 day, grace ~6 h). The `OnBootSec=2min` boot runs (e8682d6) produce extra start/success cycles — slug checks tolerate early/extra pings, but do NOT tighten the period to try to catch a missed boot run.
- Only `provisioning/templates/hetzner.bu` exists on `main` today. If a `bare-metal.bu` template exists by execution time (AGENTS.md already describes one), apply the identical `[Service]` change there too.

---

### Task 1: Secret plumbing — `HC_PING_URL` through fnox and `mise ign`

**Files:**
- Modify: `fnox.toml`
- Modify: `.mise/tasks/ign`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a `${HC_PING_URL}` placeholder that `mise ign` substitutes into any template that uses it. Task 2's template edit relies on exactly this placeholder name. The Proton Pass item is `healthchecks`, field `ping-url` (created by a human in Task 4 — rendering will fail with a clear error until then, which is the same failure mode the existing `CORE_SSH_PUBKEY` has).

- [ ] **Step 1: Add the secret mapping to `fnox.toml`**

Append to the `[secrets]` table (after the `AGE_SECRET_KEY` line):

```toml
HC_PING_URL = { provider = "protonpass", value = "healthchecks/ping-url" }
```

And extend the prereq comment block at the top of the file with a 5th item, after the age-key item:

```toml
#   5. Create a "healthchecks" item with a field named "ping-url" containing
#      the slug-mode base ping URL (https://hc-ping.com/<ping-key> — project
#      ping key, NO trailing slash, no slug). Per-server slugs are derived
#      from the server name at transpile time (materia-update-<server>).
```

- [ ] **Step 2: Fetch and substitute it in `.mise/tasks/ign`**

In `.mise/tasks/ign`, after the `CORE_SSH_PUBKEY` fetch block (currently ends around line 75 with its `fi`), add:

```bash
# Fetch the healthchecks slug-mode base ping URL (https://hc-ping.com/<ping-key>)
# — substituted into the materia-update quadlet's dead-man's-switch pings.
_hc_ping_url=$(fnox get HC_PING_URL)
if [[ -z "$_hc_ping_url" ]]; then
  echo "error: healthchecks/ping-url not set in Proton Pass — create the item first (see fnox.toml)" >&2
  exit 1
fi
```

In the `sed` invocation near the bottom, add one expression alongside the existing ones (URLs contain `/` and `?` but not `|`, so the existing `|` delimiter stays safe):

```bash
  -e "s|\${HC_PING_URL}|${_hc_ping_url}|g" \
```

- [ ] **Step 3: Syntax-check the task script**

Run: `bash -n .mise/tasks/ign`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add fnox.toml .mise/tasks/ign
git commit -m "feat: plumb HC_PING_URL secret through fnox + mise ign (#3)"
```

---

### Task 2: Ping wiring in the `materia-update` quadlet (`hetzner.bu`)

**Files:**
- Modify: `provisioning/templates/hetzner.bu` (header comment ~lines 8–19; `materia-update.container` `[Service]` section, currently lines 121–122)

**Interfaces:**
- Consumes: the `${HC_PING_URL}` placeholder from Task 1 (exact name), plus the pre-existing `${SERVER_NAME}` substitution.
- Produces: the on-host `[Service]` lines that Task 4's hand-edit rollout copies verbatim (with real values) to `/etc/containers/systemd/materia-update.container`.

- [ ] **Step 1: Document the new substitution in the template header**

In the header comment's "Substituted at transpile time" list, after the `${GHOSTTY_TERMINFO_B64}` bullet, add:

```yaml
#   - ${HC_PING_URL} → healthchecks slug-mode base URL for the
#     materia-update dead-man's-switch pings (slug: materia-update-<server>)
```

- [ ] **Step 2: Add the ping Exec lines to the quadlet's `[Service]` section**

Change the `[Service]` section of the inlined `/etc/containers/systemd/materia-update.container` from:

```ini
          [Service]
          Type=oneshot
```

to:

```ini
          [Service]
          Type=oneshot
          # Dead-man's-switch pings (healthchecks.io slug mode). Leading "-"
          # keeps a down monitoring endpoint from blocking or failing the
          # update itself. $$ is systemd escaping — the shell sees $EXIT_STATUS.
          ExecStartPre=-/usr/bin/curl -fsS -m 10 --retry 5 -o /dev/null ${HC_PING_URL}/materia-update-${SERVER_NAME}/start
          ExecStopPost=-/usr/bin/bash -c 'url="${HC_PING_URL}/materia-update-${SERVER_NAME}"; [ "$$EXIT_STATUS" = "0" ] || url="$$url/fail"; curl -fsS -m 10 --retry 5 -o /dev/null "$$url"'
```

Notes locked in by this step (do not deviate):
- `ExecStartPre`/`ExecStopPost` in a quadlet `[Service]` section pass through to the generated service unchanged; quadlet's own generated `ExecStopPost` (container cleanup) coexists fine — systemd runs all of them, and `$EXIT_STATUS` reflects the main `podman run` process (materia's exit code), not other StopPost commands.
- `${HC_PING_URL}` and `${SERVER_NAME}` become literal values at transpile time (sed), so systemd never sees those as variables. Only `$$EXIT_STATUS`/`$$url` are systemd-escaped for the shell.
- No `$(...)` command substitution in the Exec line — systemd's `$`-expansion rules make it fragile; the `url=…; [ … ] || url=…; curl "$url"` form avoids it.
- The unit already has `Wants=/After=network-online.target`, which covers the pings too.

- [ ] **Step 3: Verify the template renders under `butane --strict`**

Preferred (needs Proton Pass auth + the Task 4 item already created):

Run: `mise ign --server-name flutterina`
Expected: `wrote provisioning/servers/flutterina/materia.ign — SECRET: ...`

Fallback without secrets (dummy substitution mirroring the `ign` task's sed):

```bash
tmp=$(mktemp -d)
echo "AGE-SECRET-KEY-DUMMY" > "$tmp/key.txt"
sed \
  -e 's|${SERVER_NAME}|testsrv|g' \
  -e 's|${REPO_URL}|https://example.com/repo.git|g' \
  -e 's|${CORE_SSH_PUBKEY}|ssh-ed25519 AAAAtest test|g' \
  -e "s|\${GHOSTTY_TERMINFO_B64}|$(tr -d '\n' < provisioning/ghostty.terminfo.b64)|g" \
  -e 's|${HC_PING_URL}|https://hc-ping.com/dummykey|g' \
  provisioning/templates/hetzner.bu > "$tmp/hetzner.bu"
grep -q '\$\$EXIT_STATUS' "$tmp/hetzner.bu" && echo ESCAPES-OK   # sed must not have eaten the $$ systemd escapes
butane --strict --files-dir "$tmp" "$tmp/hetzner.bu" > /dev/null && echo BUTANE-OK
rm -rf "$tmp"
```

Expected: `ESCAPES-OK`, then `BUTANE-OK`. Do not commit any `.ign` output.

- [ ] **Step 4: Commit**

```bash
git add provisioning/templates/hetzner.bu
git commit -m "feat: dead-man's-switch pings on materia-update service (#3)"
```

---

### Task 3: Documentation — AGENTS.md

**Files:**
- Modify: `AGENTS.md` ("What every template installs" → the "Materia quadlet" bullet, ~line 273)

**Interfaces:**
- Consumes: the slug convention and substitution name fixed in Tasks 1–2.
- Produces: nothing downstream; keeps AGENTS.md's provisioning description truthful.

- [ ] **Step 1: Extend the Materia-quadlet bullet**

In the "Materia quadlet" bullet of "What every template installs", after the sentence ending "for faster syncs, trigger externally.", append:

```markdown
  The service pings a healthchecks.io-style check (slug
  `materia-update-<server>`, base URL substituted at transpile time via
  `${HC_PING_URL}` from Proton Pass) on start and on success/failure, so a
  silently-failing or stopped timer gets noticed. Ping failures never block
  the update (systemd `-` prefix). Size the check for the daily cadence
  (period 1 day, grace ~6 h) — boot-time runs add extra, harmless ping cycles.
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: describe materia-update monitor ping in AGENTS.md (#3)"
```

---

### Task 4: Provider setup + rollout to the running host (human-in-the-loop)

**Files:** none in this repo (Proton Pass item, healthchecks.io check, and the live host's `/etc/containers/systemd/materia-update.container`).

**Interfaces:**
- Consumes: the exact Exec lines from Task 2 Step 2 and the secret item shape from Task 1 Step 1.
- Produces: a live, alerting check. This task is what actually closes #3 — the repo changes alone monitor nothing (Ignition only runs at first boot).

These steps need credentials/UI access only a human has; an agent executing this plan should stop here and hand these off as a checklist.

- [ ] **Step 1: Create the healthchecks.io check**

In the healthchecks.io project: New Check → slug `materia-update-flutterina`, Period **1 day**, Grace **6 hours**. Confirm the project's ping key; the slug-mode URL is `https://hc-ping.com/<ping-key>/materia-update-flutterina`. Wire the desired alert channel (email/etc.) to the check.

- [ ] **Step 2: Create the Proton Pass item**

In the `materia` vault: item named `healthchecks`, custom field `ping-url` = `https://hc-ping.com/<ping-key>` (no trailing slash, no slug). Verify from the workstation:

Run: `fnox get HC_PING_URL`
Expected: prints the base URL.

- [ ] **Step 3: Verify the full render**

Run: `mise ign --server-name flutterina`
Expected: `wrote provisioning/servers/flutterina/materia.ign — SECRET: ...` (never commit it).

- [ ] **Step 4: Hand-edit the running host (flutterina)**

Ignition won't re-run, so mirror Task 2's change live. Over SSH (`mise server:ssh --server-name flutterina` or plain ssh as `core`), edit `/etc/containers/systemd/materia-update.container` as root: add the same two Exec lines to `[Service]`, but with the real values substituted — `${HC_PING_URL}/materia-update-${SERVER_NAME}` becomes `https://hc-ping.com/<ping-key>/materia-update-flutterina`, and `$$` stays `$$` (it's still a systemd unit file being escaped for the shell). Then:

```bash
sudo systemctl daemon-reload
systemctl cat materia-update.service | grep -A1 ExecStartPre   # confirm quadlet regenerated with the pings
```

- [ ] **Step 5: Prove the success path end-to-end**

```bash
sudo systemctl start materia-update.service
```

Expected: the healthchecks.io check shows a **start** event followed by a **success** ping; check status goes/stays green. Also `systemctl status materia-update.service` shows the service succeeded as before (pings didn't break it).

- [ ] **Step 6: Prove the alert path**

Send a manual fail ping to confirm the alert channel fires:

```bash
curl -fsS "https://hc-ping.com/<ping-key>/materia-update-flutterina/fail"
```

Expected: check flips to red and the configured notification arrives. Then either wait for the next scheduled run or `sudo systemctl start materia-update.service` again to clear it back to green.

- [ ] **Step 7: Land the branch**

Merge the PR containing Tasks 1–3. From then on, any rebuild (`mise hz:rebuild --server-name flutterina`) provisions the pings from the template, matching what the host now runs.
