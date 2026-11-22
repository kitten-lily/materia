# Podman and Quadlet

Read this guide when writing units, health checks, environment values, mounts, or non-root containers.

- **On bow's podman (5.7.1), a string-form `HealthCmd` with an embedded
  quoted argument loses its closing quote, and the container never becomes
  healthy.** silentsuite (#192) shipped
  `HealthCmd=python -c "import http.client,…;sys.exit(…!=200)"`. Quadlet
  emitted `["CMD-SHELL","python -c \"import …!=200)"]`, with no closing `"`, so
  every probe printed `/bin/sh: syntax error: unterminated quoted string`.
  The identical quadlet was healthy under podman 6.1.4 on the workstation, so
  a local test can't catch this. With `Notify=healthy` the start job just
  waits: materia timed out on it and aborted bow's run (18/23 steps). Rule:
  any `HealthCmd` needing quotes or spaces inside an argument uses the
  JSON-array form. Best of all, use a mounted script with no quoting at all
  (`HealthCmd=["python","/healthcheck.py"]`, `silentsuite/healthcheck.py`).
  Check what podman stored with `podman inspect <ctr> -f '{{json
  .Config.Healthcheck.Test}}'`.
- **A start job stuck on `Notify=healthy` makes materia's restart of the
  fixed unit time out too.** After the healthcheck fix landed, materia
  installed the new quadlet but its restart queued behind the original start
  job, which waits up to `TimeoutStartSec` for a healthy signal that never
  comes. The run aborted again (`operation timeout`, 3/4 steps), and the
  container kept the old health test. Fix by hand: `systemctl restart
  <unit>` (recreates the container from the new quadlet), then re-run
  materia, which should say `Nothing to do`.

- **Podman healthcheck mechanics (issue #113).** Four things that are easy
  to get wrong: (1) **podman DOES inherit an image's `HEALTHCHECK`** — a
  container with no `HealthCmd=` still reports `healthy`/`unhealthy` if
  the image declares one (verified). Of the three apps this was assumed
  for, only jellyfin's image declares one; grimmory's and mediamanager's
  have none (`podman inspect` → `Config.Healthcheck` null, 2026-10-24), so
  podman never probes them. Restating `HealthCmd=` in the quadlet is needed
  for those, and elsewhere only to
  control `HealthInterval=`/`HealthRetries=`/`HealthStartPeriod=`, which
  otherwise take podman's defaults. (2) **`podman build` in the default
  OCI format silently DROPS `HEALTHCHECK`** (it is a Docker-schema field) —
  use `--format docker`, or any local test of healthcheck behaviour will
  wrongly conclude podman ignores image healthchecks. (3) A plain-string
  `HealthCmd=` is wrapped in `/bin/sh -c`, which **does not exist** in
  scratch/distroless images (`beszel-hub`,
  `beszel-agent`, both buildbarn images — confirmed by `podman exec … /bin/sh`
  failing with `crun: executable file /bin/sh not found`). Use the
  JSON-array form for those, which execs directly:
  `HealthCmd=["/beszel","health","--url","http://localhost:8090"]`. (4) A
  probe referencing an env var must escape it as `$$VAR` — quadlet emits
  the command into `ExecStart=`, where systemd would expand `$VAR` (unset
  in the unit environment) to empty before podman ever sees it.
  `HealthOnFailure=` defaults to `none` (report only); `kill` + the usual
  `Restart=always` is what makes an unhealthy-but-alive container
  self-heal — never set it on `newt`, whose probe tracks the upstream
  tunnel, or an edge outage becomes a restart loop.

- **SELinux relabels.** Volumes need `:z` (shared, lowercase) for dirs mounted
  into multiple containers, `:Z` for single-container dirs. Missing = "container
  starts but can't read volume" on enforcing SELinux. Harmless on permissive but
  keep for portability.

- **Systemd unit inline comments are literal values.**
  `PublishPort=443:443/udp  # HTTP/3` passes the full string including comment
  to Podman. The `/3` in `HTTP/3` triggered "protocol can only be specified
  once". Rule: quadlet file comments must be on their own lines, never inline
  after a value.
- **`Environment=` values containing a space MUST be quoted, or systemd
  silently truncates/splits them.** Quadlet's `Environment=` follows
  systemd's `Environment=` parsing rules (confirmed:
  `podman-systemd.unit(5)`, "uses the same format as services in
  systemd"), which split unquoted values on whitespace. Two real bugs
  found this way: (1) `beszel-agent.container.gotmpl`'s
  `Environment=KEY={{ .beszelKey }}` — an ed25519 public key
  (`ssh-ed25519 AAAA...`) contains a space, so the agent only ever
  received `KEY=ssh-ed25519` (no key data), failing with `ssh: no key
  found` at every startup. (2) `restic-backup.container.gotmpl`'s
  `Environment=BACKUP_PATHS=/var/lib/materia/components
  /var/lib/containers/storage/volumes` — confirmed via `systemctl cat` +
  `podman inspect` on flutterina that the container only ever received
  `--env BACKUP_PATHS=/var/lib/materia/components`; the podman volumes
  path was silently dropped since the component shipped, meaning
  pangolin-config/letsencrypt/beszel-data etc. were never backed up.
  Fix: quote the whole assignment —
  `Environment="KEY={{ .beszelKey }}"` /
  `Environment="BACKUP_PATHS=path1 path2"`. Audit any new
  `Environment=` line whose templated value might contain a space
  (public keys, multi-path lists, anything with a comment/description)
  before assuming it "just works" — there is no local materia template
  renderer to catch this; it only surfaces as a runtime failure on the
  actual host.

- **Non-root images (UID 1000) need three changes, not just a new
  `Image=`.** This was learned with minimus before the
  [registry exit](media-apps.md) and applies to other non-root images such
  as Docker Hardened Images (#174). Three things break when switching from
  an upstream image to a non-root one: (1) **privileged port binding** — UID 1000 can't bind
  to ports < 1024 without `CAP_NET_BIND_SERVICE`; add
  `AddCapability=NET_BIND_SERVICE` to the `.container.gotmpl`. (2) **named
  volume write permissions** — podman named volumes are root-owned by
  default; add `User=1000`/`Group=1000` to the `.volume` quadlet file so the
  volume is created with the right ownership (confirmed: quadlet `.volume`
  files support `User=`/`Group=` directly, per podman-volume.unit.5). For
  existing volumes with root-owned content, chown on the host before
  restarting: `sudo podman unshare chown -R 1000:1000 <volume-path>`. (3)
  **plugin/download directories** — directories the upstream image created
  as root (e.g. traefik's `/plugins-storage`) don't exist or aren't writable
  by UID 1000; use `Tmpfs=/plugins-storage` for ephemeral writable dirs (the
  badger plugin re-downloads on each boot, ~1s). Confirmed by local smoke
  test during issue #8's traefik minimus migration.
- **Switching an ALREADY-DEPLOYED component to non-root takes a host-side
  chown — the `.volume` quadlet's `User=`/`Group=` alone silently does
  nothing, and the app dies at runtime.** `User=`/`Group=` in a `.volume`
  file are *creation-time* arguments; podman also auto-chowns a named
  volume to the container's user only when that volume is **empty** at
  first use. A volume that already holds data from a previous root-run
  keeps its root ownership forever, so adding `User=1000` to the
  `.container` turns a working service into a crash loop on the next
  `materia-update` — on a fresh host the identical commit works fine,
  which is why local/greenfield testing never catches it. Caught
  2026-09-21: commit `7a33daa` (#26) added `User=1000`/`Group=1000` to
  `beszel-hub` + `beszel-data.volume`; flutterina's
  `systemd-beszel-data` volume had existed root-owned since #20, so the
  hub exited immediately on every start with PocketBase's
  `attempt to write a readonly database (1544)`, `Restart=always`
  crash-looped it, and `https://beszel.<baseDomain>` served Traefik's
  `503 no available server` for ~4 days while the rest of the edge
  (pangolin + every bow-tunneled resource) stayed green — beszel is the
  alerting system, so nothing else reported it. Reproduced exactly with
  local rootless podman (populate a volume root-run, then rerun
  `--user 1000:1000` → same error; `podman unshare chown -R 1000:1000
  <mountpoint>` → healthy `/api/health` 200), and the error is
  version-independent (0.19.0 and 0.20.0 behave identically — the
  same-day Renovate bump to 0.20.0 was a red herring). Either do the
  chown on every already-provisioned host **before** the commit lands,
  or don't make the change. Reverted here (commit reverts #26's
  `User=`/`Group=` on hub, volume, and agent) since the fleet is
  GitOps-pull and a repo revert is the only fix that needs no shell.
- **Non-root containers can't read the rootful podman socket.**
  `podman.socket` ships `SocketMode=0660` with no `SocketUser=`/
  `SocketGroup=`, so `/run/podman/podman.sock` is `root:root 0660` and a
  `User=1000` container mounting it gets EACCES. `beszel-agent` fails
  *soft* here — it keeps running and reporting host metrics, just with
  zero container stats, i.e. it silently undoes #32 with no failed unit
  and no obvious symptom. Any component that needs the podman socket
  must run as root until the socket is given a shared group.
