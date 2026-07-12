# Implementation Plan — Issue #8: Replace traefik with minimus image

**issue:** https://github.com/kitten-lily/materia/issues/8
**risk:** P1 (touches the production edge node's reverse proxy — a failure
takes down all public ingress)
**epic:** standalone (not part of e01)

## Summary

Switch `components/pangolin/traefik.container.gotmpl` from the upstream
Docker Hub traefik image to the [minimus traefik image](https://images.minimus.io/gallery/images/traefik)
(`reg.mini.dev/traefik`). The minimus image is a hardened, reduced-CVE
rebuild of the same traefik binary — 0 known CVEs at 3.7.7 vs. the upstream
image, ~53 MB smaller compressed. No auth needed (standard gallery images
are public). Plugin support (badger) is present. Entry point is the same
(`/usr/bin/traefik`), so `Exec=--configFile=...` works unchanged.

## Investigation findings

### What works without changes

- **Registry auth:** standard minimus images pull without authentication
  — verified by pulling `reg.mini.dev/traefik:3.7.7` with no credentials.
  No `registries.conf` or pull-secret wiring needed on flutterina.
- **Entrypoint compatibility:** minimus image entrypoint is
  `/usr/bin/traefik` (same as upstream). `Exec=--configFile=/etc/traefik/traefik_config.yml`
  appends args to the entrypoint — works unchanged.
- **Plugin support:** `--experimental.abortonpluginfailure` and plugin
  config flags are present in the minimus image. The badger plugin
  (`experimental.plugins.badger` in `traefik_config.yml.gotmpl`) should
  work — traefik downloads plugins at startup to a writable plugin dir.
- **Config mount:** the read-only `Volume=...traefik:/etc/traefik:ro,z`
  mount works the same way (minimus image reads config files the same as
  upstream).

### What needs changes

#### CRITICAL: the minimus image runs as UID 1000 (non-root)

The upstream `docker.io/traefik` image runs as **root** (UID 0). The
minimus image runs as **UID 1000**. This breaks two things:

1. **Port binding.** Traefik binds to `:80` and `:443` inside the pod's
   shared network namespace. Ports < 1024 require `CAP_NET_BIND_SERVICE`
   or root. UID 1000 without that capability gets `bind: permission
   denied` — **confirmed by local smoke test** (the minimus image failed
   to start with exactly this error when given the current config).

   **Fix:** add `AddCapability=NET_BIND_SERVICE` to
   `traefik.container.gotmpl`. This grants the non-root process the
   single capability it needs to bind privileged ports — more secure than
   running as root, which is the whole point of the minimus image.

2. **`letsencrypt` volume write permissions.** Traefik writes
   `acme.json` to `/letsencrypt` (the `letsencrypt.volume` named volume).
   The volume is currently created without a UID specification — podman
   assigns it root ownership by default. UID 1000 can't write to a
   root-owned directory.

   **Fix:** the `letsencrypt.volume` quadlet file needs `User=1000` (or
   `User=traefik` if the image has a named user) so the named volume is
   owned by the same UID the container runs as. Alternatively, a
   `Volume=` mount option or an init step could chown the volume — but
   the cleanest approach is the volume's `User=` field if quadlet
   supports it, or a `PodmanArgs=--userns=keep-id` or similar. **This
   needs verification** — quadlet `.volume` files may not support `User=`
   directly; check the podman-systemd.unit docs.

   **Migration concern:** the existing `letsencrypt` volume on flutterina
   already has `acme.json` with valid Let's Encrypt certificates, owned
   by root. Changing the container to UID 1000 means either (a) chowning
   the existing volume contents on the host before the first run with the
   new image, or (b) traefik can't read the existing cert and has to
   re-issue via DNS challenge (a few minutes of downtime + rate-limit
   risk). **Plan: chown the volume on the host during the deploy.**

#### Renovate: tag format and versioning

The minimus tags drop the `v` prefix: `3.7.7` vs upstream's `v3.7`.
Renovate's docker datasource with default `semver` versioning should
handle both (it strips `v` prefixes for comparison). But the existing
`renovate.json5` has no special rule for `docker.io/traefik` — the
quadlet manager will pick up `reg.mini.dev/traefik` automatically (same
`managerFilePatterns` regex matches all `.container.gotmpl` files).

**One thing to verify:** the `digest` automerge rule
(`matchUpdateTypes: ["digest"]`) applies repo-wide, so minimus traefik
digest bumps will automerge — same as all other images. No config change
needed, but worth watching the first Renovate run to confirm it resolves
`reg.mini.dev/traefik` tags correctly.

No `versioning` rule needed for traefik (unlike pangolin's `ee-` prefix)
— `3.7.7` is standard semver.

#### AGENTS.md

The repo layout and gotchas don't need changes for this — the traefik
container file is already documented. But a new gotcha should be added
about the UID 1000 / `NET_BIND_SERVICE` / volume-ownership pattern for
minimus images, since future minimus migrations (e.g. if we switch other
images) will hit the same issues.

## Implementation steps

### Step 1: Update `traefik.container.gotmpl`

- Change `Image=docker.io/traefik:v3.7@sha256:1cb3845...` to
  `Image=reg.mini.dev/traefik:3.7.7@sha256:941454652ae4b0a98088987dfb5100b50cf14bed043e257f71524b36bded664d`
- Add `AddCapability=NET_BIND_SERVICE` (ports 80/443 binding as UID 1000)
- → verify: `grep -q 'reg.mini.dev/traefik' traefik.container.gotmpl && grep -q 'NET_BIND_SERVICE' traefik.container.gotmpl`

### Step 2: Fix `letsencrypt.volume` ownership for UID 1000

- Investigate whether quadlet `.volume` files support a `User=` field
  (check podman-systemd.unit docs). If yes, add `User=1000`.
- If not, add a comment documenting that the volume must be chowned to
  UID 1000 on first deploy, and handle it in the deploy step.
- → verify: `grep -q '1000' letsencrypt.volume` or documented chown step

### Step 3: Local smoke test

- Pull the minimus image, run it with `AddCapability=NET_BIND_SERVICE`
  and the current traefik config, confirm it starts and binds ports
  without errors.
- Test the badger plugin download (may need network access to GitHub).
- → verify: `podman run --cap-add NET_BIND_SERVICE ... reg.mini.dev/traefik:3.7.7 --configFile=...` starts without "permission denied"

### Step 4: Deploy to flutterina

This is the risky step — the traefik container is the public ingress.

1. `materia update` on flutterina (picks up the new image + capability).
2. **Before restarting traefik**, chown the letsencrypt volume to UID 1000:
   `sudo podman unshare chown -R 1000:1000 /var/lib/containers/storage/volumes/systemd-letsencrypt/_data`
   (or the equivalent path — verify with `podman volume inspect letsencrypt`).
3. `sudo systemctl restart traefik.service`
4. Watch `journalctl -u traefik.service -f` — confirm it starts, binds
   ports, loads the badger plugin, and can read the existing `acme.json`.
5. Smoke test: `curl -sI https://pangolin.<domain>/` — confirm 200/302.
- → verify: `systemctl is-active traefik.service` + `curl` returns expected status

### Step 5: Update Renovate (if needed)

- After the first Renovate run, check the Dependency Dashboard issue (#6)
  to confirm `reg.mini.dev/traefik` was detected and version/digest
  updates are flowing.
- If Renovate can't resolve `reg.mini.dev` tags, add a `custom.regex`
  manager or a `hostRules` entry for `reg.mini.dev`.
- → verify: `gh issue view 6` shows traefik in the dashboard

### Step 6: Document the minimus migration pattern in AGENTS.md

- Add a gotcha about minimus images running as non-root (UID 1000) and
  the three things that break: port binding (`AddCapability=NET_BIND_SERVICE`),
  volume write permissions (`User=` in `.volume` or chown on deploy), and
  the migration concern for existing volumes with root-owned content.
- → verify: `grep -q 'minimus' AGENTS.md`

## Risks

- **Public ingress downtime.** If traefik fails to start with the new
  image, all public traffic to pangolin stops. Mitigation: test locally
  first, chown the volume before restarting, have a rollback plan
  (`git revert` + `materia update` to restore the upstream image).
- **Let's Encrypt rate limiting.** If the volume chown fails and traefik
  can't read `acme.json`, it will try to re-issue certificates. Let's
  Encrypt has rate limits (50 per registered domain per week). A single
  re-issue is fine, but repeated failures could hit the limit.
  Mitigation: verify the chown worked before restarting traefik.
- **Badger plugin download failure.** The minimus image may have a
  different plugin download path or lack write access to the default
  plugin directory. If the plugin can't be downloaded, traefik won't
  start (with `abortonpluginfailure` off, it would start but the badger
  middleware would 500 every request). Mitigation: test locally first,
  check traefik logs for plugin download errors.
- **Renovate coverage gap.** If Renovate can't resolve `reg.mini.dev`
  tags, the image won't get update PRs — it'll be frozen at the pinned
  digest until manually bumped. Not a P0, but defeats the GitOps auto-
  update convention. Mitigation: check the dashboard after the first run.
