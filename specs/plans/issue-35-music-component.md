# Implementation Plan — Issue #35: Add music component (navidrome + aonsoku)

**issue:** https://github.com/kitten-lily/materia/issues/35
**risk:** P2 (adds a new self-contained component on `bow`; no changes to
existing services; exposed via the established Newt tunnel + newt-net
pattern, same as beszel-hub)
**epic:** standalone

## Summary

Add a `music` component running [Navidrome](https://www.navidrome.org)
(self-hosted music server) and [Aonsoku](https://github.com/victoralvesf/aonsoku)
(a modern Navidrome/Subsonic web client) on `bow`, exposed at
`music.<baseDomain>` via the existing Newt tunnel.

## Architecture decisions

### Component structure: one component, two standalone containers (no pod)

Both navidrome and aonsoku belong on the same host (`bow`) but run as
**standalone containers** on `newt-net`, not in a shared pod. The
original plan used a `music.pod` so aonsoku could reach navidrome over
`localhost:4533`, but aonsoku is a **browser SPA** — its JavaScript runs
in the user's browser, not in the container. The SPA's requests hit
navidrome's *public* URL (`https://navidrome.<baseDomain>`), not the
container's localhost. So the pod's shared-namespace rationale doesn't
apply, and bundling them in a pod would only couple their restarts for
no benefit. Each container is standalone, joining `newt-net` for tunnel
exposure (same ×2 pattern as beszel-hub, which is itself standalone
rather than in `pangolin.pod` for the same isolation reasoning).

### Pod: none (standalone containers)

Dropped the `music.pod` (see component-structure decision above). Both
containers join `newt-net` directly. No `PublishPort` — exposure is via
Newt tunnel + `newt-net` (container name resolution), not host port
binding. This avoids the `0.0.0.0` bind exposure window that
beszel-hub's `PublishPort=8090` carries (see grimmory spec's "same known
risk as beszel-hub #22").

### Exposure: two Newt-tunneled resources, navidrome.<baseDomain> + music.<baseDomain>

Both containers join `newt-net`. Newt (already on `bow` via
`[Roles.tunneled]`) reaches navidrome by container name `navidrome:4533`
and aonsoku by `aonsoku:8080`. Two Pangolin local-site + resources are
configured manually in the dashboard at deploy time:

- `navidrome.<baseDomain>` → `navidrome:4533` — the music server (web UI,
  Subsonic API). Aonsoku's SPA will call this URL from the browser.
- `music.<baseDomain>` → `aonsoku:8080` — the aonsoku web client.

Both get TLS + auth via Pangolin's Traefik, no
`dynamic_config.yml.gotmpl` changes. Same known property as beszel-hub:
container name resolution only works on named networks, not the default
bridge — hence the explicit `Network=newt-net` on each container.

### Navidrome music library: `/var/lib/materia-data/Music`, read-only bind mount

Navidrome needs a read-only music library path. The user chose
`/var/lib/materia-data/Music` — the LVM data mount on `bow` (created by
`bare-metal.bu`'s `lvm-data.service` at `/var/lib/materia-data`). The
container bind-mounts it read-only at `/music:ro,z` (the `z` for SELinux
relabel, matching the old compose's `:ro,z` and the restic-backup
read-only bind pattern). The path existing on the host is a deploy-time
prerequisite — `lvm-data.service` must have run (it does on every
provisioned bare-metal box), and the user populates the directory at
deploy time.

### Aonsoku config: HIDE_SERVER=true, SERVER_URL=navidrome public URL, SERVER_TYPE=navidrome

Per the user's spec, aonsoku runs with:
- `HIDE_SERVER=true` — hides the server URL field on login (only
  username/password shown), since the server is fixed.
- `SERVER_URL=https://navidrome.{{ .baseDomain }}` — composed from the
  global `baseDomain` attribute (same pattern as beszel-hub's `APP_URL`
  and newt's `PANGOLIN_ENDPOINT`). This is the **public** navidrome URL
  (the `navidrome.<baseDomain>` resource), because aonsoku is a browser
  SPA — its requests originate from the user's browser, not the
  container, so it must reach navidrome's public endpoint, not a
  localhost/pod-internal address. The URL is a public hostname, not a
  secret, so it's a templated `Environment=` line, not a podman secret.
  This matches the user's instruction ("set to a secret/attribute ... value
  https://music.ririi.dev") via the attribute path — `baseDomain` is
  already in the vault as a global, no new secret needed.
- `SERVER_TYPE=navidrome` — tells aonsoku to apply navidrome-specific
  behavior (vs `subsonic`/`lms`).

Aonsoku's `APP_USER`/`APP_PASSWORD` (automatic login) are **not** set —
the `.env.example` warns these compromise the password if publicly
exposed, and `music.<baseDomain>` is public. Users log in with their
navidrome credentials via the form.

### Aonsoku exposure

Aonsoku (port 8080) is on `newt-net` and gets its own Pangolin resource
at `music.<baseDomain>` (separate from navidrome's
`navidrome.<baseDomain>`). Both are dashboard-configured local-site +
resource entries, no `dynamic_config.yml.gotmpl` change. See the
exposure decision above for the full mapping.

### Images: both pinned by digest, Renovate-tracked

- `docker.io/deluan/navidrome:0.63.2@sha256:9012939...` — latest stable,
  digest resolved via `skopeo inspect`. Runs as root (alpine-based, no
  baked-in non-root `USER`) — same as beszel-hub, so no `User=`/`Group=`
  on the data volume.
- `ghcr.io/victoralvesf/aonsoku:latest@sha256:9bdfc8f1...` — the README
  only publishes a `:latest` tag (no version tags on the GHCR registry),
  so this pins `latest` by digest. Renovate's native `quadlet` manager
  (already extended to match `*.container.gotmpl`) will track digest
  bumps for both. **Note:** aonsoku has no version tags, so Renovate
  can only bump the digest (tag stays `latest`) — covered by the
  existing `digest` automerge rule in `renovate.json5`.

### Navidrome data: named volume, root-owned

`navidrome-data.volume` → `/data` (navidrome's `--datafolder`, holds the
DB). Root-owned (no `User=`/`Group=`) since the image runs as root —
same reasoning as beszel-hub's `beszel-data.volume`. The cache folder
defaults to the data folder (`/data/cache`), so no separate cache volume
needed for a personal library.

### Navidrome env: telemetry off, scanning interval

`ND_ENABLEINSIGHTSCOLLECTOR=false` (matches the old compose — disables
anonymous usage telemetry). `ND_LOGLEVEL=info` (default). No
`ND_MUSICFOLDER` env — navidrome reads the `--musicfolder` flag default
(`music`), but we bind to `/music` via the `MusicFolder`-equivalent: the
volume mount puts the library at `/music`, and navidrome's default
`--musicfolder=music` resolves to the relative `./music` under the data
dir. **Correction during implementation:** set `ND_MUSICFOLDER=/music`
explicitly so the bind-mounted path is used, not the data-dir-relative
default. (The old compose relied on the volume mount at `/music` being
picked up by the default — verify this works or set the env explicitly.)

## Files to create / modify

### 1. `components/music/` (new)

**`MANIFEST.toml`:**
```toml
[Defaults]

[[Services]]
Service = "navidrome.service"
RestartedBy = ["navidrome.container"]

[[Services]]
Service = "aonsoku.service"
RestartedBy = ["aonsoku.container"]
```
No `Secrets` — `SERVER_URL` is composed from the existing `baseDomain`
global, not a new secret. No `Oneshot`/`Stopped`/`Static` — both are
long-running `Restart=always` services. No `music-pod.service` — both
containers are standalone (no pod, see architecture decision above).

**`music.pod`:**
```ini
[Unit]
Description=Music pod (navidrome + aonsoku)
Wants=network-online.target
After=network-online.target

[Pod]
PodName=music
# No PublishPort — exposure is via Newt tunnel + newt-net (container
# name resolution), not host port binding. See beszel-hub pattern.

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**`navidrome-data.volume`:**
```ini
# Named volume for navidrome application data (/data — DB, cache).
# The deluan/navidrome image runs as root (alpine-based), so no
# User=/Group= here — unlike letsencrypt.volume which sets them for the
# minimus traefik. See beszel-data.volume for the same root-image pattern.
[Volume]
```

**`navidrome.container.gotmpl`:**
```ini
[Unit]
Description=Navidrome music server
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=navidrome
Image=docker.io/deluan/navidrome:0.63.2@sha256:9012939114fbb1bb641b81cf96dec5ded15f0aafefe8d47a511d7cb919658e40

# Join newt-net so Newt (on bow via [Roles.tunneled]) reaches navidrome
# by container name "navidrome:4533" for the navidrome.<baseDomain> resource.
# Container name resolution only works on named networks, not the default
# bridge — same reason beszel-hub and newt itself use Network=newt-net.
# Standalone container (no pod) — aonsoku is a browser SPA that reaches
# navidrome by its public URL, not via a shared localhost namespace.
Network=newt-net

# Music library — read-only bind mount from bow's LVM data disk.
# /var/lib/materia-data is created by bare-metal.bu's lvm-data.service.
# :ro,z — read-only + SELinux shared relabel (matches old compose + restic).
Volume=/var/lib/materia-data/Music:/music:ro,z

# Navidrome persistent data (DB, cache) — named volume, root-owned image.
Volume=navidrome-data.volume:/data:z

# Explicit music folder path — the default --musicfolder=music resolves
# relative to the data dir, but we bind to /music, so set it explicitly.
Environment=ND_MUSICFOLDER=/music
Environment=ND_ENABLEINSIGHTSCOLLECTOR=false
Environment=ND_LOGLEVEL=info

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**`aonsoku.container.gotmpl`:**
```ini
[Unit]
Description=Aonsoku (Navidrome/Subsonic web client)
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=aonsoku
Image=ghcr.io/victoralvesf/aonsoku:latest@sha256:9bdfc8f1d7f462c7f4da90e70598696057ab765972f4b6a7f09f6f85ef1a2460

# Join newt-net — reachable by Newt as "aonsoku:8080" for the
# music.<baseDomain> resource. Standalone container (no pod).
Network=newt-net

# Aonsoku config per user spec:
# - HIDE_SERVER=true: hide the server URL field on login (server is fixed)
# - SERVER_URL: navidrome's PUBLIC URL (https://navidrome.<baseDomain>).
#   Aonsoku is a browser SPA — its JS runs in the user's browser, so it
#   must reach navidrome's public endpoint, not a container-internal
#   address. Composed from baseDomain (public URL, not a secret).
# - SERVER_TYPE=navidrome: navidrome-specific behavior
# APP_USER/APP_PASSWORD intentionally NOT set — .env.example warns the
# password is compromised on publicly-exposed instances; users log in
# via the form with their navidrome credentials.
Environment=HIDE_SERVER=true
Environment=SERVER_URL=https://navidrome.{{ .baseDomain }}
Environment=SERVER_TYPE=navidrome

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

### 2. `MANIFEST.toml` (root) — wire the component

```diff
 [Hosts.bow]
-Components = []
+Components = ["music"]
 Roles = ["base", "tunneled"]
```
`bow` already has `[Roles.tunneled]` (newt) and `[Roles.base]`
(restic-backup, beszel-agent) — adding `music` to `Components` directly
since it's host-specific (only bow has the music library), not a
role-wide assignment.

### 3. `AGENTS.md` — repo layout + component entry

Add `music/` to the repo layout tree and a one-line component
description, matching the beszel-hub/grimmory entries.

## Deployment steps (out of IaC scope, tracked in the issue)

1. `materia update` on `bow` installs the new component.
2. Populate `/var/lib/materia-data/Music` on `bow` with the music library.
3. Pangolin dashboard: create two local-site + resources:
   - `navidrome.<baseDomain>` → `navidrome:4533` (music server + Subsonic API)
   - `music.<baseDomain>` → `aonsoku:8080` (web client)
4. Disable Pangolin auth on both resources if navidrome's/aonsoku's own
   auth should handle login directly (same gotcha as beszel-agent #23 —
   Pangolin's default Platform SSO intercepts clients; navidrome has its
   own auth and aonsoku proxies it, so Pangolin's layer is redundant and
   should be disabled/public). Dashboard-only.

## Out of scope

- The old compose's `picard` container (MusicBrainz tagger) — not
  requested; the user's old compose had it but the new spec is navidrome
  + aonsoku only. Can be added later as a separate component or a third
  container in this pod.
- The old compose's `newt` service — replaced by the repo's managed
  `newt` component (`[Roles.tunneled]`), already on `bow`.
- Navidrome users/admin setup — first-run admin creation happens in the
  navidrome web UI at deploy time, not IaC.
