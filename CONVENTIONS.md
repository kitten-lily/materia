# Conventions — Materia Podman Orchestration

> **Read this before any GitHub or git operation.** Project description,
> commands, architecture, locked decisions, and hard-won gotchas live in
> `AGENTS.md` — read it first. This file holds the process and quality rules
> all AI agents must follow.

## Conventions

- **specs/ is your memory.** All planning, investigation, and specification
  output goes to `specs/` at the repo root. State lives in `specs/state.yaml`.
- **Focused semantic commits.** One logical change per commit. Subject ≤50 chars,
  Conventional Commits style (`feat:`, `fix:`, `docs:`, `chore:`). Body only when
  the "why" isn't obvious from the diff.
- **Keep the repo generic.** No real domain names, server IPs, or
  deployment-specific values in tracked files. Those live in `attributes/`
  vaults (SOPS-encrypted), not hardcoded.
- **Pinned image digests.** No `AutoUpdate=registry` — git-pinned GitOps. Renovate
  bumps digests via PRs (`renovate.json5`).
- **`.gotmpl` suffix is stripped on install.** `config.yml.gotmpl` installs as
  `config.yml`.
- **`{{ m_dataDir "pangolin" }}`** expands to `/var/lib/materia/components/pangolin`
  — use it for `Volume=` bind mounts in `.container` files.
- **Systemd unit inline comments are literal values.** Never put `#` after a
  value in a quadlet file — the comment becomes part of the value. Comments go on
  their own lines.
- **Butane changes don't reach a running host.** Ignition runs once at first
  boot. To change a provisioned server, rebuild it or hand-edit on the host and
  mirror the change in the template for next provision.
- **AI sessions update AGENTS.md.** After any session that uncovers a
  non-obvious constraint, fix, or pattern, add it to the Gotchas section and commit.
- **No upstream issues without permission.** Never file issues, PRs, or comments
  in dependency/upstream repos without express user permission.
- **verify: every step.** Every epic task must have `verify: <runnable command>`.
  Evidence over claims.

## Never

- Never dismiss reproducible gate failures as pre-existing or out of scope.
- Never proceed on a red Preflight or red CI — invoke quick-fix or fix-bug first.
- Never put real domain names, server IPs, or secrets in tracked files — use
  `attributes/` vaults.
- Never hand-roll a reconciler, webhook, or seed-secrets service — Materia is the
  single source of truth enforcement.
- Never split Pangolin/Gerbil/Traefik into separate network namespaces — the
  shared pod is an architecturally locked decision (Gerbil's CGNAT tunnel IPs
  must be reachable from Traefik).
- Never mask docker/containerd services to disable them — use the `/dev/null`
  sysext symlink trick (flatcar/Flatcar#1481).
- Never file upstream issues/PRs without user permission.
- Never put `#` inline after a value in a quadlet file.

## Defensive Code

This is infrastructure-as-code, not a request-serving application. The defensive
concerns that apply are about reconciliation and provisioning resilience, not
traffic handling:

- **Retry:** `materia-update.timer` fires daily and ~2min after boot. A failed
  run retries on the next timer tick automatically — no manual intervention for
  transient failures.
- **Timeout:** systemd unit timeouts bound materia-update runs; healthcheck ping
  timeouts are bounded; the healthchecks.io check has a grace window sized for
  the daily cadence.
- **Graceful degradation:** Healthcheck ping failures never block the materia
  update — the systemd `-` prefix on ping commands means a failed ping is
  non-fatal. A silently-failing or stopped timer gets noticed via the check, but
  the update itself is never blocked by observability.

Rate limiting and circuit breaking do not apply — there is no inbound request
load to manage.

## Always Green / Shift Left

**Rationale (1-10-100):** a defect caught at render costs 1, caught at provision
costs 10, caught on a running production edge node costs 100.

**Preflight green** = `mise clean && mise ign --server-name <name>` renders
without error AND `git status` shows only intended changes (no leaked secret
material, no stray `.ign` files committed).

**CI green** = `gh pr checks` passes for an open PR.

Never proceed on red Preflight or red CI. Reproducible gate failures require
**fix-or-log**: invoke `quick-fix` for trivial data-only fixes, or `fix-bug` for
anything needing investigation. Fixes discovered during forward work go in a
**separate commit** from the feature work.

## Discovered Defects

When a gate fails or a defect is found during work:

1. **quick-fix** — trivial data-only fixes (no logic risk). Falls back to
   `fix-bug` if guardrails trip.
2. **fix-bug** — investigates root cause, writes a TDD-based fix plan to
   `specs/bugs/BUG-*.md`, then validates the fix.
3. **Separate commit.** A discovered fix is never bundled into the feature commit
   that exposed it. One logical change per commit.

## Banned Dismissive Phrases

Never use these to wave away a red gate or a failing check:

| Phrase | Why it's banned |
|--------|-----------------|
| "pre-existing" | Dismisses a reproducible failure without investigation. |
| "unrelated to this session" | A red gate is never out of scope — it blocks forward work. |
| "not introduced by my changes" | If it's red, it needs fix-or-log, regardless of origin. |
| "out of scope" | Used to ignore a gate failure. Not a valid response to red Preflight/CI. |

## Agent Rules

- **Workflow Mandate:** You MUST use the bigpowers skills (e.g. `plan-work`,
  `develop-tdd`, `orchestrate-project`) to perform tasks. DO NOT write changes
  directly in response to a user prompt like "add this server" or "change this
  config" without planning first.
- **Always Green:** Preflight and CI must be green before forward work.
  Reproducible gate failures require fix-or-log per § Discovered Defects.
- **Read AGENTS.md before writing code.** It holds the locked architecture
  decisions and gotchas. Touching quadlets, pod configs, or provisioning without
  reading it will break things in subtle ways.
- **Read specs/ before writing code.** Check `specs/state.yaml` for active
  flow/epic, `specs/release-plan.yaml` for planned work.
- **All planning and specifications MUST be written to `specs/`**
  (`product/SCOPE_LATEST.yaml`, `release-plan.yaml`, `epics/`) before any IaC
  change is generated.
- **Write the minimum change that solves the stated problem.** Nothing extra.
- **Run Preflight after every change.** Show evidence before declaring done.
- **One clarifying question beats a wrong assumption baked into a quadlet.**
