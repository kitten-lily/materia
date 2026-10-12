# BUG-011 — badger catalog gate fails main on a transient catalog 404

**status:** fixed
**found:** 2026-10-12, preflight run 38289449314 on `main` after #146 merged
**severity:** P3 (red CI on `main`; no host affected)
**epic:** standalone (preflight CI)

## Symptom

`preflight` / "badger version accepted by traefik plugin catalog" failed with
`traefik plugin catalog rejects badger v1.5.0 (HTTP 404)`. v1.5.0 is the pinned
version and had not changed. The same check on the PR's last commit passed at
18:12:15Z, and the failing run's three attempts ran 18:13:29–18:13:46Z. Manual
`curl` of the same URL right afterwards returned 200 six times in a row.

It happened once before: run 34212194499 (2026-09-08 09:50:12Z) failed the same
way, between runs at 09:49:59Z and 09:50:33Z that both passed with v1.5.0.

## Root cause

`plugins.traefik.io/public/validate/<module>/<version>` sometimes answers 404
for an accepted version, for about 20 seconds. The gate retried 3 times, 5 s
apart, which is shorter than the outage, so all three attempts landed inside it.

## Fix

`.github/workflows/preflight.yml`: 6 attempts with 5/10/20/40/60 s backoff
(about 2 min), and each attempt's HTTP code logged. BUG-007's real rejection is
a steady 404, so it still fails, about 2 minutes later.

## Verify

- verify: `gh run list -R kitten-lily/materia --workflow preflight.yml --branch main --limit 1` → success
- verify: the job log shows `catalog answered HTTP 200`
