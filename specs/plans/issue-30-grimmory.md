# Implementation Plan — Issue #30: Add Grimmory as a materia component

**issue:** https://github.com/kitten-lily/materia/issues/30
**risk:** P2 (adds a new self-contained component; no changes to existing
services; exposed via Newt tunnel on `newt-net`, same pattern as the music
component — no host port exposure at all)
**epic:** standalone
**host:** bow (bare-metal, `[Roles.tunneled]` — newt-net
already present; same host as the music component)

## Summary

Add [Grimmory](https://grimmory.org) — a self-hosted library manager for
ebooks, comics, and audiobooks — as a materia component on flutterina.
Grimmory ships upstream as a two-service Docker Compose stack (app +
MariaDB); this plan translates that to Materia's quadlet + SOPS secrets
model using **two standalone containers on `newt-net`** (the music/beszel-hub
pattern), not a pod.

## Architecture decisions (locked)

### No pod — two standalone containers on `newt-net`

The original draft proposed a dedicated `grimmory.pod` (app + mariadb
sharing localhost) + `PublishPort=6060` + a Pangolin local-site resource.
**Revised**: use the established `newt-net` pattern instead — two
standalone containers, both joining `newt-net`, no pod, no `PublishPort`.
This is strictly better on every axis the pod approach traded on:

- **No host port exposure.** `PublishPort=6060` is gone entirely —
  eliminates the "unauthenticated 6060 exposure window" risk class the
  original draft flagged (same class as beszel-hub #22's port 8090).
  Newt reaches grimmory by container name `grimmory:6060` for the
  `grimmory.<baseDomain>` resource, same as `navidrome:4533`,
  `aonsoku:8080`, `beszel-hub:8090`.
- **app↔mariadb uses container-name DNS**, not localhost:
  `DATABASE_URL=jdbc:mariadb://grimmory-mariadb:3306/grimmory`. This is
  actually **closer to upstream's compose** (`mariadb:3306`) than the
  localhost translation the pod would have required — a named podman
  network is the compose-DNS equivalent (confirmed in AGENTS.md:
  "Container name resolution only works on named networks").
- **Precedent**: `components/music/` (navidrome + aonsoku, both standalone
  on `newt-net`, no pod). This is the established pattern for any non-edge
  service on a `[Roles.tunneled]` host. The pod was only ever needed for
  `pangolin.pod` (Gerbil's CGNAT tunnel IP reachability) — a constraint
  that doesn't apply here.
- **No local-site resource, no podman bridge gateway target.** The
  original draft's Pangolin UI step (local-site + resource pointing at the
  host IP / bridge gateway) is replaced by a Newt-tunnel resource
  (`grimmory.<baseDomain>` → `grimmory:6060`), configured in the Pangolin
  dashboard — same flow as the music resources on bow.

flutterina is already in `[Roles.tunneled]` (runs newt), so `newt-net`
already exists on the host.

### Component structure: one component, two containers

Unlike beszel (split into `beszel-hub` + `beszel-agent` because they run on
different hosts/roles), Grimmory's app and database both belong on the same
host and need to talk to each other constantly — a single
`components/grimmory/` component containing both quadlets, mirroring how
`pangolin` bundles three containers and `music` bundles two.

### Image provenance (resolved)

All three open image questions from the original draft are resolved:

- **App**: `ghcr.io/grimmory-tools/grimmory:v3.2.4@sha256:dfa7afdfcf25d649fd664497a62385dd00cd9678c37546e182c172e41c8e80cb`
  — GHCR over Docker Hub for pull reliability (no anonymous rate limits
  from flutterina's Hetzner IP). Both registries serve the identical index
  digest; GHCR chosen. v3.2.4 is the latest stable (2026-07-01). Renovate's
  existing `quadlet` manager (extended to `.gotmpl`) will track it.
- **MariaDB**: `reg.mini.dev/mariadb:12.3.2@sha256:93bfc249cf987c7fb62fc99900d3e20e3697c23fa562a419559d07df73bf1c9d`
  — minimus image (user's choice), non-root UID 1000. Same registry host
  as the existing traefik pin (`reg.mini.dev/traefik:3.7.7`). The minimus
  registry uses auth realm `auth.mini.dev` (not Docker Hub / GHCR) —
  podman pulls it fine (anonymous token from `auth.mini.dev`), but note
  the auth path if a pull ever fails to authenticate.

### UID/GID: 1000 for both (resolved)

- **App**: grimmory's entrypoint (`packaging/docker/entrypoint.sh`) reads
  `USER_ID`/`GROUP_ID` (default 1000) and drops privs via
  `su-exec "$USER_ID:$GROUP_ID"` — the linuxserver PUID/PGID convention,
  not a baked-in non-root `USER`. Set `USER_ID=1000`/`GROUP_ID=1000` env.
- **MariaDB**: minimus runs as non-root UID 1000 by default (per minimus
  docs + the AGENTS.md minimus gotcha). No `PUID`/`PGID` env needed — that
  was a linuxserver-image convention; minimus is already non-root.
- → All three named volumes (plus the books bind-mount dir on the
  host) get `User=1000`/`Group=1000` — per the minimus UID-1000 gotcha
  (podman named volumes are root-owned by default, and the data-disk
  subdirectory must be owned by UID 1000 so the `su-exec`-dropped app
  can write). No `User=`/`Group=` on the container definitions.

### MariaDB env: `MARIADB_*`, not `MYSQL_*` (translation from upstream)

Upstream's compose uses `MYSQL_ROOT_PASSWORD`/`MYSQL_DATABASE`/`MYSQL_USER`/
`MYSQL_PASSWORD` because it used the linuxserver mariadb image (which
accepts `MYSQL_*`). **Minimus mariadb uses the official MariaDB
convention** — `MARIADB_ROOT_PASSWORD`, `MARIADB_USER`, `MARIADB_PASSWORD`,
`MARIADB_DATABASE`. This is a required translation; `MYSQL_*` env vars are
silently ignored on the minimus image, leaving the DB uninitialized.

### Secrets: DB password + MariaDB root password via `secretEnv`

- `grimmoryDbPassword` — shared between the app (`DATABASE_PASSWORD` env)
  and mariadb (`MARIADB_PASSWORD` env) — same value, two `secretEnv` calls
  referencing the same declared secret name.
- `mariadbRootPassword` — mariadb `MARIADB_ROOT_PASSWORD` only.
- Both declared in the component manifest's top-level `Secrets = [...]`
  (must appear before any `[Table]` header — see the TOML-ordering gotcha).
- Stored in `attributes/bow.yml` (host-specific vault — grimmory is
  bow-only, single component, so no global hoisting needed per the
  attribute-scoping gotcha). The age key lives in Proton Pass
  (`fnox.toml` `SOPS_AGE_KEY`), resolved via `fnox exec` — not available
  locally without a Proton Pass session.

### Startup ordering: `Requires=`/`After=` + app retry (decided)

Docker Compose blocks the app until mariadb's healthcheck passes; quadlets
have no direct equivalent (`Requires=`/`After=` order unit *starts*, not
container *readiness*). **Decision**: `Requires=mariadb.service` +
`After=mariadb.service` on the app for start ordering, rely on the app's
own DB-connection retry (Spring Boot/HikariCP retries with backoff; the
container's `Restart=always` restarts it if it does crash on cold start).
Simplest option; matches the plan's recommendation.

**Flag for implementation**: verify at first `materia update` that the app
doesn't crash-loop before mariadb accepts connections. If it does, the fix
is `Restart=on-failure` + `RestartSec` on the app service — a manifest-only
tweak, no architecture change. Not pre-emptively added (don't fix what
isn't broken yet).

### MariaDB healthcheck: omitted (decided)

The minimus mariadb image runs as non-root UID 1000. Upstream's compose
healthcheck (`mariadb-admin ping -h localhost`) worked on the linuxserver
image because it ran as root and could auth via the local unix socket. On
minimus, UID 1000 can't do that without credentials
(`mariadb-admin ping -u grimmory -p$MARIADB_PASSWORD`). **Decision**: omit
the mariadb `HealthCmd` entirely for now — the grimmory app already ships a
built-in `HEALTHCHECK` (`wget /api/v1/healthcheck`), beszel-agent already
monitors container health on bow (beszel-agent is role-assigned to
  `[Roles.base]`, and bow has `Roles = ["base", "tunneled"]`), and the
  app's retry handles transient DB unavailability. Can add an adapted
  healthcheck (`mariadb-admin ping ... -u grimmory -p$$MARIADB_PASSWORD`)
  later if beszel/alerting needs DB-level health visibility.

### Exposure + auth: Newt tunnel + Pangolin SSO

- `grimmory.<baseDomain>` resource via Newt tunnel (target `grimmory:6060`
  by container name on `newt-net`), configured in the Pangolin dashboard.
  Same flow as the music resources on bow.
- **Pangolin's default Platform SSO auth on public resources is desirable
  here** (unlike beszel-agent #23's WebSocket, which the 302 redirect
  broke). Grimmory is a human-facing web UI accessed in a browser —
  authenticating through Pangolin SSO before reaching the app adds a
  layer, then the user hits Grimmory's own setup wizard / login. **Do not
  disable auth** on the `grimmory.<baseDomain>` resource.

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
Service = "grimmory-mariadb.service"
RestartedBy = ["grimmory-mariadb.container"]
```

**`grimmory.container.gotmpl`:**
```ini
[Unit]
Description=Grimmory app
Wants=network-online.target
After=network-online.target
Requires=grimmory-mariadb.service
After=grimmory-mariadb.service

[Container]
ContainerName=grimmory
Image=ghcr.io/grimmory-tools/grimmory:v3.2.4@sha256:dfa7afdfcf25d649fd664497a62385dd00cd9678c37546e182c172e41c8e80cb
# Join newt-net so Newt (on bow via [Roles.tunneled]) reaches
# grimmory by container name "grimmory:6060" for the
# grimmory.<baseDomain> resource, AND so the app can reach the mariadb
# sidecar by container name "grimmory-mariadb:3306". Container name
# resolution only works on named networks, not the default bridge — same
# reason beszel-hub, navidrome, aonsoku, and newt itself use
# Network=newt-net. Standalone container (no pod) — the music component
# pattern, not the pangolin.pod pattern.
Network=newt-net
Environment=USER_ID=1000
Environment=GROUP_ID=1000
Environment=TZ=Etc/UTC
Environment=DATABASE_URL=jdbc:mariadb://grimmory-mariadb:3306/grimmory
Environment=DATABASE_USERNAME=grimmory
{{ secretEnv "grimmoryDbPassword" "DATABASE_PASSWORD" }}
Volume=grimmory-data.volume:/app/data:z
# Books library — writable bind mount from bow's LVM data disk (same
# pattern as navidrome's /music bind). Large durable media belongs on
# /var/lib/materia-data, not a podman named volume on root storage.
# :z (writable, SELinux shared) — grimmory writes metadata/covers into
# the library. Pre-create on bow: sudo mkdir -p /var/lib/materia-data/Books
# && sudo chown 1000:1000 /var/lib/materia-data/Books
Volume=/var/lib/materia-data/Books:/books:z
Volume=grimmory-bookdrop.volume:/bookdrop:z

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**`grimmory-mariadb.container.gotmpl`:**
```ini
[Unit]
Description=Grimmory MariaDB
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=grimmory-mariadb
Image=reg.mini.dev/mariadb:12.3.2@sha256:93bfc249cf987c7fb62fc99900d3e20e3697c23fa562a419559d07df73bf1c9d
# Join newt-net so the grimmory app reaches it by container name
# "grimmory-mariadb:3306" (DATABASE_URL above). Same named-network
# requirement. No PublishPort — 3306 is reachable only by name on
# newt-net, never published to the host.
Network=newt-net
Environment=TZ=Etc/UTC
Environment=MARIADB_DATABASE=grimmory
Environment=MARIADB_USER=grimmory
{{ secretEnv "mariadbRootPassword" "MARIADB_ROOT_PASSWORD" }}
{{ secretEnv "grimmoryDbPassword" "MARIADB_PASSWORD" }}
Volume=grimmory-mariadb-config.volume:/var/lib/mysql:z

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

Note: minimus mariadb's data dir is `/var/lib/mysql` (official MariaDB
convention), **not** `/config` (the linuxserver convention the upstream
compose used). This is the second translation required by switching to
minimus.

**`grimmory-data.volume`, `grimmory-bookdrop.volume`,
`grimmory-mariadb-config.volume`:**
```ini
[Volume]
User=1000
Group=1000
```
(The minimus UID-1000 gotcha: podman named volumes are root-owned by
default; `User=`/`Group=` on the `.volume` quadlet creates them with the
right ownership so the non-root containers can write. Verify the actual
runtime UID against the images during implementation — the entrypoint's
`USER_ID`/`GROUP_ID` default is 1000, and minimus is UID 1000, so this
should match, but confirm with `podman inspect` after first pull if any
volume permission errors appear.)

### 2. `attributes/bow.yml` — DB secrets

```yaml
components:
    grimmory:
        grimmoryDbPassword: <encrypted>
        mariadbRootPassword: <encrypted>
```
Set via `fnox exec -- sops --set ...` (age key resolved from Proton Pass)
or `fnox exec -- sops edit attributes/bow.yml` — the age key is not
available locally without a Proton Pass session. Generate strong
passwords (e.g. `openssl rand -base64 24`) and inject programmatically
with `jq -Rs` to avoid any copy-paste corruption (per the BUG-003
convention, though these are simple strings, not multi-line keys).

### 3. `MANIFEST.toml` — wire the component

```toml
[Hosts.bow]
Components = ["music", "grimmory"]
Roles = ["base", "tunneled"]
```
(bow already has `Roles = ["base", "tunneled"]` — newt-net and the newt
client are already present; music is already assigned there.)

### 4. Pangolin UI configuration (manual, one-time, deploy-time)

Same flow as the music resources on bow:
1. Add a **public resource** `grimmory.<baseDomain>` with target
   `grimmory:6060` (container name on `newt-net` — Newt resolves it).
2. Add a DNS record for `grimmory.<domain>`.
3. **Keep Pangolin's default Platform SSO auth enabled** on the resource
   (do NOT disable it — unlike beszel-agent #23's WebSocket, this is a
   human-facing web UI; SSO before reaching the app is desirable).
4. Visit `https://grimmory.<domain>` → authenticate via Pangolin SSO →
   run Grimmory's setup wizard (admin account creation) → create a
   library pointing at `/books`.

### 5. `AGENTS.md` — document the component

Add to the repo layout (the `components/grimmory/` entry), plus gotchas
covering:
- **`newt-net` for both app↔mariadb AND Newt↔app routing** — the named
  network gives container-name DNS for both paths, eliminating the need
  for a pod's shared localhost. `DATABASE_URL` uses the mariadb container
  name (`grimmory-mariadb:3306`), closer to upstream compose than a
  localhost translation would be.
- **`MARIADB_*` env, not `MYSQL_*`** — minimus mariadb uses the official
  MariaDB env convention; the linuxserver image's `MYSQL_*` names are
  silently ignored. Required translation when switching from the upstream
  compose's linuxserver image to minimus.
- **minimus mariadb data dir is `/var/lib/mysql`, not `/config`** — the
  second translation required by the image switch (linuxserver used
  `/config`).
- **No `PublishPort`, no local-site resource** — the newt-net pattern
  eliminates the port-exposure risk class entirely. No `mise
  hz:podman-gateway` target needed.
- **Pangolin SSO auth kept on** — contrast with beszel-agent #23 (which
  needed auth disabled for the WebSocket handshake). Grimmory is
  human-facing; the SSO layer is desirable.

### 6. `renovate.json5` — verify (likely no change)

The existing `quadlet` manager (extended to match `.gotmpl` files) should
pick up both new pinned images. Verify on the next scheduled Renovate run
via the Dependency Dashboard:
- `ghcr.io/grimmory-tools/grimmory:v3.2.4@sha256:...`
- `reg.mini.dev/mariadb:12.3.2@sha256:...`

If the minimus registry (`reg.mini.dev`) isn't recognized by Renovate's
default registry list, add a `registryAliases` entry — but the existing
traefik pin on `reg.mini.dev` suggests it's already handled (verify it's
actually being tracked, not just present).

## Implementation steps

1. Create `components/grimmory/` (MANIFEST.toml, two containers, four
   volumes) with the pinned digests above.
2. Generate DB passwords + add `grimmoryDbPassword` +
   `mariadbRootPassword` to `attributes/bow.yml` (`fnox exec -- sops
   --set` with generated values, or `fnox exec -- sops edit` for manual).
3. Wire `MANIFEST.toml`: add `grimmory` to `Hosts.bow Components`.
4. `materia update` on bow → both containers start on `newt-net`;
   verify the app connects to mariadb by container name and doesn't
   crash-loop (the startup-ordering flag above).
5. In Pangolin UI: add `grimmory.<domain>` resource, target
   `grimmory:6060`, keep SSO auth enabled.
6. Add DNS record for `grimmory.<domain>`.
7. Visit the URL, authenticate via Pangolin SSO, run Grimmory's setup
   wizard, create the admin account and first library pointing at
   `/books`.
8. Update `AGENTS.md`.
9. Verify Renovate picks up both new images on the next scheduled run.

## Risks

- **Startup ordering may need a fallback.** If `Requires=`/`After=`
  ordering alone isn't sufficient (app crash-loops before mariadb is ready
  to accept connections), the fix is a manifest-only change
  (`Restart=on-failure` + `RestartSec`), not an architecture change —
  low risk, flagged above.
- **minimus mariadb data dir.** If `/var/lib/mysql` is wrong for this
  image version, the DB won't persist — verify with `podman inspect` +
  a write test after first `materia update`. The official MariaDB
  convention is `/var/lib/mysql`; minimus follows it, but confirm.
- **Pangolon SSO intercepting setup wizard.** If the first-time setup
  wizard can't be reached through Pangolon's SSO redirect (e.g. the
  wizard makes unauthenticated API calls that the SSO layer blocks),
  temporarily disable auth on the resource, complete setup, re-enable.
  Low likelihood — the wizard is browser-driven, same as the rest of
  the UI.
