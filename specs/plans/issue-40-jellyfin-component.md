# Implementation Plan — Issue #40: Add jellyfin component (movies + TV) on bow

**issue:** https://github.com/kitten-lily/materia/issues/40
**risk:** P2 (adds a new self-contained component on `bow`; no changes to
existing services; exposed via the established Newt tunnel + `newt-net`
pattern, same as `music`/`grimmory`/`audiobookshelf`)
**epic:** standalone

## Summary

Add a `jellyfin` component running [Jellyfin](https://jellyfin.org) — a
self-hosted media server — on `bow`, exposed at `jellyfin.<baseDomain>` via
the existing Newt tunnel. Movies and TV Shows libraries only (no music —
`music` already owns that content type on this host via navidrome).
Hardware-accelerated transcoding is enabled via `/dev/dri` passthrough.

## Architecture decisions

### Standalone container on `newt-net`, no pod

Same pattern as `music`/`grimmory`/`audiobookshelf`: Jellyfin has no
shared-network-namespace requirement (single container, no sidecar), so it
joins `newt-net` directly rather than getting its own pod. Newt (already on
`bow` via `[Roles.tunneled]`) reaches it by container name `jellyfin:8096`
for the `jellyfin.<baseDomain>` resource. No `PublishPort=8096:8096` —
exposure is via the tunnel only, avoiding the host-port-bind exposure
window `beszel-hub`'s `PublishPort=8090` carries. `7359/udp` (Jellyfin's
LAN auto-discovery beacon) is **not** published either — auto-discovery is
irrelevant behind a Newt tunnel (clients connect via
`jellyfin.<baseDomain>`, not LAN broadcast), and it's a UDP broadcast
listener with no auth, so there's no reason to expose it even on
`newt-net`.

### Movies + TV Shows only — no music library

Per the user's decision: two read-only bind mounts,
`/var/lib/materia-data/Movies` → `/media/Movies` and
`/var/lib/materia-data/TVShows` → `/media/TVShows`, mirroring the
per-content-type library pattern already used by `audiobookshelf`
(`/AudioBooks`, `/Podcasts`) and `grimmory` (`/Books`). No music library —
`music`'s navidrome already owns that content type on `bow`; wiring a
second music-scanning path here would duplicate it, same reasoning
`audiobookshelf` used to exclude `/books` (owned by `grimmory`).

Both mounts are **read-only** (`:ro,z`) — Jellyfin only needs to read
media files and write its own metadata/artwork into `/config`, not modify
source files. Same reasoning as navidrome's read-only `/Music` mount and
audiobookshelf's read-only `/AudioBooks` mount.

### Config + cache: named volumes, not host bind mounts

Upstream's `/config` (library DB, user accounts, metadata/artwork cache,
transcoding logs) and `/cache` (transcoding scratch space, thumbnail
cache) are Jellyfin's own app-managed state, not user-supplied media. Per
the data-dir-drift gotcha (materia treats everything under
`/var/lib/materia/components/<name>/` as its own and schedules undeclared
files for removal), these go in named volumes (`jellyfin-config.volume`,
`jellyfin-cache.volume`), matching `audiobookshelf-config.volume`/
`audiobookshelf-metadata.volume`.

### Hardware-accelerated transcoding: `/dev/dri` passthrough

Per the user's decision, bow has a GPU/iGPU Jellyfin should use. The
`.container.gotmpl` adds `AddDevice=/dev/dri:/dev/dri` (quadlet's
device-passthrough directive — equivalent to `podman run --device
/dev/dri:/dev/dri`). **Needs on-host verification before/at deploy time**,
not assumed from this plan alone:

- Confirm `/dev/dri` actually exists on bow (`ls /dev/dri` over SSH) —
  if bow's iGPU isn't exposed to the Flatcar host kernel, this directive
  is a no-op and the container will just fail to find the device (not a
  hard failure — Jellyfin falls back to CPU transcoding silently, but
  hardware accel won't be active).
- SELinux: per Jellyfin's docs, container-selinux ≥2.226 needs
  `container_use_dri_devices` set via `setsebool -P
  container_use_dri_devices 1` on the host, or the container can't
  actually use the device even though the mount succeeds. This repo's
  `bare-metal.bu` template doesn't currently document bow's SELinux
  enforcing mode — check `getenforce` on bow before assuming this
  boolean is needed (if permissive/disabled, it's a no-op like the
  existing SELinux `:z`/`:Z` relabel gotchas already documented for
  permissive hosts). If enforcing and the boolean is needed, that's a
  one-time hand-run `setsebool` on bow, not something Ignition/materia
  manages (out of this component's IaC scope, same category as the
  Pangolin-dashboard-only steps below).
- No `User=`/`Group=` set on the container (matches audiobookshelf/
  navidrome's root-image pattern) — rendering the render group's GID
  irrelevant here; if a future non-root Jellyfin base image is adopted,
  the container's user would need to be a member of the host's `render`
  group GID, which isn't the case with the current official (root)
  image.

### `TZ` env, `JELLYFIN_PublishedServerUrl` for correct external links

`Environment=TZ=Etc/UTC` (matches the repo's existing convention on
`restic-backup`/`beszel-agent`/`audiobookshelf`). Also set
`Environment=JELLYFIN_PublishedServerUrl=https://jellyfin.<baseDomain>` —
upstream's compose example calls this "optional, for autodiscovery", but
it's also what Jellyfin uses to generate correct external links (e.g. in
cast/sync notifications) when accessed through a reverse proxy at a
different address than the container's internal one; every other
tunnel-exposed component in this repo (`grimmory`, `audiobookshelf`)
already resolves its own public domain via `{{ .baseDomain }}`, so this is
consistent rather than a new pattern.

### Image: pinned by digest, Renovate-tracked

`docker.io/jellyfin/jellyfin:10.11.0@sha256:59417f441213e236a9f907d4e71a13472042409d85f9e9310dbdd87ee33d7bd4`
— latest stable minor release at plan time (multi-arch index digest,
resolved against the Docker Hub registry API). Renovate's existing
`quadlet` manager (already matching `*.container.gotmpl`) tracks digest
bumps automatically, same as every other pinned image in this repo.

### Pangolin exposure: SSO kept ON (human-facing UI)

Same decision as `grimmory`/`audiobookshelf` (not `beszel-agent`):
Jellyfin is a browser-driven web UI with its own login, so Pangolin's
default Platform SSO layered in front doesn't break anything — the user
authenticates twice (Pangolin, then Jellyfin). Do **not** disable Pangolin
auth on the `jellyfin.<baseDomain>` resource at deploy time.

## Files to create / modify

### 1. `components/jellyfin/` (new)

**`MANIFEST.toml`:**
```toml
[Defaults]

[[Services]]
Service = "jellyfin.service"
RestartedBy = ["jellyfin.container"]
```
No `Secrets` — nothing templated needs a podman secret (Jellyfin's admin
account is set up via its own first-run web UI, same as audiobookshelf).
Long-running `Restart=always` service, no `Oneshot`/`Stopped`/`Static`.

**`jellyfin-config.volume`:**
```ini
# Named volume for jellyfin app config (library DB, user accounts,
# metadata/artwork cache, transcoding logs). Image runs as root — no
# User=/Group= (see audiobookshelf-config.volume/navidrome-data.volume
# for the same root-image pattern).
[Volume]
```

**`jellyfin-cache.volume`:**
```ini
# Named volume for jellyfin transcoding scratch space + thumbnail cache.
# Root-owned, same as jellyfin-config.volume.
[Volume]
```

**`jellyfin.container.gotmpl`:**
```ini
[Unit]
Description=Jellyfin (movies + TV)
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=jellyfin
Image=docker.io/jellyfin/jellyfin:10.11.0@sha256:59417f441213e236a9f907d4e71a13472042409d85f9e9310dbdd87ee33d7bd4

# Join newt-net so Newt (on bow via [Roles.tunneled]) reaches jellyfin
# by container name "jellyfin:8096" for the jellyfin.<baseDomain>
# resource. Container name resolution only works on named networks, not
# the default bridge — same reason music/grimmory/audiobookshelf/newt
# itself use Network=newt-net. No PublishPort — exposure is via the
# tunnel only. 7359/udp (LAN auto-discovery) is deliberately not
# published either: irrelevant behind a tunnel, unauthenticated
# broadcast listener.
Network=newt-net

# Hardware-accelerated transcoding — passes bow's iGPU render device
# into the container. Verify /dev/dri exists on bow and (if SELinux is
# enforcing) that container_use_dri_devices is set before relying on
# this — see plan notes.
AddDevice=/dev/dri:/dev/dri

# Movies + TV libraries — read-only bind mounts from bow's LVM data disk
# (/var/lib/materia-data, created by bare-metal.bu's lvm-data.service).
# Read-only: same reasoning as navidrome's/audiobookshelf's read-only
# media mounts — jellyfin shouldn't modify source media files.
# No music library: music's navidrome already owns that content type on
# this host.
Volume=/var/lib/materia-data/Movies:/media/Movies:ro,z
Volume=/var/lib/materia-data/TVShows:/media/TVShows:ro,z

# App config (library DB, users, metadata/artwork cache) and transcoding
# cache — named volumes, not bind mounts. Materia treats the data dir as
# fully managed; app-writable runtime state needs a named volume so it
# isn't scheduled for removal as drift.
Volume=jellyfin-config.volume:/config:z
Volume=jellyfin-cache.volume:/cache:z

Environment=TZ=Etc/UTC
Environment=JELLYFIN_PublishedServerUrl=https://jellyfin.{{ .baseDomain }}

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

### 2. `MANIFEST.toml` (root) — wire the component

```diff
 [Hosts.bow]
-Components = ["music", "grimmory", "audiobookshelf"]
+Components = ["music", "grimmory", "audiobookshelf", "jellyfin"]
 Roles = ["base", "tunneled"]
```
Host-specific (only `bow` has the library disks + GPU), not role-wide.

### 3. `AGENTS.md` — repo layout + component entry

Add `jellyfin/` to the repo layout tree and a one-line component
description, matching the `music`/`grimmory`/`audiobookshelf` entries.
Add a Gotchas bullet documenting the `/dev/dri` + SELinux
`container_use_dri_devices` on-host verification requirement (so it isn't
silently forgotten the way `beszel-agent`'s Pangolin-auth requirement
almost was).

## Deployment steps (out of IaC scope, tracked in the issue)

1. On `bow`, confirm the GPU render device is exposed to the host kernel
   and check SELinux mode:
   ```
   ls /dev/dri
   getenforce
   ```
   If enforcing and `container-selinux` ≥2.226:
   ```
   sudo setsebool -P container_use_dri_devices 1
   ```
2. Pre-create the library directories on `bow` before the first `materia
   update` (same as grimmory's `/Books` prerequisite):
   ```
   sudo mkdir -p /var/lib/materia-data/Movies /var/lib/materia-data/TVShows
   ```
3. `materia update` on `bow` installs the new component.
4. Populate `/var/lib/materia-data/Movies` /
   `/var/lib/materia-data/TVShows` with existing content, if any. Both
   mounts are read-only, so directory structure/content must exist before
   this step — Jellyfin can't create it.
5. Complete Jellyfin's first-run setup wizard (create admin account, add
   the two libraries pointing at `/media/Movies` [Movies] and
   `/media/TVShows` [Shows]) via `https://jellyfin.<baseDomain>`.
6. In Jellyfin's admin dashboard (Playback settings), enable hardware
   acceleration (VAAPI, pointing at `/dev/dri/renderD128` or similar) if
   step 1 confirmed the device is present.
7. Pangolin dashboard: create a local-site + resource,
   `jellyfin.<baseDomain>` → `jellyfin:8096`. Leave Pangolin auth
   **enabled** (see architecture decision above).

## Out of scope

- Music library — `music`'s navidrome already covers that content type
  on `bow`.
- Subtitle burn-in custom fonts (`/usr/local/share/fonts/custom` mount
  from upstream's example) — not requested; can be added later as an
  additive `Volume=` line if needed.
- `JELLYFIN_FFmpeg__probesize`/other tuning env vars — defaults are
  fine at this scope; revisit only if a real performance issue surfaces.
- `AutoUpdate=registry` from upstream's rootless example — this repo's
  convention is git-pinned digests (no `AutoUpdate`), consistent with
  every other component.
