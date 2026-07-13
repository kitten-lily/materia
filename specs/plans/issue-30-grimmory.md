# Implementation Plan — Issue #30: Add Grimmory as a materia component

**issue:** https://github.com/kitten-lily/materia/issues/30
**risk:** P2 (adds a new self-contained component; no changes to existing
services; exposed via Pangolin's own resource system, same pattern as
beszel-hub)
**epic:** standalone

## Summary

Add [Grimmory](https://grimmory.org) — a self-hosted library manager for
ebooks, comics, and audiobooks — as a materia component on flutterina.
Grimmory ships upstream as a two-service Docker Compose stack (app +
MariaDB); this plan translates that to Materia's pod + quadlet + SOPS
secrets model.

## Architecture decisions

### Component structure: one component, two containers, one pod

Unlike beszel (split into `beszel-hub` + `beszel-agent` because they run
on different hosts/roles), Grimmory's app and database both belong on the
same host and need to talk to each other constantly — a single
`components/grimmory/` component containing both quadlets, mirroring how
`pangolin` bundles three containers in one component.

### Pod: dedicated `grimmory.pod`, not `pangolin.pod`

Upstream's `docker-compose.yml` connects the app to the database via
Docker's compose-network DNS (`DATABASE_URL=jdbc:mariadb://mariadb:3306/grimmory`).
Materia/podman quadlets have no equivalent — this repo's pattern for
inter-container communication is a shared pod network namespace, where
containers reach each other over `localhost` (documented in AGENTS.md:
"Containers reach each other over localhost. In a pod, all containers
share one network namespace.").

**Chosen approach:** a dedicated `grimmory.pod`, not a join to
`pangolin.pod`. Two independent concerns:
- `pangolin.pod` membership is locked to the three containers that need
  Gerbil's CGNAT tunnel-endpoint routing (Traefik→Gerbil IP reachability).
  Grimmory has no such requirement.
- Putting an unrelated app in the edge pod's shared namespace would be
  the same isolation mistake explicitly avoided for beszel-hub ("a
  misbehaving hub could affect the gateway" — same reasoning applies to
  any non-edge service).

`DATABASE_URL` becomes `jdbc:mariadb://localhost:3306/grimmory` (was
`mariadb:3306` upstream) — the single required translation from the
compose file. Only port 6060 (the app) is published at the pod level;
3306 (mariadb) stays internal to the pod's namespace, never published.

### Exposure: Pangolin local site + resource, same pattern as beszel-hub

Grimmory's web UI needs to be reachable from outside the LAN (personal
library access). Following the beszel-hub precedent (#20/#22): the
`grimmory.pod` publishes port 6060 on the host, and a Pangolin **local
site + resource** (`grimmory.<baseDomain>`) is configured manually in the
Pangolin UI, pointing at the host's address (or podman bridge gateway
IP) on port 6060. This gets TLS + auth automatically via Pangolin's own
Traefik — no `dynamic_config.yml.gotmpl` changes.

**Same known risk as beszel-hub #22:** publishing 6060 with
`PublishPort=6060:6060` binds `0.0.0.0` on the host, because Pangolin
(running inside `pangolin.pod`'s own network namespace) cannot reach a
`127.0.0.1`-bound host port — it needs the host IP or the podman bridge
gateway. This exposes 6060 without TLS until the Pangolin resource is
configured. Mitigation options carried over from #22's resolution:
either accept the exposure window during setup (short-lived, manual
step), or add a Hetzner Cloud Firewall rule scoped to the setup period.
Resolved at deploy time, not in IaC — flag in `AGENTS.md`.

### Named volumes for all app-writable state

Per the data-dir-drift gotcha (`AGENTS.md`), the materia data dir
(`{{ m_dataDir "grimmory" }}`) is fully managed — anything not installed
by materia is drift and gets deleted on the next run. All four of
upstream's bind-mount directories are runtime-writable, so all four
become named volumes instead of data-dir bind mounts:

- `grimmory-data.volume` → `/app/data` (app settings, cache, logs)
- `grimmory-books.volume` → `/books` (library storage)
- `grimmory-bookdrop.volume` → `/bookdrop` (auto-import folder)
- `mariadb-config.volume` → `/config` (MariaDB data files)

### Secrets: DB password + MariaDB root password via `secretEnv`

- `grimmoryDbPassword` — shared between the app (`DATABASE_PASSWORD` env)
  and mariadb (`MYSQL_PASSWORD` env) — same value, two `secretEnv` calls
  referencing the same declared secret name.
- `mariadbRootPassword` — mariadb `MYSQL_ROOT_PASSWORD` only.
- Both declared in the component manifest's top-level `Secrets = [...]`
  (must appear before any `[Table]` header — see the TOML-ordering
  gotcha in `AGENTS.md`).
- Non-secret: `DB_USER`/`MYSQL_USER` (e.g. `grimmory`), `MYSQL_DATABASE`
  (`grimmory`), `USER_ID`/`GROUP_ID`/`PUID`/`PGID` (`1000`), `TZ`,
  `BOOKLORE_PORT` (`6060` — upstream's env var name; artifact of
  Grimmory being a Booklore-derived fork, not a naming choice we control).

### Startup ordering: compose `depends_on: condition: service_healthy` → quadlet HealthCmd + Requires/After

Docker Compose blocks the app container from starting until mariadb's
healthcheck passes. Quadlets have no direct equivalent — `Requires=`/
`After=` order unit *starts*, not container *readiness*. This repo
already solved an analogous problem for pangolin's `app`→`gerbil`/
`traefik` ordering: `Notify=healthy` + `HealthCmd` so systemd dependents
wait until the upstream service actually serves.

**Plan:** give the mariadb container `HealthCmd=mariadb-admin ping -h
localhost` (matches upstream's own healthcheck). Give the grimmory app
container `Requires=mariadb.service` + `After=mariadb.service` for start
ordering, and rely on the app's own connection-retry behavior (most JVM
apps like this retry DB connections with backoff rather than crash-loop
on first failure) to tolerate mariadb still initializing after the unit
starts but before the DB is actually accepting connections. **Needs
verification during implementation** — if the app crash-loops instead of
retrying, add `Restart=on-failure` with a short `RestartSec` on the app
service as a fallback.

## Files to create / modify

### 1. `components/grimmory/` (new)

**`MANIFEST.toml`:**
```toml
Secrets = ["grimmoryDbPassword", "mariadbRootPassword"]

[Defaults]

[[Services]]
Service = "grimmory.service"
RestartedBy = ["grimmory.container"]

[[Services]]
Service = "mariadb.service"
RestartedBy = ["mariadb.container"]
```

**`grimmory.pod`:**
```ini
[Unit]
Description=Grimmory library pod
Wants=network-online.target
After=network-online.target

[Pod]
PodName=grimmory
PublishPort=6060:6060

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**`grimmory.container.gotmpl`:**
```ini
[Unit]
Description=Grimmory app
Requires=mariadb.service
After=mariadb.service

[Container]
ContainerName=grimmory
Pod=grimmory.pod
Image=<registry>/grimmory/grimmory:<pinned-tag>@sha256:<digest>
Environment=USER_ID=1000
Environment=GROUP_ID=1000
Environment=TZ=Etc/UTC
Environment=DATABASE_URL=jdbc:mariadb://localhost:3306/grimmory
Environment=DATABASE_USERNAME=grimmory
Environment=BOOKLORE_PORT=6060
{{ secretEnv "grimmoryDbPassword" "DATABASE_PASSWORD" }}
Volume=grimmory-data.volume:/app/data:z
Volume=grimmory-books.volume:/books:z
Volume=grimmory-bookdrop.volume:/bookdrop:z

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**`mariadb.container.gotmpl`:**
```ini
[Unit]
Description=Grimmory MariaDB

[Container]
ContainerName=grimmory-mariadb
Pod=grimmory.pod
Image=lscr.io/linuxserver/mariadb:<pinned-tag>@sha256:<digest>
Environment=PUID=1000
Environment=PGID=1000
Environment=TZ=Etc/UTC
Environment=MYSQL_DATABASE=grimmory
Environment=MYSQL_USER=grimmory
{{ secretEnv "mariadbRootPassword" "MYSQL_ROOT_PASSWORD" }}
{{ secretEnv "grimmoryDbPassword" "MYSQL_PASSWORD" }}
Volume=mariadb-config.volume:/config:z
HealthCmd=mariadb-admin ping -h localhost
HealthInterval=5s
HealthTimeout=5s
HealthRetries=10

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

Note: no `[Install]` conflict between pod and containers — same pattern
as pangolin (pod carries `PublishPort`, member containers reference
`Pod=grimmory.pod` and carry no `PublishPort` of their own).

**`grimmory-data.volume`, `grimmory-books.volume`, `grimmory-bookdrop.volume`, `mariadb-config.volume`:**
```ini
[Volume]
User=1000
Group=1000
```
(Both images run as non-root via `USER_ID`/`GROUP_ID`/`PUID`/`PGID` env
mapping rather than a baked-in non-root `USER`, but the volumes still
need matching ownership so the mapped UID can write — verify against the
actual image's runtime UID during implementation, same caution as the
minimus UID-1000 gotcha.)

### 2. `attributes/flutterina.yml` — DB secrets

```yaml
components:
    grimmory:
        grimmoryDbPassword: <encrypted>
        mariadbRootPassword: <encrypted>
```

### 3. `MANIFEST.toml` — wire the component

```toml
[Hosts.flutterina]
Components = ["pangolin", "beszel-hub", "grimmory"]
Roles = ["base"]
```

### 4. Pangolin UI configuration (manual, one-time)

Same flow as beszel-hub (#20's step 6):
1. Create/reuse the existing **Local Site**.
2. Add a **public resource** `grimmory.<baseDomain>` with target
   `<flutterina-ip>:6060` (or the podman bridge gateway IP).
3. Add a DNS record for `grimmory.<domain>`.
4. Visit `https://grimmory.<domain>` → run Grimmory's own setup wizard
   (admin account creation) → create a library pointing at `/books`.

### 5. `AGENTS.md` — document the component

Add to the repo layout, plus gotchas covering:
- `grimmory.pod` and the `mariadb:3306` → `localhost:3306` translation
  (compose-network DNS has no pod equivalent)
- The `HealthCmd` + `Requires=`/`After=` startup-ordering approach and
  its "needs verification" caveat
- Named volumes for all four app-writable directories (data-dir-drift
  gotcha applies to any component with runtime-writable state, not just
  pangolin)

### 6. `renovate.json5` — verify (likely no change)

The existing `quadlet` manager already matches all `.container.gotmpl`
files via `managerFilePatterns`. Both new images need versioned tags
(not `latest`) before Renovate can track them — resolve the image-pinning
open question first (see below), then verify Renovate picks up both on
the first scheduled run via the Dependency Dashboard.

## Open questions (must resolve before implementation)

- **Image registry + pinned tag for `grimmory/grimmory`.** The marketing
  site's compose example uses `grimmory/grimmory:latest` with no visible
  versioned-tag documentation. Repo convention is pinned digests, no
  `AutoUpdate=registry` (see "Pinned image digests" in AGENTS.md's locked
  architecture decisions). Check the upstream GitHub repo
  (`grimmory-tools/grimmory`) releases/tags and registry (Docker Hub vs
  GHCR) before writing the `.container.gotmpl`.
- **MariaDB image tag.** Upstream's example pins `lscr.io/linuxserver/mariadb:11.4.5`
  — confirm this is still current and grab its digest at implementation
  time (`docker:pinDigests` in `renovate.json5` will keep the digest
  fresh once pinned; the tag itself needs a human bump via Renovate PR
  when a new MariaDB minor/major is desired).
- **Runtime UID for the app image.** Need to confirm at implementation
  time whether `grimmory/grimmory` actually maps `USER_ID`/`GROUP_ID` to
  file ownership the way linuxserver.io's `PUID`/`PGID` convention does,
  or whether it needs `User=`/`Group=` at the container level instead of
  (or in addition to) the `.volume` files.
- **Health-gating verification.** Confirm the app tolerates mariadb not
  yet accepting connections at `Requires=`/`After=` unit-start time
  (retry-with-backoff vs crash-loop). If it crash-loops, add
  `Restart=on-failure` + `RestartSec` to the app service as a fallback —
  no IaC redesign needed, just a manifest tweak.

## Implementation steps

1. Resolve the open questions above (registry, tags, digests, UID
   mapping) — likely requires pulling both images locally and inspecting.
2. Create `components/grimmory/` (MANIFEST.toml, pod, two containers,
   four volumes) with pinned digests.
3. Add `grimmoryDbPassword` + `mariadbRootPassword` to
   `attributes/flutterina.yml` (`sops edit`).
4. Wire `MANIFEST.toml`: add `grimmory` to `Hosts.flutterina Components`.
5. `materia update` on flutterina → pod + both containers start; verify
   mariadb health passes before the app container is considered up.
6. In Pangolin UI: add `grimmory.<domain>` local-site resource, target
   `<flutterina-ip>:6060`.
7. Add DNS record for `grimmory.<domain>`.
8. Visit the URL, run Grimmory's setup wizard, create the admin account
   and first library.
9. Update `AGENTS.md`.
10. Verify Renovate picks up both new images on the next scheduled run.

## Risks

- **Port 6060 exposed on the host** (same class of risk as beszel-hub
  #22's port 8090 exposure) — unauthenticated access to Grimmory's setup
  wizard / login page until the Pangolin resource + any firewall rule are
  in place. Time-box the exposure window; consider a Hetzner Cloud
  Firewall rule scoped to 6060 during initial setup only.
- **Startup ordering may need a fallback.** If `Requires=`/`After=`
  ordering alone isn't sufficient (app crash-loops before mariadb is
  ready to accept connections), the fix is a manifest-only change
  (`Restart=on-failure`), not an architecture change — low risk, flagged
  above.
- **Image provenance unconfirmed.** Unlike beszel (upstream on Docker Hub
  with clear semver tags, confirmed via GitHub source), Grimmory's exact
  registry/tag/digest needs to be resolved from the actual upstream repo
  before any `.container.gotmpl` can be written — this plan intentionally
  leaves those as placeholders rather than guessing.
