# BUG-014 — badger catalog gate validates without `X-Plugin-Hash`, catalog 404s everything

**status:** fixed
**found:** 2026-11-05, badger-catalog run 42002814406 on `main` (commit `e3a474f`)
**severity:** P3 (red CI on `main`; no host affected)
**epic:** standalone (CI)

## Symptom

`badger version accepted by traefik plugin catalog` failed with
`traefik plugin catalog rejects badger v1.5.0 (HTTP 404)`. All six attempts
got 404 from the IAD edge, and every one was `cf-cache-status: DYNAMIC`,
meaning Cloudflare served the origin's live answer, not a cached one. The same
URL from the workstation (CPH edge) also gave `DYNAMIC` 404s.

## Root cause

The gate called `GET /public/validate/<module>/<version>` with no headers.
Traefik doesn't. Its check (`pkg/plugins/downloader.go` `Check`, traefik
master `38d53dd`):

1. downloads the archive from `/public/download/<module>/<version>`;
2. computes `hex(sha256(archive))` (`manager.go` `computeHash`);
3. calls `validate` with `X-Plugin-Hash: <that hash>`.

Measured 2026-11-05, all `cf-cache-status: DYNAMIC`:

| Request | v1.5.0 | v1.6.0 | v1.6.1 | v1.7.0 |
|---|---|---|---|---|
| no `X-Plugin-Hash` | 404 | 404 | 404 | 404 |
| empty `X-Plugin-Hash` | 404 | 404 | 404 | 404 |
| wrong hash | 404 | 404 | 404 | 404 |
| correct hash | **200** | **200** | **200** | **200** |

Without the hash, `traefik/plugindemo` v0.2.1/v0.2.2 also get an empty-body
404. An unknown plugin gets a JSON `Plugin not found` 404. So the catalog
checks the hash for every plugin it knows, and the gate's request could never
pass.

BUG-007 recorded that the endpoint "ignores `X-Plugin-Hash` entirely for
plugins it knows": in September `plugindemo` returned 200 with a
deliberately wrong hash. **The catalog has changed since then.** It now
enforces the hash, and it re-published badger v1.6.1: BUG-007 recorded the
v1.6.1 archive as `sha256 33bcd3d7…`, today it is `9a5a926900ab…`. That
fits upstream's "accidentally tagged" explanation in fosrl/badger#31.

[INFERENCE] This probably also explains BUG-011 and BUG-013:

- Cloudflare caches by URL, not by the `X-Plugin-Hash` header. An edge then
  serves whichever answer it cached first: a 200 from a hashed traefik
  request, or a 404 from a hashless probe such as this gate. That fits the
  per-edge `HIT` 200s and 404s with ~56-day ages that BUG-013 saw for the
  same version.
- The same mechanism could hand a cached hashless 404 to a real traefik
  startup, a BUG-007-style edge outage triggered by someone else's probe.
- Today's answers are all `DYNAMIC` (uncached), so none of this is happening
  now.

## Fix

`.github/workflows/badger-catalog.yml` now does exactly what traefik does:

- download the pinned archive (`--retry 3`, so transient download errors are
  retried);
- send its sha256 as `X-Plugin-Hash` to `validate`.

Behaviour:

- no archive for the version → error;
- catalog unreachable → warning, then skip (unchanged);
- the retry loop and per-attempt `cf-ray`/`cf-cache-status`/`age` logging stay.

Not changed here: the Renovate hold `badgerVersion <=1.5.0`. v1.6.x and
v1.7.0 all validate with the correct hash today. Lifting the hold, which
Pangolin >= 1.22's public resource type needs, is a separate decision and
should be tried with the local traefik reproduction in AGENTS.md first.

## Verify

- verify (local, done 2026-11-05): extract the step script with `yq` and run
  it:
  - pinned v1.5.0 → `archive sha256: c2378ec1…`, one `HTTP 200 (cache=DYNAMIC)`,
    exit 0;
  - a temp manifest pinned to v9.9.9 → `no archive for badger v9.9.9 (HTTP 500)`,
    exit 1;
  - a copy that prefixes the hash with `0000` → six `HTTP 404`, exit 1.
- verify: the `badger-catalog` run on the push of this fix succeeds and logs
  `archive sha256:` followed by `catalog answered HTTP 200`.
