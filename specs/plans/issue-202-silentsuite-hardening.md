# silentsuite: config hardening and doc fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the wrong comments, narrow CORS to the one web origin in use,
make `healthcheck.py` changes reach the container, and retire the exposed
bootstrap token without losing a safe way to re-bootstrap.

**Architecture:**
- Quadlet, manifest and ini edits in `components/silentsuite/`.
- The bootstrap token moves behind `{{ if exists }}`, like the
  registration token. It leaves the vault, and comes back only through a
  new `init-secrets --bootstrap` mode that writes and prints a fresh one.
- Docs and AGENTS.md wording.

**Tech Stack:** materia templates, podman, SilentSuite v0.5.20-beta.

**Spec:** GitHub issue #202 (deferred minors from the #192 final review).
Revised after a Codex review (2026-11-20).
**Depends on:** #203. `--bootstrap` reuses its stdin-based `put()`.

## Global Constraints

- Upstream behaviour, read at the pinned tag `v0.5.20-beta` (`server/`,
  2026-11-20; `main` agrees):
  - `CORS_ALLOWED_ORIGINS` is comma-separated (`fastapi/main.py`), with
    `allow_credentials=True`.
  - The bootstrap token is checked only when it is non-empty *and* no
    UserInfo exists (`fastapi/routers/authentication.py:286-287`).
  - `signup_save` calls `check_registration_token` first (`:284`), so with
    it set, signup is closed whatever the bootstrap state.
- **Dangerous state to never create:** registration token unset + bootstrap
  token unset + empty DB. That means open signup for anyone. `--bootstrap`
  and the docs must make that ordering explicit.
- Any change to `silentsuite.container` restarts the server (brief
  outage). Postgres is not touched.

## Decisions

- **CORS origins: `https://app.silentsuite.io` only.** The native Android
  app and bridges don't use CORS; the hosted web app is the only browser
  client in use (confirmed by the user, 2026-11-20).
- **Bootstrap token: remove, don't rotate.** It is inert while the
  registration token is set. Keeping a rotated copy in the vault buys
  nothing until a re-bootstrap, and that is when `--bootstrap` mints one.

## Review Focus

1. **Materia leaves the old podman secret behind.** When the attribute
   disappears, materia may keep `materia-silentsuiteBootstrapToken`.
   Expected: Task 2 checks `podman secret ls` and removes it by hand if it
   is still there.
2. **`exists` guard rendering.** If the guarded block is not removed
   cleanly, a dangling `Secret=` line breaks the unit. Expected: the
   installed quadlet has no `ETEBASE_BOOTSTRAP_ADMIN_TOKEN`, and
   `podman inspect` env lacks it.
3. **CORS preflight from the web app.** Expected: `OPTIONS` with
   `Origin: https://app.silentsuite.io` gets
   `access-control-allow-origin` echoed back. With
   `Origin: http://localhost:3000` that header is absent.
4. **Re-bootstrap ordering.** A vault value changes nothing until materia
   has run and the container was recreated. Expected: `--bootstrap` prints
   this order, and each step names its check:
   1. write the bootstrap token, push, run materia;
   2. verify `podman exec silentsuite printenv ETEBASE_BOOTSTRAP_ADMIN_TOKEN`
      prints it (non-empty);
   3. only then `sops unset` the registration token, push, run materia, and
      verify `printenv ETEBASE_REGISTRATION_TOKEN` is empty;
   4. sign up with `?bootstrap_token=`;
   5. `--close`, push, run materia, and verify the registration token is
      back in the container *and* a header-less signup gets 403.

---

### Task 1: Comments, CORS, RestartedBy (one restart)

**Files:**
- Modify: `components/silentsuite/silentsuite.container.gotmpl`. Fix the
  `Secret=` comment: the secret supplies only `password`; later files win,
  so the templated ini wins on any key both set, and it must never set
  `password`. Fix the `TRUSTED_PROXY_IPS` comment: the range is podman's
  whole named-network pool; the real peer is tailscale-gateway, so any
  tailnet peer granted `:3735` can forge `X-Forwarded-*`; the impact is the
  logged client IP and scheme; keep the grant narrow. Add
  `Environment=CORS_ALLOWED_ORIGINS=https://app.silentsuite.io`.
- Modify: `components/silentsuite/etebase-server.ini.gotmpl`, header
  comment, same merge-order wording.
- Modify: `components/silentsuite/MANIFEST.toml`. `silentsuite.service`
  `RestartedBy` gains `"healthcheck.py"`.

- [ ] **Step 1: Failing check (live, read-only).** Run
  `curl -s -o /dev/null -D- -X OPTIONS -H 'Origin: http://localhost:3000' -H 'Access-Control-Request-Method: GET' https://silentsuite.<baseDomain>/api/v1/authentication/is_etebase/ | grep -i access-control-allow-origin`.
  Expected now: `http://localhost:3000` echoed (RED).
- [ ] **Step 2: Implement** the three file edits.
- [ ] **Step 3: Local check.** Run the pinned image with
  `CORS_ALLOWED_ORIGINS=https://app.silentsuite.io` (local harness from
  #192). Expected: the localhost preflight gets no allow-origin, and the
  app.silentsuite.io preflight gets it echoed.
- [ ] **Step 4: Commit** `fix(silentsuite): narrow CORS, fix config comments (#202)`.
- [ ] **Step 5: Deploy and verify.** Push and run materia on bow. Expected:
  no `FATA`, `silentsuite` healthy, the Step 1 probe now prints nothing,
  and the app.silentsuite.io probe echoes. Log in from the web app to
  confirm it still works.

### Task 2: Retire the bootstrap token; add `init-secrets --bootstrap`

**Files:**
- Modify: `components/silentsuite/silentsuite.container.gotmpl`. Wrap the
  bootstrap `secretEnv` in `{{- if exists "silentsuiteBootstrapToken" }}`.
- Modify: `.mise/tasks/silentsuite/init-secrets`. Add `--bootstrap`, which
  writes only `silentsuiteBootstrapToken`, refuses if it exists, and prints
  the URL plus the safe ordering. The default (first-install) mode is
  unchanged.
- Modify: `components/silentsuite/MANIFEST.toml` header comment.

- [ ] **Step 1: Test `--bootstrap` on a temp vault** (the #203 harness).
  - Expected now: `unknown flag` (RED).
  - After implementing: the key is written and the token is printed once.
  - A second run refuses.
  - The default mode on a vault holding only a bootstrap token refuses
    too, as today.
- [ ] **Step 2: Implement**, then commit
  `feat(silentsuite): guard bootstrap token, add --bootstrap (#202)`.
- [ ] **Step 3: Vault and deploy, in this order.**
  1. Push the guard commit and let materia run, so the quadlet is guarded
     while the attribute still exists. Expected: no change in behaviour.
  2. Run `sops unset attributes/bow.yml '["components"]["silentsuite"]["silentsuiteBootstrapToken"]'`.
     Commit it as `chore(silentsuite): drop the bootstrap token (#202)`,
     push, and run materia.
- [ ] **Step 4: Verify.**
  - The installed quadlet has no `ETEBASE_BOOTSTRAP_ADMIN_TOKEN`.
  - `podman exec silentsuite env | grep -c BOOTSTRAP` gives 0.
  - A signup attempt without the header still gets
    `403 registration_token_required`. Run it only after confirming the ssh
    call succeeded; that is the #192 `closed-probe-user` lesson.
  - `podman secret ls | grep -i bootstrap`. If it is still listed,
    `podman secret rm materia-silentsuiteBootstrapToken` and record which
    behaviour materia showed.

### Task 3: Doc gaps

**Files:**
- `.mise/tasks/db/backup` `#MISE description` (add SilentSuite);
- `AGENTS.md` layout block (`healthcheck.py`; fix the silentsuite
  merge-order line);
- `specs/plans/silentsuite-investigation.md` "Open questions" (strike
  `/data` ownership, resolved: 100:101 on deploy);
- `renovate.json5` silentsuite comment:
  keep "take `mise db:backup --target core@bow` before merging" as the
  rule, and add that the nightly db-dump (#194) is a fallback if it was
  forgotten, not a replacement (automating the step is separate work).

- [ ] **Step 1:** Make the edits. Run `npx --yes -p renovate renovate-config-validator renovate.json5`
  (or the repo's existing validation). Expected: valid.
- [ ] **Step 2: Commit** `docs(silentsuite): fix review doc gaps (#202)`.
- [ ] **Step 3:** Tick #202's boxes and close it.
