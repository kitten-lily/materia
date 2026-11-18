# SilentSuite feasibility

Investigation date: 2026-11-17. Investigation only: no component, vault or
host changes.

## Recommendation

Feasible as a standard bow component (`silentsuite`: server + Postgres
sidecar on `newt-net`, published through `tailscale-gateway` and the Pangolin
edge). It fits the mediamanager/grimmory pattern with no new infrastructure.
Two things should be decided before building it:

1. **Client coverage.** There is no iOS client. Android, the hosted web app
   and a desktop CalDAV/CardDAV bridge exist. If any device that needs
   calendar/contacts is an iPhone, stop here.
2. **Beta risk on irreplaceable data.** The project is beta, releases every
   few days (v0.5.16 → v0.5.21 between 2026-10-26 and 2026-11-17), has no
   independent audit, and says outright that it supplies no cross-version
   updater (`self-host/update.sh`: "This script does not change SilentSuite
   versions"). Every image bump runs `manage.py migrate` on start. Renovate
   bumps for this image must never automerge, and each one needs a
   `pg_dump` first.

## What it is

E2E-encrypted sync for calendars, contacts and tasks (notes experimental, web
only). Server stores ciphertext only. It is a fork of the EteSync/Etebase
server (Django + FastAPI under uvicorn, config file `etebase-server.ini`).
Licence AGPL-3.0-only (server, web, self-host), GPL-3.0 (Android adapter).

Sources: <https://silentsuite.io>, <https://docs.silentsuite.io/self-hosting/>,
<https://github.com/silent-suite/silentsuite> (`self-host/docker-compose.yml`,
`self-host/install.sh`, `Dockerfile.server`, `server/docker/entrypoint.sh`,
`server/etebase_server/settings.py`, `server/etebase_server/fastapi/main.py`).

## Upstream deployment shape

Two containers, nothing else (no Redis, no web container):

| | Upstream | Notes for materia |
|---|---|---|
| Server | `ghcr.io/silent-suite/silentsuite-server@<index digest>` | Non-root user `etebase` (Alpine `adduser -S`, UID not pinned). Listens 3735. |
| DB | `postgres:16.9-alpine` by digest | `shm_size: 128mb`, `max_connections=200`, `pg_isready` healthcheck |
| Server state | volume at `/data` | `secret.txt` (Django SECRET_KEY), `media/`, `static/`. The image chowns `/data` to `etebase`, so podman's copy-up on an empty named volume keeps it writable: no `User=`/`Group=` on the `.volume`. |
| DB state | volume at `/var/lib/postgresql/data` | Postgres 16: the default PGDATA, no override needed (unlike our 18.6 pin). |
| Config | `etebase-server.ini` → `/etc/etebase-server/etebase-server.ini:ro` | Contains the DB password (see Secrets). |
| | `success.html` → `/app/etebase_server/templates/success.html:ro` | Optional branding; skip it. |

The supported install path is `install.sh` (Docker 24+/Compose v2). It only
verifies a release bundle and writes `.env` + the ini. Nothing in it is
needed when writing quadlets by hand.

**Image tags exist** on GHCR: `v0.5.21-beta`, `v0.5.19-beta.2`,
`selfhost-<sha>`, bare `<sha>`. Renovate can pin `tag@digest`, but needs a
regex `versioning` (the `-beta` / `-beta.2` suffixes otherwise read as
different compatibility tracks, which is the jellyfin silence gotcha).

**Verified 2026-11-18:** for all 8 published releases checked (v0.5.13-beta
… v0.5.20-beta), the GHCR `v*` tag, the `selfhost-<sourceCommit>` tag and
the release asset `server-image.json`'s `indexDigest` are the same digest.
The amd64 child of each index equals the manifest's `amd64Digest`. So
`ghcr.io/silent-suite/silentsuite-server:<tag>@<digest>` pins exactly what
`install.sh` would install. None of the 8 release commits has a bare
`<sha>` tag; what the existing bare-SHA tags contain was not checked, so
never pin one.

**Catch:** image tags are pushed before the GitHub release is published.
`v0.5.21-beta` (git tag → commit `34844fe`, same digest as
`selfhost-34844fe…`) exists on GHCR while the release API answers 404 for
it, and the installer refuses unpublished releases. Renovate sees the GHCR
tag, so it would propose builds upstream hasn't released.

**Merge gate (mandatory):** a CI check, like the `badger-catalog` workflow,
that the tag has a *published* GitHub release and that the pinned digest
equals `indexDigest` in that release's `server-image.json`. A
`minimumReleaseAge` only adds delay on top. It can't be the gate, because an
old tag that was never released would still become eligible.

## Configuration that matters

Env vars (server): `ETEBASE_DISABLE_SIGNUP`, `ETEBASE_BOOTSTRAP_ADMIN_TOKEN`,
`ETEBASE_DISABLE_DJANGO_ADMIN` (default true, leave it), `SUPER_USER`/
`SUPER_PASS` (Django admin only, skip), `TRUSTED_PROXY_IPS`,
`ETEBASE_MAX_REQUEST_BYTES`, `CORS_ALLOWED_ORIGINS`,
`ETEBASE_SECURE_SSL_REDIRECT`, `ETEBASE_BEHIND_PROXY`,
`ETEBASE_EASY_CONFIG_PATH`.

ini: `[global] secret_file/media_root/static_root`, `[allowed_hosts]`
(becomes both Django `ALLOWED_HOSTS` and FastAPI's `TrustedHostMiddleware`,
so it must list the public hostname *and* `localhost` for the healthcheck),
`[database]`.

### Reverse proxy: the redirect-loop trap

With `debug = false`, `SECURE_SSL_REDIRECT` defaults to **true**. uvicorn
only rewrites the scheme from `X-Forwarded-Proto` when the TCP peer is in
`TRUSTED_PROXY_IPS` (exact IPs, no CIDR). Our peer is the
`tailscale-gateway` container's `newt-net` address, which is dynamic. If it
isn't trusted, the app sees `http` and 301-loops every request to https.
Options:

- `ETEBASE_SECURE_SSL_REDIRECT=false`: TLS is terminated at Traefik anyway,
  and port 3735 is reachable only on `newt-net`. Stops the loop, but on its
  own the app still sees `http`, so generated URLs, HSTS and CSRF checks may
  not behave as HTTPS.
- `ETEBASE_BEHIND_PROXY=true`: sets Django's `SECURE_PROXY_SSL_HEADER`, so
  Django trusts `X-Forwarded-Proto` regardless of peer.
- `TRUSTED_PROXY_IPS=*`: passed to uvicorn's `--forwarded-allow-ips`. It
  also lets any `newt-net` container spoof client IPs and scheme.

**Not settled (review 2026-11-18).** These conclusions come from `main`
sources, not the release that would be pinned. The uvicorn version, the
full Django/FastAPI middleware order, and the "exact IPs, no CIDR" limit
(stated by upstream docs, not checked in uvicorn) are unverified. Decide in
the local test run (below): HTTPS through a TLS proxy, then check
redirects, `Strict-Transport-Security`, CSRF on any POST, and generated
URLs. Record which peers are allowed to supply trusted headers.

Traefik sets `X-Forwarded-Proto`; the gateway's raw `TCPForward` passes the
headers through unchanged. Upload limit: `ETEBASE_MAX_REQUEST_BYTES` is
64 MiB. Traefik has no default body limit, so no proxy change is needed.

### CORS

`CORS_ALLOWED_ORIGINS` defaults to `https://app.silentsuite.io`,
`previewapp`, and localhost. The hosted web app therefore works against a
self-hosted server with no change. Only set it if we self-host the web
client too (out of scope).

### Secrets

The server takes the DB password **only** from the ini (`settings.py` has no
env override for it). Two ways to keep it out of a plaintext data-dir file:

- **Recommended:** `settings.py` calls `configparser.read()` on *every*
  existing path in `[ETEBASE_EASY_CONFIG_PATH, ./etebase-server.ini,
  /etc/etebase-server/etebase-server.ini]` and merges their sections. So the
  templated ini (non-secret, data resource) leaves out `password`, and a
  hand-written `Secret=materia-silentsuiteDbIni,type=mount,target=/run/secrets/db.ini`
  holding `[database]\npassword = …` is pointed to by
  `ETEBASE_EASY_CONFIG_PATH`. Cost: the vault holds the password twice
  (bare for Postgres' `POSTGRES_PASSWORD`, ini-fragment for the server).
  Set both in one `sops --set` script, never by hand (BUG-003).
  Unverified: the merge and the secret's readability by the non-root
  `etebase` user (mount mode 0444) need the local test run.
- Simpler: template `{{ .silentsuiteDbPassword }}` into the ini. The password
  then sits in `/var/lib/materia/components/silentsuite/` at mode 0644
  (upstream does the same, mode 0644). Weaker, but the DB has no published
  port.

`ETEBASE_BOOTSTRAP_ADMIN_TOKEN` goes in the vault too, via `secretEnv`.

## Proposed component (bow)

```
components/silentsuite/
  MANIFEST.toml                      # Secrets: silentsuiteDbPassword, silentsuiteDbIni, silentsuiteBootstrapToken
  silentsuite.container.gotmpl       # newt-net, no PublishPort, Requires/After postgres, strict HealthCmd (see below)
  silentsuite-postgres.container.gotmpl  # postgres 16 official, newt-net, Notify=healthy + pg_isready, ShmSize=128m
  etebase-server.ini.gotmpl          # allowed_hosts = silentsuite.<baseDomain>, localhost; no password
  silentsuite-data.volume
  silentsuite-db.volume
```

Service `silentsuite.service` needs `RestartedBy = ["silentsuite.container",
"etebase-server.ini"]`, as mediamanager does for `config.toml`, so ini
changes take effect.

**Healthcheck:** upstream's probe passes on any status below 500, so a 400
(host rejected by `allowed_hosts`), a 404 or a redirect loop all count as
healthy. Use a probe that names an endpoint and requires the exact status
(and body if useful) it returns when the API is ready. Find both in the
test run. The Pangolin health check must send `Host:
silentsuite.<baseDomain>` if it probes the target IP. After deploy, also
make one real API request through Pangolin from outside.

Plus:
- `MANIFEST.toml`: add to `Hosts.bow.Components` only after the vault keys
  exist (the missing-attribute abort gotcha).
- `tailscale-gateway/serve/serve.json`: `"3735": { "TCPForward":
  "silentsuite:3735" }` (this restarts the gateway, which briefly drops all
  forwards).
- Pangolin: resource `silentsuite.<baseDomain>`, site **flutterina**, target
  `<bow-ts-ip>:3735` (site and host together, see the retarget gotcha).
  **SSO off**, because the Android app and bridge are non-browser clients
  (the beszel-agent 302 failure). Add a health check on `/`.
- `renovate.json5`: regex versioning for this image, `automerge: false`,
  `minimumReleaseAge`, plus the release/digest merge gate above.
- **Backups (prerequisite, wider than this component).** Today there is no
  reliable restore path for any Postgres/MariaDB on bow. restic backs up the
  live data directories, which this plan calls unreliable. `mise db:backup`
  writes to `/var/lib/db-backups`, which restic does not cover
  (`BACKUP_PATHS` is the materia data dir and the podman volumes). The
  script is also manual and hardcodes the mediamanager user and database
  (`.mise/tasks/db/backup:54`, `:67`). Needed: scheduled logical dumps into
  a restic-covered path, a script parameterised per database, and a tested
  restore of both the database and `/data`. Grimmory and mediamanager have
  the same gap, so track it separately.

Why bow over flutterina: matches every other personal app, has the data disk
and restic, and keeps user data off the public ingress box. The cost is that
sync is only available while the home uplink and the T2 path are up. The
clients sync offline-first, so an outage only delays sync.

## First-run procedure

1. Deploy with `ETEBASE_DISABLE_SIGNUP=false` and a bootstrap token.
2. Sign up from a client using server URL
   `https://silentsuite.<baseDomain>/?bootstrap_token=<token>`. The first
   account becomes server admin.
   Until step 3 is live, anyone who reaches the URL can register (the
   bootstrap token is ignored once an account exists).
3. Flip `ETEBASE_DISABLE_SIGNUP=true` in the manifest and push, then run
   `materia update` on bow immediately (deploys are pull-based on a daily
   timer). Confirm by attempting a second signup and checking that it is
   rejected. Additional accounts after that need signup re-opened, or the
   `ETEBASE_REGISTRATION_TOKEN` env (exists in `settings.py`, undocumented:
   verify).

## Local test run (before writing the component)

Against the exact image to be pinned (currently
`v0.5.20-beta@sha256:6a5ab47d…`), with rootful podman, a TLS proxy in front,
and fresh named volumes:

- ini merge via `ETEBASE_EASY_CONFIG_PATH`; secret readable by `etebase`;
  DB authentication succeeds.
- `/data` on an empty named volume is writable by `etebase` (copy-up);
  `secret.txt` persists across a container restart.
- Proxy behaviour per the options above; pick one and record why.
- A strict readiness endpoint and status for the healthcheck.
- First signup with the bootstrap token; second signup rejected after
  `ETEBASE_DISABLE_SIGNUP=true`.

## Open questions / unverified

- iOS requirement (blocking, user decision).
- Everything listed under "Local test run".
- Backup prerequisite (see Proposed component).
- Audit lineage: none found (2026-11-17). EteSync's two NLnet NGI0 PET
  grants (iOS app 2019, Etebase protocol redesign 2020) mention no audit,
  and Radically Open Security's public reports have no EteSync entry.
  Neither EteSync nor the SilentSuite fork has a known third-party review.
- Etebase protocol compatibility: whether existing EteSync clients or a
  plain upstream `etebase-server` would be an option. Not investigated.
- Android app and bridge custom-server steps (docs not read).
