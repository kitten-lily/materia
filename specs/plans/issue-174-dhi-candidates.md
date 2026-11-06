# #174: Docker Hardened Images candidates

Catalogue of which images this repo uses have a Docker Hardened Images
(DHI) equivalent, and what switching each would take. Source: the public
DHI definitions, `github.com/docker-hardened-images/catalog` at `5e9692f4`
(2026-11-06, 688 images). Nothing was pulled: `dhi.io` needs a login.
Claims about image contents come from the definition files;
"[INFERENCE]" marks anything that still needs a real pull to confirm.

## Inventory

The repo uses 18 images across 13 components, plus 2 base images in
`images/restic-backup/Dockerfile`. **Six have a DHI match**; the other
fourteen have none (listed at the end).

## Candidates

| Component (host) | Current | DHI | Runs as | Shell |
|---|---|---|---|---|
| pangolin `traefik` (flutterina, public edge) | `library/traefik:v3.7.17` | `dhi.io/traefik:3.7.17` (debian13 / alpine3.24) | nonroot 65532 | none (4 packages, no dev variant) |
| grimmory `grimmory-mariadb` (bow, data) | `library/mariadb:12.3.3` | `dhi.io/mariadb:12.3.3` (debian13) | `mysql`, **UID 65532** | bash; probably no `/bin/sh` [INFERENCE] |
| mediamanager `mediamanager-postgres` (bow, data) | `library/postgres:18.6` | `dhi.io/postgres:18.6` (debian13; alpine exists) | `postgres`, **UID 70** | bash; probably no `/bin/sh` [INFERENCE] |
| `tailscale` / `tailscale-gateway` (flutterina, bow, krytis-runner) | `tailscale/tailscale:v1.104.4` | `dhi.io/tailscale:1.104.5`, `-compat` variant | root (`containerboot`) | runtime none; `-compat` has `dash` |
| restic-backup build stage (CI) | `library/golang:1.25-alpine` | `dhi.io/golang:1.26-alpine3.24-dev` | root (dev) | busybox, apk, git |
| restic-backup final stage (CI) | `scratch` | `dhi.io/static` | nonroot 65532 | none |

## What each switch needs

### traefik (highest exposure: the public ingress)

- `AddCapability=NET_BIND_SERVICE` to bind :80/:443 as UID 65532 (the
  minimus UID-1000 gotcha in AGENTS.md).
- `letsencrypt.volume`'s `acme.json` is `1000:1000`, mode 600. UID 65532
  can't read it, so it needs a host-side chown before the switch, made
  executable per BUG-010. Otherwise every certificate is reissued, or ACME
  fails.
- `Tmpfs=/plugins-storage` stays. It worked for minimus's non-root UID 1000.
- No `HealthCmd=` today, so the missing shell doesn't matter.
- Test badger with the AGENTS.md local reproduction against the DHI image.

### mariadb (grimmory)

- **The entrypoint ignores `MARIADB_DATABASE`/`MARIADB_USER`/`MARIADB_PASSWORD`.**
  It reads only `MARIADB_ROOT_PASSWORD(_FILE)` and `MARIADB_OPTIONS`.
  bow's existing data is unaffected, but a fresh host would get no
  `grimmory` database or user, silently, like the `MYSQL_*` gotcha. That
  needs an init script, or a decision to accept the gap for fresh hosts.
- The entrypoint drops root via `gosu` but **never chowns the datadir**
  (official images do). The data is owned by 999 today, so it needs a
  host-side chown to 65532.
- Ships `/usr/local/bin/healthcheck.sh`, which is usable with a JSON-array
  `HealthCmd=` if wanted.
- Dump first with `mise db:backup`, then `--compare`.

### postgres (mediamanager)

- Same `gosu`-without-chown behaviour, so a host-side chown 999 → 70.
- Default `PGDATA` is `/var/lib/postgresql/18/data`, and **there is no
  "unused mount" guard**: the entrypoint only checks `$PGDATA/PG_VERSION`.
  Keep `PGDATA=/var/lib/postgresql/data`. Without it, the image silently
  runs initdb on an empty cluster next to the real data. The official
  image refuses to start in that case instead.
- `HealthCmd=pg_isready …` is a plain string, so it runs via `/bin/sh`.
  Change it to `HealthCmd=["pg_isready","-U","mediamanager","-d","mediamanager"]`
  if `/bin/sh` is indeed missing.
- Use the **debian13** variant. Its glibc should match the official
  Debian trixie image (2.41), so there's no collation change [INFERENCE].
  The alpine variant is musl, which would mean another collation change
  and reindex.

### tailscale

- Same `containerboot` entrypoint and env contract as upstream; still
  runs as root; `iptables` and `iproute2` are present.
- Both quadlets use `HealthCmd=wget -q -O /dev/null http://127.0.0.1:9002/healthz`.
  The runtime image has no shell, and `-compat` has `dash` but no `wget`,
  so **the probe needs a new design** (`tailscale status --json`
  semantics differ from `/healthz`).

### restic-backup image (CI build)

- `golang`: DHI has only 1.26/1.27, no 1.25. restic needs ≥ 1.25.8, so
  1.26 should do [INFERENCE: needs a build]. The `-dev` variant has
  `apk`/`git` for the builder stage.
- `static` instead of `scratch` adds CA certificates and a non-root user,
  but the job reads a 0400 root-owned SSH key, so it stays root. Small
  gain.
- The CI workflow would need Docker Hub credentials as a GitHub Actions
  secret.

## No DHI image

jellyfin, navidrome, aonsoku, audiobookshelf, grimmory (app),
mediamanager (app), beszel hub and agent, pangolin/gerbil/newt,
buildbarn `bb-storage`/`bb-remote-asset`, our own `restic-backup`, and
materia itself (`ghcr.io/stryan/materia`).

## Cross-cutting (unchanged from the issue)

Every switch inherits the open credential questions: host pulls (Q1),
Renovate lookups (Q2), and vendor-gate risk (Q3). The scope question
(Q5) is now answered by the catalogue: at most these six images.

## Suggested order, if pursued

1. **traefik:** the most exposed, no data, one chown.
2. **tailscale:** network-facing, but needs the probe redesign.
3. **postgres**, then **mariadb:** internal only, carry live data and the
   chown/env traps, so they come last.
4. **golang/static:** build-time only; do it whenever CI credentials exist.
