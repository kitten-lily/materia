# Media apps and SilentSuite

Read this guide when changing media apps, SilentSuite, DB sidecars, hardlinks, image pins, or SSO.

- **A pinned image tag whose *precision* no upstream tag matches makes
  Renovate go permanently silent on that image — no PR, no dashboard
  entry, no error.** Renovate's `docker` versioning is
  precision-matching by design (docs: "a user on `12.14` expects to be
  upgraded to `12.15` and not `12.15.0`"), so a three-part pin can only
  ever be offered three-part tags. `jellyfin` dropped the leading `10.`
  in its version scheme (`10.11.x` → `12.0` → `12.1`) and now publishes
  only two-part stable tags, so `components/jellyfin/`'s
  `10.11.11@sha256:…` pin became unupgradable: 19 days after 12.0
  shipped (with security fixes), dependency dashboard #6 still listed
  jellyfin with no available update, and the pinned digest was still
  current for the dead tag — so the digest watch was quiet too. This
  fails *open and silent*: the image just stops appearing in Renovate
  traffic, which reads exactly like "no updates available". Fix is a
  per-image `versioning:` override with an explicit regex (see
  `specs/plans/jellyfin-12-upgrade-evaluation.md`); prefer regex over
  `loose`, since `loose` will happily propose jellyfin's dated
  `2026092110`/`unstable` builds as giant "major" upgrades. When an
  upstream renames or re-shapes its version scheme, re-check that the
  repo's pin still has the same number of parts as the new tags.
- **A major jellyfin upgrade can silently reset a whole config file —
  check `config/*.xml` against the pre-upgrade backup, not just
  "does it start".** Jellyfin 12.1 refuses to deserialize a 10.11
  `config/encoding.xml` that contains `<EncoderPreset xsi:nil="true" />`
  (`Instance validation error: '' is not a valid value for
  EncoderPreset`), emits exactly one `[ERR] BaseConfigurationManager:
  Error loading configuration file` line during startup, and then
  **rewrites the file from defaults**. On bow (2026-09-27) that turned
  `HardwareAccelerationType=qsv` + `QsvDevice=/dev/dri/renderD128` +
  five hardware decode codecs into `none` / empty / two codecs, i.e.
  every transcode silently dropped to `libx264` on the CPU while the
  server stayed `(healthy)` and every playback still worked. Nothing
  else reports it — this is exactly the failure mode #47 describes.
  Diff the old file out of the pre-upgrade tarball
  (`tar -xOf <backup>.tar _data/config/encoding.xml`) against the live
  one and restore the deltas through the API
  (`POST /System/Configuration/encoding`) rather than hand-editing the
  file under a running server. Verify the fix from the transcode log:
  `-init_hw_device vaapi=…,driver=iHD -init_hw_device qsv=qs@va
  -codec:v:0 h264_qsv` means the hardware path is live; `-codec:v:0
  libx264` means it is not.

- **Grimmory: two standalone containers on `newt-net`, not a pod.** Unlike
  `pangolin.pod` (which exists so Traefik can reach Gerbil's CGNAT tunnel
  IPs), the grimmory app + MariaDB sidecar have no shared-namespace
  requirement — they reach each other by **container name**
  (`grimmory-mariadb:3306`) on the named `newt-net` network, and Newt
  reaches the app by container name (`grimmory:6060`) for the
  `grimmory.<baseDomain>` resource. This is the same pattern as the
  `music` component (navidrome + aonsoku, both standalone on `newt-net`,
  no pod). No `PublishPort` at all — port 6060 is never bound on the
  host, eliminating the port-exposure risk class that beszel-hub #22
  and the original grimmory draft (a dedicated `grimmory.pod` with
  `PublishPort=6060`) carried. A named podman network is the
  compose-DNS equivalent — `DATABASE_URL=jdbc:mariadb://grimmory-mariadb:3306/grimmory`
  is closer to upstream's compose (`mariadb:3306`) than a localhost
  translation would be. Container name resolution only works on named
  networks, not the default bridge — the same reason every
  tunnel-reachable service in this repo uses `Network=newt-net`.
- **The official MariaDB image uses `MARIADB_*` env, not `MYSQL_*`; data
  dir is `/var/lib/mysql`, not `/config`.** Upstream's grimmory compose used
  the linuxserver mariadb image (`lscr.io/linuxserver/mariadb`), which
  accepts `MYSQL_ROOT_PASSWORD`/`MYSQL_DATABASE`/`MYSQL_USER`/
  `MYSQL_PASSWORD` and stores data in `/config`. The official convention
  (minimus followed it too) is `MARIADB_ROOT_PASSWORD`/`MARIADB_USER`/
  `MARIADB_PASSWORD`/`MARIADB_DATABASE`, with data in `/var/lib/mysql`.
  `MYSQL_*` vars are **silently ignored**, leaving the DB uninitialized
  with no error (the app then fails with a connection refusal). Don't
  carry the linuxserver names over from upstream's compose.
- **minimus (`reg.mini.dev`) closed anonymous pulls around 2026-10-22,
  and nothing failed loudly.** After the echo.ai acquisition,
  `auth.mini.dev/api/v1/registry/token` answers 403. The only signal was
  Renovate's dependency dashboard (#6): `Failed to look up docker package
  reg.mini.dev/…: no-result`. Running containers kept going on cached
  images, but no more security updates arrived, and a rebuilt or pruned
  host could not have pulled traefik at all (no edge). traefik, grimmory's
  mariadb and mediamanager's postgres moved to Docker Official Images at
  the same versions (plan: `specs/plans/minimus-exit.md`). Takeover of the
  minimus-written data was smoke-tested locally first:
  - mariadb's and postgres's root entrypoints chown a UID-1000 datadir to
    999 and keep the data;
  - root traefik reads the UID-1000, mode-600 `acme.json`.

  `mise db:backup` takes the dump, row counts and volume tar before any
  DB image change, and `--compare` checks the counts afterwards. **Read
  the Renovate dashboard's lookup failures**: an image that stops getting
  lookups is frozen, not current.
- **Pangolin SSO is OFF for grimmory, audiobookshelf, jellyfin and
  pinepods — only Media Manager has it.** Earlier versions of AGENTS.md said SSO was
  "kept ON" for the three media apps; the live dashboard (Pangolin API,
  2026-10-23) has `sso: 0` on every resource except Media Manager, and
  each app's own login is the only auth layer. Any non-browser client
  hits the same failure as beszel-agent #23: Pangolin's SSO answers an
  unauthenticated request with a `302` to its interactive login page,
  which native apps talking straight to the API (Jellyfin TV/mobile
  clients, the Audiobookshelf app, OPDS/e-reader sync, PinePods' apps
  and gPodder clients) cannot follow. PinePods kept SSO **on** only until
  its first admin existed: its `POST /api/data/create_first` is
  unauthenticated (#196).
  Before turning SSO on for a resource, confirm every client of it is a
  browser; Media Manager is browser-only, which is why it can keep it.
- **Audiobookshelf: standalone on `newt-net`, audiobooks only — no
  ebook library, and no podcasts since #196.** Same standalone-container-on-`newt-net`
  pattern as `music`/`grimmory` (no pod — single container, no
  shared-namespace requirement). Deliberately omits upstream's `/books`
  volume from its [podman quadlet example](https://audiobookshelf.org/docs/documentation/install/podman)
  — `grimmory` already owns ebook/comic hosting on `bow`, so wiring a
  second ebook-scanning path would duplicate that content type across
  two components. `AudioBooks` is mounted **read-only** (`:ro,z`) since
  audiobookshelf shouldn't modify source audiobook files. Podcasts
  used to be a read-write `Podcasts` mount here. #196 moved them to
  `pinepods`, which owns `/var/lib/materia-data/Podcasts` with a private
  `:Z` label and UID 1000, so don't re-add that mount to audiobookshelf.
  The mount mode still differs by library: check whether an app writes
  into a library before copying another library's mode onto it. `/config` and `/metadata` are named volumes (not
  bind mounts) for the same data-dir-drift reason as every other
  app-writable state directory in this repo. Pangolin SSO is off — see
  the SSO bullet above. [Materia data-dir behavior](materia-behaviour.md)
- **Jellyfin: standalone on `newt-net`, movies + TV only, HW transcoding
  needs on-host verification.** Same standalone-container-on-`newt-net`
  pattern as `music`/`grimmory`/`audiobookshelf` (no pod). Movies and
  TVShows are mounted **read-only** (`:ro,z`) — jellyfin only reads media
  and writes metadata/artwork into `/config`, not the source files — same
  reasoning as navidrome's/audiobookshelf's read-only media mounts. No
  music library: `music`'s navidrome already owns that content type on
  `bow` (same reasoning audiobookshelf used to exclude a `/books` mount,
  owned by `grimmory`). `/config` and `/cache` are named volumes for the
  same data-dir-drift reason as every other app-writable state directory
  in this repo. **`AddDevice=/dev/dri:/dev/dri` for hardware-accelerated
  transcoding is unverified against the live host** — confirm `/dev/dri`
  actually exists on `bow` (`ls /dev/dri`) and check `getenforce` before
  assuming the passthrough is effective; if SELinux is enforcing and
  `container-selinux` ≥2.226, the container also needs `sudo setsebool -P
  container_use_dri_devices 1` run once on the host (not managed by
  Ignition/materia — a manual step, like changes to the Pangolin dashboard). If the device isn't
  present or the boolean isn't set, jellyfin silently falls back to CPU
  transcoding rather than hard-failing, so this is easy to miss unless
  explicitly checked. Pangolin SSO is off — see the SSO bullet above.
- **Hardlinks can't cross mount points, even on one filesystem — so a
  media manager and its downloads directory need a *single* bind mount.**
  `mediamanager` hardlinks a finished download from `torrent_directory`
  into the library instead of copying it, and probes exactly that at
  startup (`run_filesystem_checks()`). Linux's `link()` refuses when the
  two paths sit on different mounts regardless of the underlying
  filesystem, so the obvious per-library bind layout every other
  component here uses (`Volume=/var/lib/materia-data/Movies:…`,
  `…/TVShows:…`, `…/Downloads:…`) fails with `OSError: [Errno 18]
  Invalid cross-device link` and silently degrades to full file copies —
  two copies of every import, on a disk already ~94% used. Confirmed by
  local smoke test before deploy, on sibling directories of one tmpfs.
  Fix: bow's video content lives under a single parent,
  `/var/lib/materia-data/video/{Movies,TVShows,Downloads}`, bind-mounted
  once as `Volume=/var/lib/materia-data/video:/data:z`. `jellyfin`'s two
  read-only mounts were repointed at the same subtree; their
  *container-side* paths (`/media/Movies`, `/media/TVShows`) are
  unchanged, so jellyfin's library DB needs no re-scan. Binding
  `/var/lib/materia-data` wholesale would also have worked but hands the
  app read-write access to buildbarn's CAS and every other library —
  rejected. Any future component that hardlinks between two
  materia-data paths must keep them under one bind.
- **MediaManager's `CONFIG_FILE` env var cannot be set from outside the
  container — use `CONFIG_DIR`.** `media_manager/config.py` honours
  `CONFIG_FILE` first and `$CONFIG_DIR/config.toml` second, which reads
  like an invitation to point `CONFIG_FILE` straight at a
  materia-installed file. It doesn't work: `mediamanager-startup.sh`
  executes `CONFIG_FILE="$CONFIG_DIR/config.toml"`, and reassigning an
  already-exported shell variable keeps the export, so the app child
  process inherits the script's value. The failure is silent and
  confusing — the app reads the image's bundled example config and dies
  with `failed to resolve host 'db'` (the compose service name from
  upstream's example), not with any config-path error. Set
  `CONFIG_DIR=/etc/mediamanager` and mount the templated file there
  instead. Pair it with `LOG_FILE=/tmp/media_manager.log`: the rotating
  file handler is hardcoded to `/app/config/media_manager.log`, which
  stops existing once `CONFIG_DIR` moves, and `dictConfig` hard-fails
  (`ValueError: Unable to configure handler 'file'`). Both were found by
  running the real image locally, not by reading the source.
- **Run MediaManager as `User=1000` — its entrypoint's root branch
  recursively chowns the entire media library on every start.**
  `mediamanager-startup.sh` checks `id -u`: as root it runs
  `chown -R mediamanager:mediamanager /data` whenever `stat -c '%U'
  /data` isn't already `mediamanager`, and `/data` is a container-layer
  directory (only its children are mounted), so it is root-owned again
  after *every* container recreate — including every Renovate digest
  bump. As non-root the script skips permission fixing entirely. Running
  as root would additionally `chown -R "$CONFIG_DIR"`, which fails hard
  against the read-only config mount under the script's `set -eEuo
  pipefail`. Cost of `User=1000`: host-side bind sources must be owned
  `1000:1000` (deploy step), and named volumes the app writes need
  `User=1000`/`Group=1000` per the existing UID-1000 volume gotcha.
- **Official postgres 18 needs `PGDATA=/var/lib/postgresql/data` set
  explicitly.** The official 18+ image moved its default `PGDATA` to
  `/var/lib/postgresql/18/docker`. With an existing cluster mounted at
  `/var/lib/postgresql/data` (minimus's path, and the 17-era default) and
  no override, it **refuses to start** with exit 1: `Error: in 18+, these
  Docker images are configured to store database data in a format …
  there appears to be PostgreSQL data in: /var/lib/postgresql/data (unused
  mount/volume)`. A failing service fails `materia-update` for the whole
  host. Confirmed locally; `mediamanager-postgres.container.gotmpl` sets
  the override. The `POSTGRES_USER`/`POSTGRES_DB`/`POSTGRES_PASSWORD`
  contract is the same as minimus. **Changing the image's distro changes
  glibc, and with it postgres's collation version.** After the swap,
  every connection warned `database "mediamanager" has a collation version
  mismatch … created using collation version 2.44, but the operating
  system provides version 2.41` (minimus/Wolfi → Debian). Text indexes
  built under the old sort order can misorder non-ASCII keys. Fix, per
  database (`mediamanager`, `postgres`, `template1`): `REINDEX DATABASE`,
  then `ALTER DATABASE … REFRESH COLLATION VERSION`. MariaDB has no
  equivalent problem: it ships its own collations. The `.volume` stays root-owned with no
  `User=`/`Group=`: the entrypoint chowns `PGDATA` itself. Was pinned to
  the 17 series (18 relocated the data directory, which would silently
  re-init an empty cluster on an existing volume) until issue #104
  (2026-09-17): mediamanager wasn't in production
  use yet, so the bump to v18.6 was landed as a rebuild-in-place (wipe
  `mediamanager-db.volume`, let v18's entrypoint init a fresh cluster) —
  NOT a `pg_dump`/`pg_upgrade` migration. **That wipe was never executed
  on bow, and the bump took the whole host down for four days — see the
  [reconciliation failure notes](materia-behaviour.md).** A future major bump against a volume with real data
  needs an actual dump/restore or `pg_upgrade` path, not this shortcut.
  `pg_isready` is present, so `HealthCmd` + `Notify=healthy` can gate a
  dependent app's start — needed here because MediaManager runs
  `alembic upgrade head` in its entrypoint and exits non-zero (rather
  than retrying) when the DB isn't up yet.

## Resource map

```text
  music/                        # Navidrome music server + Aonsoku web client (standalone, bow-only)
    MANIFEST.toml                # component manifest — Defaults, Services (no Secrets)
    navidrome.container.gotmpl    # Navidrome server, joins newt-net, read-only /music bind, navidrome.<baseDomain>
    aonsoku.container.gotmpl      # Aonsoku web client, joins newt-net, SERVER_URL=navidrome public URL, music.<baseDomain>
    navidrome-data.volume         # named volume for /data (DB, cache; root-owned, no User=/Group=)
  grimmory/                     # Grimmory ebook/comic/audiobook library + MariaDB sidecar (standalone, bow-only)
    MANIFEST.toml                # component manifest — Secrets (grimmoryDbPassword, mariadbRootPassword), Services
    grimmory.container.gotmpl     # Grimmory app, joins newt-net, /books bind from LVM data disk, grimmory.<baseDomain>
    grimmory-mariadb.container.gotmpl # MariaDB sidecar (Docker Official Image), joins newt-net, no PublishPort, MARIADB_* env
    grimmory-data.volume          # named volume for /app/data (UID 1000)
    grimmory-bookdrop.volume      # named volume for /bookdrop (UID 1000)
    grimmory-mariadb-config.volume # named volume for /var/lib/mysql (entrypoint chowns it to mysql/999)
  audiobookshelf/                # Audiobookshelf audiobook server (standalone, bow-only; podcasts moved to pinepods, #196)
    MANIFEST.toml                # component manifest — Defaults, Services (no Secrets)
    audiobookshelf.container.gotmpl # joins newt-net, ro AudioBooks bind from LVM data disk, audiobookshelf.<baseDomain>
    audiobookshelf-config.volume  # named volume for /config (root-owned, no User=/Group=)
    audiobookshelf-metadata.volume # named volume for /metadata (root-owned, no User=/Group=)
  jellyfin/                      # Jellyfin movies + TV media server (standalone, bow-only)
    MANIFEST.toml                # component manifest — Defaults, Services (no Secrets)
    jellyfin.container.gotmpl     # joins newt-net, /dev/dri passthrough, ro Movies + TVShows binds from LVM data disk (under video/), jellyfin.<baseDomain>
    jellyfin-config.volume        # named volume for /config (root-owned, no User=/Group=)
    jellyfin-cache.volume         # named volume for /cache (root-owned, no User=/Group=)
  mediamanager/                  # MediaManager TV + movie management ("Arr" replacement, standalone, bow-only)
    MANIFEST.toml                # component manifest — Secrets (mediamanagerTokenSecret, mediamanagerDbPassword), Services
    mediamanager.container.gotmpl # app, joins newt-net, runs as UID 1000, single rw bind of LVM video/ subtree, mediamanager.<baseDomain>
    mediamanager-postgres.container.gotmpl # postgres 18 sidecar (Docker Official Image, PGDATA override), joins newt-net, Notify=healthy gates the app
    config.toml.gotmpl            # templated backend config, mounted read-only via CONFIG_DIR (see gotchas)
    mediamanager-db.volume        # named volume for /var/lib/postgresql/data (root-owned, entrypoint chowns it)
    mediamanager-images.volume    # named volume for the poster cache at /images (UID 1000)
  pinepods/                      # PinePods podcast server + gPodder sync, replaces abs podcasts (standalone, bow-only, #196)
    MANIFEST.toml                # component manifest — Secrets (pinepodsDbPassword), Services
    pinepods.container.gotmpl    # app, joins newt-net, PUID/PGID=1000 (not User=), rw Podcasts + pinepods-backups binds, body-checking HealthCmd, pods.<baseDomain>
    pinepods-postgres.container.gotmpl # postgres 18 sidecar (same pin as mediamanager's, PGDATA override, DB name = user), Notify=healthy
    pinepods-valkey.container.gotmpl # required valkey sidecar, ephemeral (no volume, smoke-tested), Notify=healthy
    pinepods-db.volume            # named volume for /var/lib/postgresql/data (root-owned, entrypoint chowns it)
  silentsuite/                   # SilentSuite E2E calendar/contacts/tasks sync server + Postgres 16 sidecar (standalone, bow-only, #192)
    MANIFEST.toml                # Secrets: silentsuiteDbPassword, silentsuiteDbIni, silentsuiteBootstrapToken, silentsuiteRegistrationToken (from `mise silentsuite:init-secrets`; the bootstrap token is removed after --close, --bootstrap re-adds it)
    silentsuite.container.gotmpl # server, newt-net, no PublishPort, TRUSTED_PROXY_IPS=10.89.0.0/16, CORS app.silentsuite.io only, strict is_etebase healthcheck; both tokens behind {{ if exists }}
    healthcheck.py               # the HealthCmd: exit 0 only on exactly 200 from is_etebase (mounted; in RestartedBy)
    silentsuite-postgres.container.gotmpl # postgres 16.16-alpine (upstream's tested major), default PGDATA
    etebase-server.ini.gotmpl    # allowed_hosts silentsuite.<baseDomain> + localhost; NEVER a password: the silentsuiteDbIni secret supplies it, and this file is read after it, so it would win
    silentsuite-data.volume      # /data: secret.txt (Django SECRET_KEY), media, static (etebase UID 100 via copy-up)
    silentsuite-db.volume        # Postgres data
```

For a major database upgrade's effect on reconciliation, see [Materia behaviour](materia-behaviour.md). For SilentSuite's `Host` header on Pangolin checks, see [Pangolin edge](pangolin-edge.md).
