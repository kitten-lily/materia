# Implementation Plan — Issue #70: Add mediamanager component (TV + movies) on bow

**issue:** https://github.com/kitten-lily/materia/issues/70
**risk:** P2 (new self-contained component on `bow`, but it takes **write**
access to the media libraries `jellyfin` already serves read-only, moves them
under a new `video/` parent on the LVM data disk, and changes their ownership
to UID 1000)
**epic:** standalone

## Summary

Add a `mediamanager` component running
[MediaManager](https://github.com/maxdorninger/MediaManager) v1.12.3 — a
single-app successor to the "Arr" stack (TV/movie discovery, indexer search,
download-client handoff, library organisation) — on `bow`, exposed at
`mediamanager.<baseDomain>` via the existing Newt tunnel.

Two containers: the app (`quay.io/maxdorninger/mediamanager`) and a
PostgreSQL sidecar. Both standalone on `newt-net`, same shape as
`grimmory` + `grimmory-mariadb`.

## Architecture decisions

### Standalone containers on `newt-net`, no pod

MediaManager and its Postgres have no shared-network-namespace requirement
(the `pangolin.pod` exception exists only for Gerbil's CGNAT tunnel IPs), so
they join `newt-net` and reach each other by **container name**
(`mediamanager-postgres:5432`). Newt reaches the app by container name
(`mediamanager:8000`). Container-name resolution only works on named podman
networks, not the default bridge. No `PublishPort`: neither 8000 nor 5432 is
bound on the host.

### One bind mount for the whole video subtree — hardlinks can't cross mounts

MediaManager hardlinks a finished download from `torrent_directory` into the
library instead of copying it, and `run_filesystem_checks()` probes exactly
that at startup. Linux rejects `link()` when the two paths are on different
**mount points**, even when both sit on the same filesystem — confirmed
locally: three separate binds of sibling directories on one tmpfs produced
`OSError: [Errno 18] Invalid cross-device link`, and MediaManager logged
"Hardlink creation failed, falling back to copying files". The fallback keeps
two full copies of every import on a disk that is already ~94% used.

So the libraries and the downloads directory move under a single parent on
bow's LVM data disk, mounted **once**:

```
/var/lib/materia-data/video/          →  /data        (rw, :z)
                        ├── Movies    →  /data/Movies
                        ├── TVShows   →  /data/TVShows
                        └── Downloads →  /data/Downloads
```

Chosen over binding `/var/lib/materia-data` wholesale (which would hand
MediaManager read-write access to buildbarn's CAS plus the Music, Books,
AudioBooks and Podcasts libraries) and over keeping three separate binds
(which loses hardlinks permanently). `jellyfin` follows the move — its two
mounts become `/var/lib/materia-data/video/{Movies,TVShows}`, still `:ro,z`,
with **container-side paths unchanged** (`/media/Movies`, `/media/TVShows`),
so its library database needs no re-scan. The host-side move is a rename
within one filesystem, i.e. instant.

Read-write is mandatory, not a preference: `filesystem_checks.py` runs at
**import time** (module scope in `main.py`, before the app serves anything)
and `mkdir`/`rmdir`-probes both the TV and movie directories. A read-only
mount kills the container at startup. This is the first component in the repo
that writes into a library another component reads.

`image_directory` (poster/backdrop cache) is a named volume mounted at
`/images`, deliberately **outside** `/data` — nesting it would materialise an
empty mount-point directory inside the media library. No hardlinking happens
there, so a separate mount costs nothing.

### Runs as UID 1000 — deliberately skipping the image's root branch

`mediamanager-startup.sh` branches on `id -u`:

- **as root:** `chown -R mediamanager:mediamanager /data` whenever
  `stat -c '%U' /data` isn't `mediamanager`, plus `chown -R "$CONFIG_DIR"`.
  The `/data` chown would walk the entire media library, and the `CONFIG_DIR`
  chown would fail outright against the read-only config mount (the script
  runs under `set -eEuo pipefail`).
- **as non-root:** skips permission fixing entirely and `exec`s the app.

So the quadlet sets `User=1000` / `Group=1000` — the image's own
`mediamanager` user (`groupadd -g 1000` / `useradd -u 1000` in its
Dockerfile), which owns `/app`, `/app/.venv` and `UV_CACHE_DIR`. Cost: the
host-side directories must be owned `1000:1000` (a one-time deploy step, same
as grimmory's `/Books`), and named volumes get `User=1000`/`Group=1000` per
the existing UID-1000 volume-ownership gotcha.

### Config: `CONFIG_DIR`, **not** `CONFIG_FILE`

MediaManager reads a TOML config; **every** value can also be overridden by a
`MEDIAMANAGER_<SECTION>__<KEY>` env var (`env_nested_delimiter="__"` in
`media_manager/config.py`), which is how the secrets get in.

`config.py` resolves the path as `CONFIG_FILE` if set, else
`$CONFIG_DIR/config.toml` — but **`CONFIG_FILE` cannot be set from outside the
container**: `mediamanager-startup.sh` does
`CONFIG_FILE="$CONFIG_DIR/config.toml"`, and reassigning an already-exported
shell variable keeps it exported, so the app child process inherits the
script's value, not ours. Found by smoke test, not by reading: with
`CONFIG_FILE=/etc/mediamanager/config.toml` passed in, the app silently read
the image's own example config and died with
`failed to resolve host 'db'`.

The component therefore sets `CONFIG_DIR=/etc/mediamanager` and mounts the
templated file at `/etc/mediamanager/config.toml` **read-only**. That is safe
because the entrypoint's two write paths don't trigger: the file already
exists (so no example-config copy) and we're non-root (so no `chown -R`).

`LOG_FILE=/tmp/media_manager.log` goes with it: the rotating file handler
defaults to `/app/config/media_manager.log`, a path that no longer exists once
`CONFIG_DIR` moves, and `dictConfig` hard-fails on an unopenable handler
(`ValueError: Unable to configure handler 'file'` — also found by smoke test).
Logs still go to stdout → journal, so the file is redundant; parking it on the
container's ephemeral filesystem is the cheapest correct answer.

The config file is a `.gotmpl` data resource (installs to
`{{ m_dataDir "mediamanager" }}/config.toml`) and is bind-mounted
individually — never the whole data dir, per the data-dir-drift gotcha. Only
fields that exist in v1.12.3's pydantic models are written: upstream's
`config.example.toml` tracks `master` and already contains keys this release
doesn't know (e.g. `[auth] registration_enabled`).

### Secrets: `token_secret` + DB password as podman secrets

Component manifest `Secrets`:

- `mediamanagerTokenSecret` → `MEDIAMANAGER_AUTH__TOKEN_SECRET` (session
  signing key, `openssl rand -hex 32`)
- `mediamanagerDbPassword` → `MEDIAMANAGER_DATABASE__PASSWORD` on the app and
  `POSTGRES_PASSWORD` on the sidecar — one value, two consumers, exactly like
  `grimmoryDbPassword`

Both live in `attributes/bow.yml` under `components.mediamanager`, written with
`fnox exec -- sops --set` (never a hand paste — BUG-003). They MUST exist
**before** the component is wired into the root `MANIFEST.toml`: a missing
attribute is a fatal vault-load error that aborts reconciliation of *every*
component on the host (the `baseDomain` incident).

`mediamanagerAdminEmail` is a third, non-secret attribute — the address that
becomes administrator. MediaManager creates that account on first boot and
prints its generated password to the container log; the address does not need
to be a deliverable mailbox (no SMTP is configured). Seeded as
`mediamanager@<baseDomain>`, following the existing `pangolin@<baseDomain>`
service-address convention; change it with `sops --set` if a personal address
is preferred.

### Images: pinned by digest, Renovate-tracked

- App: `quay.io/maxdorninger/mediamanager:1.12.3@sha256:83b80dce…` — latest
  stable release. Quay is upstream's primary registry (they moved off GHCR for
  performance); the GHCR mirror is byte-identical.
- DB: `reg.mini.dev/postgres:v17.11@sha256:42030b58…` — minimus, matching the
  repo's preference for minimus images where they exist (traefik, mariadb).
  Unlike minimus mariadb this one needs **no** env/path translation: its image
  config declares `User=0`, `PGDATA=/var/lib/postgresql/data` and the stock
  `docker-entrypoint.sh`, i.e. the official `POSTGRES_*` contract (verified
  against the registry manifest and then live). Postgres 17, not 18: upstream's
  compose targets 17 and 18 relocated the data directory. The volume stays
  root-owned — the entrypoint chowns `PGDATA` itself.

Renovate's existing `quadlet` manager already matches `*.container.gotmpl`;
both images are picked up with no config change.

### Postgres gates the app's start

The sidecar sets `Notify=healthy` + `HealthCmd=pg_isready …` and the app unit
`Requires=`/`After=`s it. MediaManager runs `alembic upgrade head` in its
entrypoint and exits non-zero if the DB is unreachable, so plain start
ordering (grimmory's approach, which leans on the app's own connection retry)
would crash-loop instead of waiting. `pg_isready` is present in the minimus
image (verified).

### Pangolin exposure: SSO kept ON

Browser-driven UI with its own login — same call as `grimmory` /
`audiobookshelf` / `jellyfin`, not `beszel-agent` (whose headless WebSocket
handshake broke on Pangolin's 302 to the SSO login page).

## Files created / modified

1. `components/mediamanager/` — `MANIFEST.toml`, `config.toml.gotmpl`,
   `mediamanager.container.gotmpl`, `mediamanager-postgres.container.gotmpl`,
   `mediamanager-db.volume`, `mediamanager-images.volume`.
2. `components/jellyfin/jellyfin.container.gotmpl` — library binds repointed
   at `/var/lib/materia-data/video/…`.
3. `attributes/bow.yml` — `components.mediamanager.*` (two secrets + admin
   email).
4. `MANIFEST.toml` — `mediamanager` added to `[Hosts.bow] Components`.
5. `AGENTS.md` — repo layout entry + gotchas.

## Verification

**Local podman smoke test** (workstation, real images, the exact rendered
config and mount layout, `--user 1000:1000`, secrets as plain env):

- `Config file found at: /etc/mediamanager/config.toml` — the read-only
  materia-managed file is what the app read.
- `Running as non-root user (1000). Skipping permission fixes.` — no
  library-wide chown.
- `alembic upgrade head` applied; 15 tables present in the Postgres sidecar
  (`\dt`), which came up `healthy` on `pg_isready` with the `POSTGRES_*` env.
- `run_filesystem_checks()` passed on all four directories **including**
  `Successfully created test hardlink in TV directory` under the single
  `/data` bind (the same test with three separate binds failed EXDEV).
- `GET /api/v1/health` → `{"message":"Hello World!","version":"v1.12.3"}`.
- `create_default_admin_user(): DEFAULT ADMIN USER CREATED!` from
  `admin_emails`.

**Preflight:** `mise clean && mise ign --server-name flutterina`, plus TOML
parse of the changed manifests.

## Deployment steps (out of IaC scope, tracked in the issue)

1. On `bow`, stop jellyfin, restructure the video subtree, hand it to UID 1000:
   ```
   sudo systemctl stop jellyfin.service
   sudo mkdir -p /var/lib/materia-data/video
   sudo mv /var/lib/materia-data/Movies /var/lib/materia-data/TVShows \
           /var/lib/materia-data/video/
   sudo mkdir -p /var/lib/materia-data/video/Downloads
   sudo chown -R 1000:1000 /var/lib/materia-data/video
   ```
   (`mv` is a rename within one filesystem — instant, no data copy.)
2. `materia update` on bow — installs mediamanager and restarts jellyfin onto
   the new host paths.
3. Pangolin dashboard: resource `mediamanager.<baseDomain>` →
   `mediamanager:8000` on bow's site. Leave Pangolin auth **enabled**.
4. `sudo podman logs mediamanager | grep -A3 'DEFAULT ADMIN USER CREATED'` for
   the generated admin password; log in and change it.

## Out of scope

- Download client (qBittorrent / SABnzbd) and indexer (Prowlarr / Jackett)
  components — MediaManager ships with all of them disabled and the
  `[torrents]`/`[indexers]` config sections stay at their defaults. Without a
  client it is a library manager + metadata browser; wiring one needs its own
  decision on VPN egress. The `Downloads` directory and the single-mount
  layout are in place so that follow-up is additive.
- OIDC (`[auth.openid_connect]`) and SMTP/notification providers.
- Custom `[[misc.tv_libraries]]` / `[[misc.movie_libraries]]` — one library
  per content type matches the on-disk layout.
- Self-hosting the metadata relay (`metadata_relay` image); the public relay
  default is kept.
