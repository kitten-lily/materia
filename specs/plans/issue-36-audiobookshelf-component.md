# Implementation Plan — Issue #36: Add audiobookshelf component (audiobooks + podcasts) on bow

**issue:** https://github.com/kitten-lily/materia/issues/36
**risk:** P2 (adds a new self-contained component on `bow`; no changes to
existing services; exposed via the established Newt tunnel + `newt-net`
pattern, same as `music`/`grimmory`)
**epic:** standalone

## Summary

Add an `audiobookshelf` component running
[Audiobookshelf](https://audiobookshelf.org) — a self-hosted media server
for audiobooks and podcasts — on `bow`, exposed at
`audiobookshelf.<baseDomain>` via the existing Newt tunnel. Only the
audiobook and podcast libraries are wired; the `/books` (ebook/comic)
volume from upstream's quadlet example is intentionally omitted since
that's `grimmory`'s job on this host.

## Architecture decisions

### Standalone container on `newt-net`, no pod

Same pattern as `music`/`grimmory`: audiobookshelf has no
shared-network-namespace requirement (it's a single container, no
sidecar), so it joins `newt-net` directly rather than getting its own
pod. Newt (already on `bow` via `[Roles.tunneled]`) reaches it by
container name `audiobookshelf:80` for the `audiobookshelf.<baseDomain>`
resource. No `PublishPort` — exposure is via the tunnel, not a host
port bind (avoids the `0.0.0.0` bind exposure window beszel-hub's
`PublishPort=8090` carries).

### Only audiobooks + podcasts — no `/books` volume

Upstream's [podman quadlet example](https://audiobookshelf.org/docs/documentation/install/podman)
mounts four content volumes: `/audiobooks`, `/books`, `/podcasts`,
plus `/config` and `/metadata`. Per the user's request, only
`/audiobooks` and `/podcasts` are wired — `/books` is deliberately
omitted (not just left empty) so no ebook library ever gets scanned by
this component; `grimmory` already owns ebook/comic hosting on `bow`.

### Library paths: `/var/lib/materia-data/AudioBooks` + `/var/lib/materia-data/Podcasts`

Same LVM-data-disk pattern as `music`'s `/var/lib/materia-data/Music`
and `grimmory`'s `/var/lib/materia-data/Books` (created by
`bare-metal.bu`'s `lvm-data.service`). `AudioBooks` is mounted
**read-only** (`:ro,z`) — same reasoning as navidrome's read-only music
library: audiobookshelf shouldn't be able to modify the source audiobook
files. `Podcasts` is mounted **read-write** (`:z`) since audiobookshelf
downloads new episodes directly into that library. Populating these
directories with existing audiobook/podcast content is a deploy-time
step, same as the other library components.

### Config + metadata: named volumes, not host bind mounts

Upstream's `/config` and `/metadata` are audiobookshelf's own
app-managed state (user DB, sessions, cached covers, podcast download
staging) — not user-supplied media. Per the data-dir-drift gotcha
(materia treats everything under
`/var/lib/materia/components/<name>/` as its own and schedules
undeclared files for removal), these go in named volumes
(`audiobookshelf-config.volume`, `audiobookshelf-metadata.volume`),
matching how `navidrome-data.volume`/`beszel-data.volume` hold runtime
app state while media content lives on the bind-mounted LVM disk.

### Image: pinned by digest (multi-arch index), Renovate-tracked

`ghcr.io/advplyr/audiobookshelf:2.35.1@sha256:1eef6716183c52abafe5405e7d6be8390248ecd59c7488c44af871757ac8fc4d`
— latest stable release at plan time, digest resolved against the GHCR
registry API (both the `2.35.1` and `latest` tags currently resolve to
this same multi-arch index digest). Renovate's existing `quadlet`
manager (already matching `*.container.gotmpl`) tracks digest bumps.

### Root-owned image — no `User=`/`Group=` on volumes

The upstream image runs as root (no documented non-root `USER`,
confirmed by the official quadlet/compose examples using bare
`/config`/`/metadata` mounts with no UID/GID env vars, unlike the
minimus images in this repo). Named volumes get no `User=`/`Group=`
override — same reasoning as `navidrome-data.volume`/`beszel-data.volume`.

### `TZ` env, no auth-related env

Only `Environment=TZ=Etc/UTC` is set (matches the repo's existing
`Etc/UTC` convention on `restic-backup`/`beszel-agent`, rather than
upstream's example `America/Toronto`). Audiobookshelf's admin
account/auth is configured via its own first-run web UI setup, not
environment variables or a materia secret — there's no
`APP_USER`/`APP_PASSWORD`-style env to wire (unlike aonsoku, which
explicitly omits those for the same "don't bake credentials into a
public env var" reason).

### Pangolin exposure: SSO kept ON (human-facing UI)

Same decision as `grimmory` (not `beszel-agent`): audiobookshelf is a
browser-driven web UI with its own login form, so Pangolin's default
Platform SSO layered in front doesn't break anything — the user just
authenticates twice (Pangolin, then audiobookshelf). Do **not** disable
Pangolin auth on the `audiobookshelf.<baseDomain>` resource at deploy
time.

## Files to create / modify

### 1. `components/audiobookshelf/` (new)

**`MANIFEST.toml`:**
```toml
[Defaults]

[[Services]]
Service = "audiobookshelf.service"
RestartedBy = ["audiobookshelf.container"]
```
No `Secrets` — nothing templated needs a podman secret. Long-running
`Restart=always` service, no `Oneshot`/`Stopped`/`Static`.

**`audiobookshelf-config.volume`:**
```ini
# Named volume for audiobookshelf app config (users, sessions, settings).
# Image runs as root — no User=/Group= (see beszel-data.volume/
# navidrome-data.volume for the same root-image pattern).
[Volume]
```

**`audiobookshelf-metadata.volume`:**
```ini
# Named volume for audiobookshelf metadata cache (covers, downloaded
# podcast episode staging). Root-owned, same as audiobookshelf-config.volume.
[Volume]
```

**`audiobookshelf.container.gotmpl`:**
```ini
[Unit]
Description=Audiobookshelf (audiobooks + podcasts)
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=audiobookshelf
Image=ghcr.io/advplyr/audiobookshelf:2.35.1@sha256:1eef6716183c52abafe5405e7d6be8390248ecd59c7488c44af871757ac8fc4d

# Join newt-net so Newt (on bow via [Roles.tunneled]) reaches
# audiobookshelf by container name "audiobookshelf:80" for the
# audiobookshelf.<baseDomain> resource. Container name resolution only
# works on named networks, not the default bridge — same reason
# music/grimmory/newt itself use Network=newt-net.
Network=newt-net

# Audiobook + podcast libraries — bind mounts from bow's LVM data disk
# (/var/lib/materia-data, created by bare-metal.bu's lvm-data.service).
# AudioBooks is read-only (:ro,z) — same reasoning as navidrome's
# read-only music mount, audiobookshelf shouldn't modify source files.
# Podcasts is read-write (:z) — audiobookshelf downloads new episodes
# directly into that library.
# No /books volume: ebook/comic hosting is grimmory's job on this host.
Volume=/var/lib/materia-data/AudioBooks:/audiobooks:ro,z
Volume=/var/lib/materia-data/Podcasts:/podcasts:z

# App config (users, sessions, settings) and metadata cache (covers,
# podcast download staging) — named volumes, not bind mounts. Materia
# treats the data dir as fully managed; app-writable runtime state
# needs a named volume so it isn't scheduled for removal as drift.
Volume=audiobookshelf-config.volume:/config:z
Volume=audiobookshelf-metadata.volume:/metadata:z

Environment=TZ=Etc/UTC

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

### 2. `MANIFEST.toml` (root) — wire the component

```diff
 [Hosts.bow]
-Components = ["music", "grimmory"]
+Components = ["music", "grimmory", "audiobookshelf"]
 Roles = ["base", "tunneled"]
```
Host-specific (only `bow` has the library disks), not role-wide.

### 3. `AGENTS.md` — repo layout + component entry

Add `audiobookshelf/` to the repo layout tree and a one-line component
description, matching the `music`/`grimmory` entries.

## Deployment steps (out of IaC scope, tracked in the issue)

1. Pre-create and chown the library directories on `bow` before the
   first `materia update` (same as grimmory's `/Books` prerequisite):
   ```
   sudo mkdir -p /var/lib/materia-data/AudioBooks /var/lib/materia-data/Podcasts
   ```
   (root-owned is fine — the container itself runs as root.)
2. `materia update` on `bow` installs the new component.
3. Populate `/var/lib/materia-data/AudioBooks` /
   `/var/lib/materia-data/Podcasts` with existing library content, if any.
   `AudioBooks` content must exist before this step since the mount is
   read-only — audiobookshelf can't create the directory structure itself.
4. Complete audiobookshelf's first-run setup (create admin account) via
   its web UI at `https://audiobookshelf.<baseDomain>`.
5. In the audiobookshelf web UI, add two libraries pointing at
   `/audiobooks` (media type: Audiobooks) and `/podcasts` (media type:
   Podcasts).
6. Pangolin dashboard: create a local-site + resource,
   `audiobookshelf.<baseDomain>` → `audiobookshelf:80`. Leave Pangolin
   auth **enabled** (see architecture decision above).

## Out of scope

- Ebook/comic library (`/books` upstream volume) — deliberately
  excluded; `grimmory` already covers that content type on `bow`.
- Audiobookshelf's own auth/user setup — first-run admin creation
  happens in its web UI at deploy time, not IaC.
- `AutoUpdate=registry`/`NoNewPrivileges=true` from upstream's example —
  this repo's convention is git-pinned digests (no `AutoUpdate`,
  Renovate bumps digests via PRs instead); `NoNewPrivileges` isn't used
  elsewhere in this repo's `.container.gotmpl` files, so it's omitted
  for consistency rather than cherry-picked onto one component.
