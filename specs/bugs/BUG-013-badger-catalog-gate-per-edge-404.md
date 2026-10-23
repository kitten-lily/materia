# BUG-013 — badger catalog gate fails docs commits on a per-edge cached 404

**status:** fixed
**found:** 2026-10-23, preflight run 39931624928 on `main` (commit `0ba9541`, docs-only)
**severity:** P3 (red CI on `main`; no host affected)
**epic:** standalone (CI)

## Symptom

The "badger version accepted by traefik plugin catalog" job failed with
`traefik plugin catalog rejects badger v1.5.0 (HTTP 404)` after all six
attempts of BUG-011's retry loop returned 404, from 09:24:30Z to 09:26:46Z.
The pin had not changed, and the commit touched only docs.

The run for the next commit, `2dc265f`, ran at the same time on a different
runner. It got **200 at 09:24:48Z**. The failing runner got 404 at 09:24:45Z
and again at 09:25:06Z. So the catalog gave two different answers to two
runners at the same moment.

## Root cause

BUG-011 assumed the catalog has short, global 404 outages that a ~2 min retry
outlasts. That assumption was wrong. `plugins.traefik.io` sits behind
Cloudflare, and each edge keeps its own cached answer:

- `cf-cache-status: HIT` with `age: 4893829` (~56 days, `last-modified:
  Thu, 27 Aug 2026`) for v1.5.0. The `cache-control: max-age=3600` header does
  not bound what the edge serves.
- From the same edge (CPH), v1.7.0 returns a cached **200** from 27 Aug.
  BUG-007 recorded 404 for v1.7.0. So the same version gets different
  answers from different edges or at different times.
- The cache can't be bypassed. The origin returns 404 for any URL that isn't
  exact: `?cb=<n>`, a trailing `/`, and an empty `?` are all `MISS` + 404,
  even for v1.5.0 and for `traefik/plugindemo`.

[INFERENCE] The failing runner reached an edge holding a 404 for v1.5.0. A
retry from the same runner reaches the same edge, so no backoff length fixes
that. The run did not log cf-ray, so the edge can't be confirmed after the
fact.

The gate also ran on every push. A commit that cannot change `badgerVersion`
paid for a third-party cache's state.

## Fix

- Move the job out of `preflight.yml` into `.github/workflows/badger-catalog.yml`.
  It runs only when `components/pangolin/MANIFEST.toml` or the workflow itself
  changes, plus `workflow_dispatch`. A Renovate bump of `badgerVersion` still
  hits it, and docs commits no longer do.
- Log `cf-ray` (the suffix is the edge), `cf-cache-status` and `age` for every
  attempt, so the next 404 shows which edge sent it and whether it was cached.
- The error text says a 404 from one edge is not proof on its own.

The retry loop stays. It still covers origin blips.

## Verify

- verify: `gh run list --workflow preflight.yml --branch main --limit 1` → success, and `known_hosts drift check` is its only job
- verify: `gh workflow run badger-catalog.yml && gh run list --workflow badger-catalog.yml --limit 1` → success, and the log shows `catalog answered HTTP 200 (cf-ray=…)`
- verify (local, done 2026-10-23): extract the step script with `yq` and run it. Pinned v1.5.0 gives exit 0. A temp copy pinned to v1.6.1 logs six 404s (`cache=EXPIRED`) and exits 1.
