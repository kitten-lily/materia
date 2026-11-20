# silentsuite-release gate: required, clearer errors — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The release check's error tells an API failure apart from "no
release", and the gate is either enforced by GitHub or plainly labelled
advisory.

**Architecture:** `api()` in `.github/scripts/silentsuite-release-check.sh`
records the HTTP status. 404 means "no published release"; anything else
means "release lookup failed (HTTP N)". Enforcement stays advisory (option A, below).

**Tech Stack:** bash, curl, GitHub Actions, GitHub rulesets.

**Spec:** GitHub issue #204 (deferred minors from the #192 final review).
Revised after a Codex review (2026-11-20).

## Global Constraints

- The script must still fail closed on every error. Only the message
  changes.
- `main` has no branch protection or rulesets today (API 404, 2026-11-18).
  Adding one is an outward-facing repo-settings change, made only with the
  user's go-ahead.

## Decision

- **A (chosen by the user, 2026-11-20): say "advisory" plainly.**
  - Reword the `renovate.json5` comment and the workflow header: "red
    `silentsuite-release` on a Renovate PR = do not merge; nothing enforces
    it".
  - Cost: none. It relies on the person merging, who is the only one who
    merges here (automerge is off for this package).
- **B (not chosen): make it required.**
  - Drop the workflow's `paths:` filter and run the check on every PR and
    push. It takes ~10 s and needs no change detection, which avoids
    `origin/main...HEAD` being empty on a push to main.
  - Add a ruleset on `main` requiring the check by its emitted name, which
    is the job name: "silentsuite image is a published, digest-matching
    release". Check existing rulesets first with
    `gh api repos/{owner}/{repo}/rulesets` (branch protection's 404 doesn't
    rule them out).
  - Cost: a check on every PR (~10 s). Every other push to `main` must also
    go through a PR, or the ruleset needs a bypass for the owner, and
    today's direct pushes to `main` rely on that bypass.

## Review Focus

1. **Rate limit (403), 5xx, DNS failure or timeout.** Expected:
   `release lookup failed (HTTP 403)` (or "no HTTP response") and exit 1.
2. **Draft release.** Expected: 404, "no published release", as today.
3. **Asset download failure** (the second curl). Expected: its own
   "server-image.json download failed (HTTP N)" and exit 1.

---

### Task 1: Distinguish 404 from lookup failure

**Files:** Modify `.github/scripts/silentsuite-release-check.sh`

- [ ] **Step 1: Failing test.** Run
  `GITHUB_TOKEN=bad .github/scripts/silentsuite-release-check.sh components/silentsuite/silentsuite.container.gotmpl`.
  Expected now: `has no published release` for a 401 (RED).
- [ ] **Step 2: Implement.**
  - `api()` writes the body to a temp file and prints the status via
    `curl -sS -L -w '%{http_code}' -o "$tmp"`, without `-f`. It keeps
    `--retry 3` and `--max-time 30`, and adds `--retry-all-errors` so 5xx
    responses are retried. A curl transport failure (DNS, timeout) is
    caught explicitly (`code=$(curl …) || code=000`) so `set -e` can't exit
    without a message; status `000` prints "release lookup failed (no HTTP
    response)". The asset download keeps `-L` for the redirect.
  - Branch: 200 continues; 404 prints the existing message; any other
    status prints `::error::release lookup for $tag failed (HTTP $code)`.
    Do the same for the `server-image.json` download.
- [ ] **Step 3: Verify.**
  - `GITHUB_TOKEN=bad …` gives `lookup … failed (HTTP 401)`, exit 1.
  - With a copy of the quadlet whose tag is changed to `v0.0.0-beta`:
    `has no published release`, exit 1.
  - Transport failure: `HTTPS_PROXY=http://127.0.0.1:9 …` gives
    `failed (no HTTP response)`, exit 1.
  - The real quadlet with the real token, or unauthenticated:
    `ok: v0.5.20-beta …`, exit 0.
  - shellcheck is clean.
- [ ] **Step 4: Commit** `fix(ci): name the failing release lookup (#204)`.

### Task 2: Mark the gate advisory (option A)

- [ ] **Step 1:** Reword the `renovate.json5` silentsuite comment and the
  `silentsuite-release.yml` header to say the check is advisory: a red
  `silentsuite-release` on a Renovate PR means do not merge, and nothing
  enforces it.
- [ ] **Step 2:** Validate `renovate.json5` (as in #202 Task 3). Commit
  `docs(ci): mark silentsuite-release advisory (#204)`.
- [ ] Tick #204's boxes and close it.
