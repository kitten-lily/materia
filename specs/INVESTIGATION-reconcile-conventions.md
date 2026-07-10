# Investigation: Reconcile AGENTS.md with bigpowers convention structure

**Status:** Investigation complete — recommendation below for review.
**Date:** 2026-07-10
**Branch:** `investigate/reconcile-conventions`

## Context

PR #13 (`chore/seed-bigpowers-conventions`) layered bigpowers conventions onto
this repo by:

1. Creating `CONVENTIONS.md` (bigpowers process/quality layer).
2. Appending three fenced blocks to the existing `AGENTS.md` (`project`,
   `context-routing`, `learned-preferences`) at EOF — preserving all hand-written
   Materia docs above them.
3. Creating `CLAUDE.md` → symlink to `AGENTS.md`.
4. Creating the `specs/` planning scaffold.

This investigation asks: **is the current split between `AGENTS.md` (hand-written)
and `CONVENTIONS.md` + fenced blocks (bigpowers-managed) a good structure, or
should the two be reconciled further?**

## What bigpowers expects

The bigpowers convention structure (from `seed-conventions` REFERENCE.md and the
standard `CONVENTIONS.md` template) prescribes a clear separation of concerns:

| File | Role | Content |
|------|------|---------|
| `AGENTS.md` (→ `CLAUDE.md` symlink) | **Project context** | Project description, Commands table, Architecture, Conventions, Never-do list, Agent Rules. The agent's first read for "what is this project and how do I work in it?" |
| `CONVENTIONS.md` | **Process/quality doctrine** | Conventional Commits, GitHub/git operations, Always Green/Shift Left, Discovered Defects, banned phrases, Code Style, Tests (F.I.R.S.T), specs/ output convention, defensive code, risk tiers. The rules all agents must follow regardless of project. |

The key principle: **`AGENTS.md` describes THIS project; `CONVENTIONS.md`
describes THE METHODOLOGY.** A greenfield bigpowers project gets a fresh
`AGENTS.md` from the Reach Template with project-specific values filled in, and a
`CONVENTIONS.md` that's mostly the standard doctrine with project defensive-code
categories slotted in.

## What this repo has

This repo is not greenfield. It came with a 407-line hand-written `AGENTS.md`
that is rich, domain-specific, and hard-won — Materia concepts, locked
architecture decisions, gotchas, provisioning runbook, multi-server model. This
is far more than the bigpowers `AGENTS.md` template expects (which is ~40 lines:
project, commands, architecture, conventions, never, agent rules).

After PR #13, the structure is:

```
AGENTS.md (501 lines)
  ├── [HAND] # Materia Podman Orchestration          ← title
  ├── [HAND] ## Goal                                  ← purpose
  ├── [HAND] ## Where this sits in the larger stack   ← architecture context
  ├── [HAND] ## Materia concepts                      ← domain glossary
  ├── [HAND] ## Architecture decisions (locked)       ← ADR-equivalent
  ├── [HAND] ## Repo layout                           ← codebase map
  ├── [HAND] ## Multi-server model                    ← operational model
  ├── [HAND] ## How a host reconciles                 ← runtime behavior
  ├── [HAND] ## Attributes                            ← config/secrets model
  ├── [HAND] ## Gotchas / hard-won constraints        ← 86 lines of traps
  ├── [HAND] ## Provisioning (Butane/Ignition)        ← runbook
  ├── [HAND] ## Development conventions               ← commit/repo rules
  ├── [HAND] ## Decisions still open                  ← future revisit
  ├── [HAND] ## Reference sources                     ← links
  ├── [FENCED] ## Project (bigpowers-managed)         ← duplicated purpose/commands/arch
  ├── [FENCED] ## Context Routing                     ← glob table
  └── [FENCED] ## Learned Preferences                 ← empty

CONVENTIONS.md (180 lines)
  ├── ## Project            ← purpose (duplicated with AGENTS.md fenced block)
  ├── ## Commands           ← command table (duplicated with AGENTS.md fenced block)
  ├── ## Architecture       ← 1-2 sentences (duplicated with AGENTS.md fenced block)
  ├── ## Conventions        ← Materia-specific conventions (overlaps hand-written ## Development conventions)
  ├── ## Never              ← hard stops (overlaps hand-written ## Architecture decisions / ## Gotchas)
  ├── ## Defensive Code     ← IaC-specific (new, no overlap)
  ├── ## Always Green       ← bigpowers doctrine (new, no overlap)
  ├── ## Discovered Defects ← bigpowers doctrine (new, no overlap)
  ├── ## Banned Phrases     ← bigpowers doctrine (new, no overlap)
  └── ## Agent Rules        ← bigpowers workflow mandate (new, no overlap)
```

## Findings

### 1. Triple duplication of Project / Commands / Architecture

**This is the main problem.** The same three pieces of information appear in
three places:

| Fact | Hand-written AGENTS.md | Fenced AGENTS.md block | CONVENTIONS.md |
|------|------------------------|------------------------|----------------|
| Project purpose | `## Goal` (line 5) | `## Project` (line 410) | `## Project` (line 7) |
| Commands | (implied via `mise.toml` + `## Repo layout`) | `### Commands` (line 426) | `## Commands` (line 23) |
| Architecture | `## Where this sits…` + `## Architecture decisions` + `## Repo layout` (lines 12–108) | `### Architecture` (line 441) | `## Architecture` (line 46) |

The hand-written sections are the authoritative, detailed versions. The fenced
block and the CONVENTIONS.md section are thin summaries that duplicate the same
information in fewer words. An agent reading all three sees the same thing three
times; an agent reading one might miss the richer detail in the hand-written
version.

**Why this happened:** The seed-conventions flow generates `## Project` /
`## Commands` / `## Architecture` in both the AGENTS.md fenced block AND
CONVENTIONS.md, because it assumes a greenfield project where these are the only
places they exist. For a repo with pre-existing rich docs, this creates
redundancy.

### 2. Conventions overlap: AGENTS.md `## Development conventions` vs CONVENTIONS.md `## Conventions`

The hand-written `## Development conventions` (line 348, 14 lines) and the
CONVENTIONS.md `## Conventions` (line 56, 29 lines) cover the same ground:

- Focused semantic commits — **both**
- Keep repo generic / no deployment-specific values — **both**
- Pinned image digests / Renovate — **both**
- AI sessions update AGENTS.md — **both** (hand-written)
- No upstream issues without permission — **both**

The CONVENTIONS.md version adds bigpowers-specific items (`specs/ is your
memory`, `verify: every step`, `.gotmpl` suffix, `m_dataDir`, inline comments).
The hand-written version is the original. They don't contradict, but they
overlap on ~5 items.

### 3. Never-do overlap: AGENTS.md gotchas vs CONVENTIONS.md `## Never`

The hand-written `## Gotchas` (86 lines) contains hard-won "never do X"
constraints (don't split the pod, don't mask docker, don't put inline comments
in quadlets). The CONVENTIONS.md `## Never` section (16 lines) repeats some of
these as bullet points. The bigpowers `## Never` template also includes generic
process never-do items (never dismiss gate failures, never proceed on red
Preflight) that are correctly CONVENTIONS.md territory and don't overlap.

### 4. What's correctly separated (no reconciliation needed)

These are clean and should stay as-is:

- **CONVENTIONS.md doctrine sections** (`Always Green`, `Discovered Defects`,
  `Banned Phrases`, `Agent Rules`) — bigpowers methodology, no hand-written
  equivalent. Correctly in CONVENTIONS.md.
- **CONVENTIONS.md `## Defensive Code`** — IaC-specific defensive concerns
  (Retry/Timeout/Graceful degradation mapped to materia-update.timer). No
  hand-written equivalent. Correctly in CONVENTIONS.md.
- **AGENTS.md hand-written domain sections** (`Materia concepts`, `Repo layout`,
  `Multi-server model`, `How a host reconciles`, `Attributes`, `Gotchas`,
  `Provisioning`, `Decisions still open`, `Reference sources`) — rich
  domain/operational content that has no place in CONVENTIONS.md. Correctly in
  AGENTS.md.

### 5. Missing from standard bigpowers structure

The standard bigpowers `CONVENTIONS.md` has sections this repo's version omits:

| Standard section | Present here? | Should it be? |
|------------------|---------------|----------------|
| Conventional Commits & Semantic Versioning | No (mentioned in Conventions bullets) | **No** — this is an IaC repo with no semantic-release; Conventional Commits is covered in the commit bullet. Adding the full semver section would be misleading (no releases to version). |
| GitHub & Git Operations | No | **Partial** — the solo-git `land-branch.sh` workflow is relevant, but most of the standard section (gh repo clone, gh run view, no REST API) is app-dev specific. A trimmed version could help. |
| Risk Tiers / Rule Matrix | No | **No** — P0–P3 risk tiers and `compile-rule-matrix.sh` are for code projects with tests. Not applicable to IaC. |
| Code Style (4–20 line functions, etc.) | No | **No** — no application code. |
| Tests (F.I.R.S.T) | No | **No** — no unit tests. The `verify:` mandate is already in Conventions. |
| specs/ output convention | Partial (mentioned in Conventions) | **Yes** — could be expanded, but the current mention is sufficient for this repo's usage level. |

**Assessment:** The omissions are correct. This is an IaC repo, not a code
project. Forcing the full bigpowers CONVENTIONS.md (with Code Style, F.I.R.S.T,
Risk Tiers, semantic-release) would add noise that doesn't apply. PR #13
correctly trimmed to the applicable sections.

## Recommendation

**Yes, reconcile — but lightly. The structure is fundamentally sound; the
problem is triple duplication of Project/Commands/Architecture.**

### Proposed changes (3 edits, no restructuring)

1. **Remove `## Project`, `## Commands`, `## Architecture` from CONVENTIONS.md.**
   These three sections duplicate what's already in AGENTS.md (both hand-written
   and fenced). Replace them with a single pointer line at the top:
   > *Project description, commands, and architecture live in `AGENTS.md` — read
   > it first. This file holds the process and quality rules.*

   This keeps CONVENTIONS.md as pure methodology (Conventions, Never, Defensive
   Code, Always Green, Discovered Defects, Banned Phrases, Agent Rules) and
   AGENTS.md as pure project context. No duplication.

2. **De-duplicate the fenced `## Project` block in AGENTS.md.** The fenced block
   currently repeats Project/Commands/Architecture/Conventions/Never/Agent Rules.
   Since the hand-written sections above already cover Project/Commands/
   Architecture/Conventions/Never in richer detail, trim the fenced block to
   contain only what the hand-written sections DON'T cover: the Agent Rules
   (bigpowers workflow mandate) and the Learned Preferences / Context Routing
   markers. This shrinks the fenced block from ~75 lines to ~20.

3. **Add a cross-reference header to AGENTS.md.** After the title, add:
   > *Process rules (Always Green, Discovered Defects, Conventional Commits,
   > Agent Workflow Mandate) live in `CONVENTIONS.md` — read it before any git
   > operation.*

   This mirrors the `Read CONVENTIONS.md before any GitHub or git operation`
   line from the bigpowers template, ensuring agents find the methodology file.

### What NOT to do

- **Do not merge AGENTS.md into CONVENTIONS.md or vice versa.** The separation is
  correct — project context vs methodology. Merging would create a 680-line
  monolith.
- **Do not restructure the hand-written AGENTS.md sections** (Materia concepts,
  Gotchas, Provisioning, etc.). They're well-organized and hard-won. The
  bigpowers structure doesn't prescribe how domain docs are organized within
  AGENTS.md — it only prescribes the top-level Project/Commands/Architecture
  headings, which this repo exceeds.
- **Do not add the full bigpowers CONVENTIONS.md doctrine** (Code Style,
  F.I.R.S.T, Risk Tiers, semantic-release). This is IaC, not a code project.
- **Do not move Gotchas to `specs/adr/` or `specs/tech-architecture/`.** The
  gotchas are operational constraints that agents need at-a-glance when editing
  quadlets. Burying them in `specs/` would make them less discoverable.

## Alternatives considered

### A. Status quo (no reconciliation)

**Pro:** Zero work, PR #13 already merged.
**Con:** Triple duplication persists. An agent updating the project description
has to edit it in three places. Drift is inevitable — already visible in the
purpose wording (we updated it three times across two files this session).

### B. Full restructure: move hand-written sections to specs/

Move `## Materia concepts`, `## Architecture decisions`, `## Gotchas`, etc. to
`specs/tech-architecture/tech-stack.md` and `specs/adr/`, leaving AGENTS.md as a
thin bigpowers-template-shaped file.

**Pro:** Matches bigpowers canonical layout exactly.
**Con:** Destroys the at-a-glance utility of AGENTS.md. The gotchas are the most
valuable content in the repo for an agent — they prevent subtle breakage.
Moving them to `specs/tech-architecture/tech-stack.md` makes them less
discoverable. The hand-written AGENTS.md is the product of months of operational
experience; restructuring it for template compliance is cargo-culting. **Not
recommended.**

### C. Proposed (light de-duplication) — recommended

**Pro:** Eliminates triple duplication, preserves hand-written content, keeps
the correct separation of concerns, ~3 edits.
**Con:** AGENTS.md no longer matches the bigpowers Reach Template shape
exactly — but it never did (it's 10× richer), and the template explicitly
supports hand-written content outside fences.

## Verdict

**Reconcile with approach C (light de-duplication).** The current structure from
PR #13 is the right idea — layer, don't replace — but it left triple duplication
of Project/Commands/Architecture. Removing those from CONVENTIONS.md and
trimming the fenced AGENTS.md block to just Agent Rules + markers gives a clean
two-file split with no redundancy:

- `AGENTS.md` — everything about THIS project (hand-written domain docs + fenced
  Agent Rules + markers).
- `CONVENTIONS.md` — everything about THE METHODOLOGY (process rules only, no
  project description).

If approved, the implementation is a follow-up commit on a new branch (not this
investigation branch).
