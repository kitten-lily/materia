# Materia Podman Orchestration

> **Process rules** (Always Green, Discovered Defects, Conventional Commits,
> Agent Workflow Mandate) live in `CONVENTIONS.md` — read it before any git
> operation.

Context brief: repo structure, materia concepts, conventions, gotchas.

## Goal

Manage Podman-hosted services via [Materia](https://primamateria.systems/) — a
GitOps tool that templates resources, installs quadlets/configs, manages podman
secrets, and restarts services. No hand-rolled reconciler, no webhook, no
seed-secrets service. Materia is the single source of truth enforcement.

## Where this sits in the larger stack

- **Edge node (this repo):** Pangolin (app + Gerbil + Traefik) runs on
  `flutterina`, a public Hetzner Cloud VPS — the single public entry point
  for the zero-trust gateway. The repo supports multiple servers (see
  "Multi-server model" below); flutterina is the first one.
- **Clusters (separate work):** k8s via sysext-bakery sysexts, bootstrapped by
  CAPI/Typhoon, GitOps via Argo/Flux.
- **Multi-cluster:** KubeStellar core engine on hosting cluster.
- **Connectivity:** each cluster runs Newt (userspace WireGuard tunnel client)
  dialing OUT to edge node. Clusters keep fully closed inbound firewall.

KubeStellar and Pangolin live ABOVE node layer.

## Materia concepts (quick reference)

- **Repository:** this git repo. Contains `MANIFEST.toml`, `components/`,
  `attributes/`.
- **Component:** a directory under `components/` — a service and its resources
  (quadlets, configs, manifest). Analogous to an ansible role.
- **Resource:** a file in a component. Installed to the host on `materia update`.
  - **Quadlet resources:** `.container`, `.network`, `.volume`, `.pod`, etc. →
    installed to `/etc/containers/systemd/<component>/`.
  - **Data resources:** everything else → installed to
    `/var/lib/materia/components/<component>/`.
  - **Templated resources:** end in `.gotmpl` → processed with Go templates
    before install. The `.gotmpl` suffix is stripped from the installed name.
- **Attributes:** variables used in templates. Stored in vault files under
  `attributes/`. Scoped: global, host, role, component.
- **Manifest:** `MANIFEST.toml` at repo root (host→component assignments) and
  per-component (defaults, services, secrets).
- **Secrets:** declared in component manifest `Secrets = ["attr"]`. Materia
  creates podman secrets automatically. Referenced in templates via
  `{{ secretEnv "attr" "TARGET" }}` or `{{ secretMount "attr" "ARGS" }}`.

## Architecture decisions (locked)

- **Pod, shared network namespace.** All three containers join `pangolin.pod`
  and share one network namespace — they reach each other over `localhost`.
  Ports are published at the pod level. This is architecturally required:
  Gerbil creates WireGuard tunnel interfaces in the shared namespace, and
  Traefik must reach the tunnel endpoint IPs (100.89.137.0/20 CGNAT range) to
  proxy traffic to tunneled resources. With separate containers on a network,
  those IPs are unreachable from Traefik — breaking all tunneled resource
  proxying.
- **Materia native secrets.** The `Secrets` list in the component manifest +
  `secretEnv`/`secretMount` macros replace the old manual `podman secret create`
  + seed-service approach. Materia manages the secret lifecycle.
- **No webhook/redeploy.** Materia IS the reconciler — it syncs the repo and
  applies changes on `materia update`. For push-based deploys, run materia on a
  timer or trigger it externally.
- **Config files as `.gotmpl` data resources.** Domain and other values are
  templated from attributes — no `sed` substitution, no `/etc/pangolin.env`.
- **Pinned image digests.** No `AutoUpdate=registry` — git-pinned GitOps.
  Renovate bumps digests via PRs (see `renovate.json5`).
- **Version source-of-truth in manifests.** Plugin versions (e.g. badger) live
  in `MANIFEST.toml` `[Defaults]` and are templated into config files via
  `{{ .badgerVersion }}`. Renovate's regex manager targets the manifest, not
  the templated output.
- **Host-generic components are assigned via `[Roles.base]`, not per-host
  `Components`.** `restic-backup` backs up generic host paths
  (`/var/lib/materia/components`, `/var/lib/containers/storage/volumes`), so
  every server should get it automatically. It's assigned to the `base` role
  (`[Roles.base] Components = ["restic-backup"]`) and hosts opt in with
  `Roles = ["base"]`, rather than listing it directly in each host's
  `Components`. New servers get it for free.
- **`restic-backup` is `Type=oneshot` + timer-activated, not `Restart=always`.**
  No `[Install]` section on the `.container.gotmpl` (never started directly);
  `Stopped = true` + `Oneshot = true` in the component manifest tell Materia
  to never auto-start it and not to flag a quick exit as a failure. Only
  `restic-backup.timer` (`Static = true`, `WantedBy=timers.target`) triggers
  it, on the `resticOnCalendar` attribute-driven schedule.

## Repo layout

```
MANIFEST.toml                    # repo manifest — host → component assignments
attributes/
  vault.yml                     # global attributes (SOPS-encrypted, age backend)
components/
  pangolin/                      # Pangolin edge component
    MANIFEST.toml                # component manifest — defaults, services, secrets
    pangolin.pod                 # podman pod (shared network namespace)
    letsencrypt.volume           # named volume for ACME cert storage
    app.container.gotmpl         # Pangolin app container
    gerbil.container.gotmpl      # Gerbil (WireGuard manager) container
    traefik.container.gotmpl     # Traefik reverse proxy container
    config/
      config.yml.gotmpl          # Pangolin config (non-secret, templated)
      privateConfig.yml.gotmpl   # Pangolin private config (branding, templated)
    traefik/
      traefik_config.yml.gotmpl  # Traefik static config (templated)
      dynamic_config.yml.gotmpl  # Traefik dynamic config (templated)
  restic-backup/                 # restic-backup component (role-assigned, see below)
    MANIFEST.toml                # component manifest — Secrets, Defaults, Services
    restic-backup.container.gotmpl # oneshot backup job, pulls the GHCR image by digest
    restic-backup.timer.gotmpl   # attribute-driven schedule (resticOnCalendar)
    ssh_config                   # static /usr/local/etc/ssh_config (sftp SSH options, see BUG-001)
    known_hosts                  # copy of provisioning/storageboxes/<box>/known_hosts
images/
  restic-backup/
    Dockerfile                   # scratch + static restic + static openssh + wrapper
    wrapper/                     # Go entrypoint: ping, init, backup, forget
provisioning/
  templates/
    hetzner.bu                  # Butane template for any Hetzner Cloud server
    bare-metal.bu                # Butane template for any bare-metal server
    bare-metal-debug.bu          # minimal RAM-boot discovery-only variant
  servers/
    flutterina/
      server.toml                # per-server config (type, hetzner/bare_metal settings)
      materia.ign                 # gitignored, rendered by `mise ign`
  storageboxes/
    <box>/
      storagebox.toml             # Storage Box config (type, location, snapshot plan)
      known_hosts                  # keyscanned SSH host keys, source of truth for the copy above
  ghostty.terminfo.b64          # pre-compiled Ghostty terminfo (base64), shared by both templates
  BARE-METAL.md                 # bare-metal bring-up runbook
mise.toml                       # pinned toolchain (age, sops, fnox, hcloud, butane, yq, etc.)
fnox.toml                       # fnox secret injection (Proton Pass provider)
.sops.yaml                      # SOPS creation rules (age recipient)
renovate.json5                  # Renovate config (image + plugin updates)
.mise/tasks/                    # mise file tasks (ign, server/new, hz/*, ipxe/*, clean)
```

## Multi-server model

One name identifies a server everywhere: the Hetzner Cloud server name, the
OS hostname (set explicitly by the Butane template — see "Provisioning"),
the `MANIFEST.toml` `Hosts.<name>` key, and the `provisioning/servers/<name>/`
directory. There is no global server-name env var — every server-scoped
task takes `--server-name` explicitly.

- **Add a server:** `mise server:new --server-name <name> --type
  hetzner|bare-metal [...]` — scaffolds `provisioning/servers/<name>/server.toml`
  and a `[Hosts.<name>]` entry in `MANIFEST.toml`.
- **Render its Ignition:** `mise ign --server-name <name>` (reads
  `server.toml` to pick the Hetzner or bare-metal template).
- **Provision it:** `mise hz:create --server-name <name>` (Hetzner) or the
  iPXE bare-metal flow (see `provisioning/BARE-METAL.md`).
- **Host-specific secrets:** `attributes/<name>.yml`, same SOPS/age vault
  convention as `attributes/vault.yml`, created on demand with `sops
  attributes/<name>.yml`.

`flutterina` (Hetzner, runs the `pangolin` component) is the first and
currently only server.

## How a host reconciles

1. Materia syncs this repo to `/var/lib/materia/source` on the target host.
2. Determines which components are assigned to the host (from `MANIFEST.toml`).
3. For each component, templates `.gotmpl` resources using attributes.
4. Installs quadlets to `/etc/containers/systemd/pangolin/`.
5. Installs data files to `/var/lib/materia/components/pangolin/`.
6. Creates/updates podman secrets declared in the component manifest.
7. `systemctl daemon-reload` if quadlets changed.
8. Restarts services whose resources changed (per `RestartedBy` in manifest).
9. Starts services that aren't running.

## Attributes

- `attributes/vault.yml` — global vault (SOPS-encrypted, age backend), all hosts.
- `attributes/<hostname>.yml` — host-specific vault (optional, also encrypted).
- `attributes/<role>.yml` — role-specific vault (optional, also encrypted).

SOPS encrypts all values in the vault by default (keys/structure visible,
values ciphertext). The age private key is baked into Ignition at
provision time and lives at `/etc/materia/key.txt` on the target host. Toolchain
(`age`, `sops`) managed via `mise.toml`. Edit vaults with
`sops edit attributes/vault.yml`.

## Gotchas / hard-won constraints

- **Pod, shared network namespace — required.** All containers join
  `pangolin.pod` and share one network namespace. This is not a style choice:
  Gerbil creates WireGuard tunnel interfaces (CGNAT range 100.89.137.0/20) in
  the shared namespace, and Traefik must reach those IPs to proxy traffic to
  tunneled resources. With separate containers on a network, those IPs are
  unreachable from Traefik — breaking all tunneled resource proxying, not just
  private HTTPS.
- **Pod restart safety.** The old repo's pod-drain issue (stopping all
  container services drains the pod, killing the infra container, causing
  "dependency failed" on next start) was a reconciler-script problem — it
  restarted everything at once with `systemctl restart`. Materia restarts only
  the service whose resource changed. The pod's infra container keeps the
  namespace alive during individual container restarts. The pod only restarts
  if the `.pod` file itself changes.
- **Startup ordering, not networking.** `connection refused to localhost:3001`
  is a race: Gerbil/Traefik must be `After=app.service`/`Requires=app.service`,
  and `app` uses `Notify=healthy` + `HealthCmd` so dependents wait until it
  serves.
- **SELinux relabels.** Volumes need `:z` (shared, lowercase) for dirs mounted
  into multiple containers, `:Z` for single-container dirs. Missing = "container
  starts but can't read volume" on enforcing SELinux. Harmless on permissive but
  keep for portability.
- **Newt is userspace WireGuard** — unprivileged, no kernel module. Gerbil
  (server side, VPS) needs NET_ADMIN/SYS_MODULE, may need `PodmanArgs=--privileged`
  if WireGuard can't initialise on the kernel.
- **Podman secrets are create-time.** Env secrets injected via
  `Secret=...,type=env` are read when the container is created. A rotated value
  needs the secret updated THEN `systemctl restart` the consumer — restarting
  alone won't repopulate. Materia handles the update; the restart is still
  required.
- **Systemd unit inline comments are literal values.**
  `PublishPort=443:443/udp  # HTTP/3` passes the full string including comment
  to Podman. The `/3` in `HTTP/3` triggered "protocol can only be specified
  once". Rule: quadlet file comments must be on their own lines, never inline
  after a value.
- **`.gotmpl` suffix is stripped.** `config.yml.gotmpl` installs as
  `config.yml`. Only the last `.gotmpl` is stripped; `conf.gotmpl.gotmpl`
  installs as `conf.gotmpl`.
- **`m_dataDir` returns the host path.** `{{ m_dataDir "pangolin" }}` expands
  to `/var/lib/materia/components/pangolin` — use it for Volume= bind mounts
  in `.container` files so configs land in the right place.
- **Materia restarts containers by default.** `.container` and `.pod` resources
  trigger a service restart on update automatically. Use `RestartedBy` and
  `ReloadedBy` in the component manifest to control which resources trigger
  restart/reload for which services. Set `Settings.NoRestart = true` to disable
  automatic restarts entirely.
- **Secrets prefix.** Materia prefixes podman secrets with `materia-` by
  default (`containers.secrets_prefix` config). The `secretEnv`/`secretMount`
  macros handle this transparently — don't manually prefix the name.
- **`secretMount` cannot set `mode=`, `uid=`, or `gid=`.** Confirmed against
  materia's actual source (`internal/materia/snippet.go`): the macro only
  ever emits `Secret=<name>,type=mount,target=<value>` — despite the
  materia-templates(5) docs implying "additional arguments as defined in the
  Podman manual" are supported. Podman's `type=mount` default mode (`0444`
  in the version tested) is group/other-readable, which breaks anything with
  strict permission requirements (OpenSSH private keys refuse to load with
  "Permissions ... too open" — BUG-002). For secrets needing a specific mode,
  bypass the macro and hand-write the `Secret=` line directly, e.g.
  `Secret=materia-<name>,type=mount,target=<path>,mode=0400` — the
  `materia-` prefix matches the default `SecretName()` behavior (plain
  string concatenation, confirmed via the project's own test mocks) as long
  as `secrets_prefix` isn't overridden.
- **Templated config files are bind-mounted individually from the data dir.**
  Materia installs templated files to `{{ m_dataDir "pangolin" }}/config/`;
  `.container` files bind-mount each file on top of the runtime volume
  (`Volume=...config/config.yml:/app/config/config.yml:z`). Never bind-mount
  the whole data dir as an app-writable directory — see next gotcha.
- **The data dir is fully managed — app-writable paths need named volumes.**
  Materia treats everything under `/var/lib/materia/components/<name>/` as its
  own: any file it didn't install is drift, planned for removal on every run
  (the planner has no ignore mechanism). Pangolin's db, gerbil's generated key,
  logs, and generated traefik configs were all scheduled for deletion. Runtime
  state lives in named volumes (`pangolin-config.volume`) instead.
- **`Secrets` must be a top-level manifest key.** In `MANIFEST.toml`, the
  `Secrets = [...]` line has to appear BEFORE the first table header
  (`[Defaults]`, `[[Services]]`, ...). TOML assigns keys to the most recently
  opened table, so a `Secrets` line inside/after a table silently becomes a
  table key, the top-level field parses empty, and secret creation just never
  appears in the plan — no error anywhere. This (not the attributes engine) was
  why podman secrets weren't created; with it fixed, SOPS creates them fine and
  no manual `podman secret create` workaround is needed.
- **Containers reach each other over localhost.** In a pod, all containers
  share one network namespace. Traefik/Gerbil configs reference `localhost:3001`,
  not `app:3001`. The `server.internal_hostname` in `config.yml` is `localhost`.
- **Gerbil is the networking edge.** In the official architecture, Traefik
  shares Gerbil's network namespace (docker-compose uses
  `network_mode: service:gerbil`). A pod achieves the same: all containers share
  one namespace, ports published at the pod level. Gerbil's SNI proxy can route
  TLS traffic in multi-node deployments; in single-node it's bypassed (443→443
  direct to Traefik).
- **Flatcar pure-podman: sysext symlinks, not service masking.** Docker and
  containerd are opt-out sysexts. The `-docker`/`-containerd` syntax in
  `enabled-sysext.conf` doesn't work (flatcar/Flatcar#1481). Instead, symlink
  `/etc/extensions/docker-flatcar.raw` and `containerd-flatcar.raw` to
  `/dev/null` — this removes the entire extension (binaries + units) so no
  service masking is needed.
- **openssh static build: no Alpine package, must build from source.**
  Alpine 3.22 has no `openssh-static` package (apk returns "no such package").
  The `restic-backup` image builder stage builds the `ssh` client from the
  OpenSSH portable tarball with `LDFLAGS=-static --with-privsep-path=/tmp`
  (privsep is sshd-only; `/tmp` is a harmless placeholder in the builder stage).
  Static builds need both header and static-archive packages: `zlib-dev` +
  `zlib-static`, `openssl-dev` + `openssl-libs-static`. The `opensshVersion`
  ARG in the Dockerfile is Renovate-trackable — bump it when a new release is
  needed. **`./configure` with no `--prefix`/`--sysconfdir` defaults the
  system-wide config path to `/usr/local/etc/ssh_config`, not
  `/etc/ssh/ssh_config`** — confirmed via `strings` on the built binary
  (BUG-001). Any `.container.gotmpl` mounting a system ssh config for this
  binary must target `/usr/local/etc/ssh_config`.
- **`RESTIC_SFTP_ARGS` is not a real restic env var.** Restic's sftp backend
  only accepts custom SSH args via the `-o sftp.args=...` CLI flag (added
  v0.16.1) — no `-o` flag has an environment-variable form. Since the
  wrapper never passes CLI flags to restic, SSH options (`IdentityFile`,
  `UserKnownHostsFile`, `StrictHostKeyChecking`) are set via a static
  `ssh_config` data resource bind-mounted to `/usr/local/etc/ssh_config`
  (see BUG-001 — NOT `/etc/ssh/ssh_config`, the conventional path most
  distro-packaged OpenSSH builds use; this statically-built client's
  compiled-in sysconfdir defaults to `/usr/local/etc` since the Dockerfile
  passes no `--sysconfdir` to `./configure`) — OpenSSH's system-wide client
  config, read regardless of `$HOME` (scratch has none).
- **Scratch images need `Tmpfs=/tmp` for restic.** Restic stages backup pack
  files in `os.TempDir()` (`/tmp` by default). Scratch has no `/tmp`
  directory at all, so `restic backup` fails with "no such file or
  directory" on the temp pack path unless the `.container.gotmpl` adds
  `Tmpfs=/tmp` (quadlet's tmpfs-mount directive — ephemeral, not part of any
  materia-managed path, so it doesn't trip the data-dir-drift gotcha above).
- **`Stopped = true` is the general "never auto-start" flag, not just for
  `.build`/`.image` services.** Confirmed against the materia manifest
  reference: "Prevents materia from starting the service." Any timer-
  activated oneshot service (not just build/image quadlets) should set it —
  used for `restic-backup.service` so only its `.timer` (not `materia
  update`) ever starts it. Pair with `Oneshot = true` ("prevents materia
  from checking if this service started successfully") for jobs that don't
  stay running.
- **CI can publish more than one image per push — verify the digest against
  the run, not just "the latest one someone noted down".** A digest
  recorded during earlier epic work turned out to belong to a CI run
  triggered before the final application logic was merged (a different,
  earlier run on the same day, from a commit that touched the Dockerfile
  but not yet the full wrapper source). The image pulled and ran — podman
  pull succeeded, exit code was 0 — but the binary was empty of the
  expected logic (confirmed with `strings` on the extracted binary; zero
  matches for expected log-message literals). `gh run list
  --workflow=<file>` + `gh run view <id> --log` (grep for
  `containerimage.digest`) is the authoritative source for "which digest
  came from which commit" — don't infer it from run ordering or timestamps
  alone.
- **A CI "gate" step only proves what it actually invokes.**
  `restic-backup-image.yml`'s original gate steps ran `restic version` and
  `ssh -V` to prove those binaries are static and functional — neither
  ever invoked `/usr/local/bin/wrapper` (the actual entrypoint). This is
  why a stale/incomplete wrapper build was able to publish successfully:
  the gate tested the dependencies, not the product (issue #19, found via
  e01s11's local `podman run` + `strings`-on-the-binary check). **Fixed:**
  a third gate step now runs the image with no env vars set and asserts a
  non-zero exit plus the exact `RESTIC_REPOSITORY is required` message —
  cheap (no real backend/secrets needed) but proves the wrapper's actual
  Go logic executed, not just its static dependencies. Verified locally
  against both the old stale digest (correctly fails the new gate) and the
  corrected one (passes) before landing.
- **Duplicated source-of-truth values need a flagged pairing, not just a
  comment.** Two values in this repo are intentionally copied from an
  external or provisioning-time source into a materia attribute/resource,
  with no tooling enforcing they stay in sync: `hcPingURL`
  (`attributes/vault.yml globals`, mirrors the Proton Pass
  `healthchecks/ping-url` field the `.bu` template also reads at transpile
  time) and `known_hosts` (`components/restic-backup/known_hosts`, mirrors
  `provisioning/storageboxes/<box>/known_hosts` refreshed by `mise
  hz:storagebox:keyscan`). If either upstream value rotates, update both
  copies manually.

## Provisioning (Butane/Ignition)

Every server is provisioned via Butane → Ignition on Flatcar, rendered from
one of two templates in `provisioning/templates/` based on
`provisioning/servers/<name>/server.toml`'s `type`. The `.bu` carries only
OS-level setup + materia installation — no reconciler scripts, no seed-secrets
service, no GitHub App credentials (materia replaces all of those).

### What every template installs

- **Explicit hostname** — `/etc/hostname` is set to `${SERVER_NAME}` at
  transpile time. Hetzner Cloud's Flatcar image also sets the guest hostname
  from the Hetzner server name via its metadata service, but that happens
  after Ignition and only on Hetzner — this write removes the dependency on
  that timing and gives bare-metal (no metadata service) the same guarantee.
  This is what makes the multi-server model's unified identity hold:
  materia's `m_facts "hostname"` resolves `MANIFEST.toml`'s `Hosts.<name>` by
  the box's actual OS hostname.
- **Pure-podman sysext** — `podman` enabled in `enabled-sysext.conf`; Docker and
  containerd disabled via `/dev/null` symlinks on their `.raw` sysext files (the
  `-docker` syntax in `enabled-sysext.conf` doesn't work — flatcar/Flatcar#1481).
  No service masking needed — the sysext units don't exist if the extension is
  removed. Podman's socket needs a oneshot workaround unit
  (`enable-podman-socket.service`) since Ignition's `enabled: true` on
  `podman.socket` is silently ignored — the sysext isn't loaded yet when
  Ignition processes systemd units.
- **`/etc/containers/policy.json`** — Flatcar doesn't ship one; every
  `podman pull` fails without it.
- **Age private key** → `/etc/materia/key.txt` — for SOPS vault decryption
  (`SOPS_AGE_KEY_FILE` points the materia quadlet at it).
- **Materia config** → `/etc/materia/config.toml` — source URL + SOPS engine.
- **Materia quadlet** — `materia-update.container` + `materia-update.timer`
  inlined in the .bu. Runs materia rootful containerized, pulls the repo,
  decrypts the vault, installs quadlets/configs, manages podman secrets,
  restarts services. Timer fires ~2min after boot (so a fresh server
  converges immediately) and daily thereafter; for faster syncs, trigger
  externally.
  The service pings a healthchecks.io-style check (slug
  `materia-update-<server>`, base URL substituted at transpile time via
  `${HC_PING_URL}` from Proton Pass) on start and on success/failure, so a
  silently-failing or stopped timer gets noticed. Ping failures never block
  the update (systemd `-` prefix). Size the check for the daily cadence
  (period 1 day, grace ~6 h) — boot-time runs add extra, harmless ping cycles.
- **SSH key** for `core` user — baked from Proton Pass (same key across every
  server today — see "Decisions still open").

`provisioning/templates/hetzner.bu` additionally sets a low-traffic reboot
window and loads the WireGuard kernel module (for Gerbil) — both specific to
the current single-Hetzner-VPS edge role, kept as-is rather than generalized
further. `provisioning/templates/bare-metal.bu` additionally sets up an LVM
data volume and a closed-inbound nftables posture — see
`provisioning/BARE-METAL.md`.

### Butane changes don't reach a running host

Ignition runs once, at first boot. Committing a change to a template (e.g.
the materia quadlet's env vars) does nothing to an already-provisioned
server — the host keeps running the config it was born with. Either rebuild
the server (`mise hz:rebuild --server-name <name>`) or hand-edit the target
file on the host (e.g. `/etc/containers/systemd/materia-update.container` +
`systemctl daemon-reload`) and mirror the change in the template for the
next provision.

### Transpile flow

1. `mise ign --server-name <name>` — reads `provisioning/servers/<name>/server.toml`
   to pick the template, fetches the age private key + SSH pubkey from Proton
   Pass via fnox, detects `REPO_URL` from git origin, substitutes placeholders,
   runs `butane --strict`, emits `provisioning/servers/<name>/materia.ign`.
   Treat the `.ign` as secret — never commit (already gitignored via `*.ign`).
2. `mise hz:upload-image` — one-time Flatcar snapshot upload to Hetzner
   (Hetzner servers only; server-agnostic, no `--server-name` needed).
3. `mise hz:create --server-name <name>` — creates the server; Hetzner passes
   the `.ign` as `user_data` to Flatcar at first boot. Reads the Hetzner
   server type/location from `server.toml` unless overridden with
   `--server-type`/`--server-location`.

Bare-metal servers use a different delivery path (iPXE, not `user_data`) —
see `provisioning/BARE-METAL.md`.

### Hetzner tasks

All `hz:*` tasks use the `hcloud` CLI (not raw HTTP), resolve `HCLOUD_TOKEN`
via `fnox exec`, and require `--server-name` explicitly — there is no global
server-name env var or default.

| Task | Description |
|---|---|
| `mise hz:upload-image` | Upload Flatcar image as a Hetzner snapshot |
| `mise hz:ensure-image` | Ensure a fresh snapshot exists (refreshes if stale) |
| `mise hz:create` | Create server from snapshot + Ignition |
| `mise hz:delete` | Delete server (`--confirm` required) |
| `mise hz:rebuild` | Rebuild server in-place with latest snapshot + Ignition |
| `mise hz:ssh` | SSH into server as `core@<ip>` |
| `mise hz:pull-config` | Backup pangolin runtime volumes to a local tarball (before rebuild) |
| `mise hz:push-config` | Restore tarball into pangolin runtime volumes (after rebuild) |

`hz:pull-config`/`hz:push-config` operate on the named podman volumes
(`systemd-pangolin-config`, `systemd-letsencrypt`), not the materia data dir —
templated configs are re-rendered by materia and don't need backup. The
tarball layout mirrors the container's `/app/config` (letsencrypt as a
subdirectory), so backups made by the old pangolin-edge repo's tasks against
`/var/lib/pangolin/config` push straight into a materia host. `push-config`
works before the first `materia-update` run: it pre-creates the volumes with
the quadlet names and the quadlet units reuse them (`--ignore`).

### Storage Boxes (backups)

`hz:storagebox:*` provisions the Hetzner Storage Box that the
`restic-backup` component (#2) backs up to. Same conventions as `hz:*`:
`hcloud` via `fnox exec`, explicit name flags, config committed as
`provisioning/storageboxes/<name>/storagebox.toml`.

| Task | Description |
|---|---|
| `mise hz:storagebox:create --box-name <n>` | Create box from `storagebox.toml` — SSH-only, delete-protected, daily Hetzner snapshots |
| `mise hz:storagebox:delete --box-name <n> --confirm` | Delete box (delete-protected boxes also need `--disable-protection`) |
| `mise hz:storagebox:keyscan --box-name <n>` | Pin the box's SSH host keys to `provisioning/storageboxes/<n>/known_hosts` (commit it) |
| `mise hz:storagebox:subaccount --box-name <n> --server-name <s>` | Per-server subaccount, home `backups/<s>`, SSH-only |
| `mise hz:storagebox:install-key --box-name <n> --server-name <s>` | Generate ed25519 key, install via `install-ssh-key` (port 23), print vault handoff |

Order per server: `create` → `keyscan` (commit `known_hosts`) →
`subaccount` → `install-key` → paste the printed private key into
`attributes/<server>.yml` (`sops edit`) as
`components.restic-backup.storageBoxSshKey`, plus the printed
`sftp://...` repository attribute. Passwords are printed once — store
them in Proton Pass (both are resettable via
`hcloud storage-box [subaccount] reset-password`) — one item per box
(`storagebox-<box>`) with a `primary-password` field and a
`<server>-password` field per subaccount. Subaccounts have no
API-side SSH keys; `install-ssh-key` writes `<home>/.ssh/authorized_keys`
in both port-23 (OpenSSH) and port-22 (RFC4716) formats.

## Development conventions

- **Focused semantic commits.** Each commit covers exactly one logical change.
  Subject ≤50 chars, Conventional Commits style (`feat:`, `fix:`, `docs:`,
  `chore:`). Body only when the "why" isn't obvious from the diff.
- **Keep the repo generic.** No real domain names, server IPs, or other
  deployment-specific infra details in tracked files. Deployment-specific values
  live in `attributes/` vaults (encrypted for production), not hardcoded.
- **AI sessions: always update this file.** After any session that uncovers a
  non-obvious constraint, fix, or pattern, add it to Gotchas (or the relevant
  section) and commit. This file is committed and travels with the repo.
- **No upstream issues without permission.** Never file issues, PRs, or comments
  in dependency/upstream repos without express permission from the user.

## Decisions still open (future revisit)

- **Butane/provisioning:** lives in this repo, one template per
  provisioning type (`provisioning/templates/hetzner.bu`,
  `bare-metal.bu`), rendered per-server into
  `provisioning/servers/<name>/materia.ign`. The .bu carries OS setup +
  materia quadlet + age key. Materia replaces the old reconciler,
  seed-secrets, webhook, and GitHub App credentials entirely.
- **Server secret isolation:** not yet done. `.sops.yaml` has one shared
  age recipient for all `attributes/*.yml`, and `fnox.toml`'s
  `CORE_SSH_PUBKEY`/`AGE_SECRET_KEY` are shared across every server. Fine
  for a small, trusted fleet; revisit (multiple SOPS recipients, per-server
  SSH keys) if that stops being true.
- **Renovate:** `renovate.json5` covers image pins in `*.container.gotmpl`
  (native `quadlet` manager extended to match `.gotmpl` files), the `ee-` prefix
  on pangolin images (regex versioning), and the badger plugin version in
  `MANIFEST.toml` (`custom.regex` → `github-tags`). The materia image itself
  (`ghcr.io/stryan/materia:stable` in the .bu) is not yet covered by Renovate —
  add a `custom.regex` manager for it when ready.
- **Attributes engine:** SOPS with age backend. `attributes/vault.yml` is
  value-level encrypted (keys visible, secret values ciphertext). The age
  private key is baked into Ignition at provision time and lives at
  `/etc/materia/key.txt` on the target host. Toolchain (`age`, `sops`) managed
  via `mise.toml`.
- **Push-based deploys:** materia is pull-based by default. For instant
  deploys, either run materia on a short timer or trigger `materia update`
  externally (e.g. via SSH, a systemd timer, or a future CI hook).

## Reference sources

- Materia docs: https://primamateria.systems/documentation/latest
- Materia quickstart: https://primamateria.systems/quickstart.html
- Materia manifest reference:
  https://primamateria.systems/documentation/latest/reference/materia-manifest.5.html
- Materia templates reference (macros, snippets):
  https://primamateria.systems/documentation/latest/reference/materia-templates.5.html
- Materia SOPS config:
  https://primamateria.systems/documentation/latest/reference/materia-config-sops.5.html
- Materia age config:
  https://primamateria.systems/documentation/latest/reference/materia-config-age.5.html
- SOPS: https://github.com/getsops/sops
- Age: https://github.com/FiloSottile/age
- restic scripting/env vars: https://restic.readthedocs.io/en/stable/075_scripting.html
- restic sftp backend: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
- Pangolin docker compose: https://docs.pangolin.net/self-host/manual/docker-compose
- Pangolin podman quadlets: https://docs.pangolin.net/self-host/manual/podman-quadlets
- Pangolin Newt Helm: charts.fossorial.io (newt chart)
- Renovate: https://docs.renovatebot.com

<!-- BEGIN bigpowers:project -->
## Agent Rules (bigpowers-managed)

- **Workflow Mandate:** You MUST use the bigpowers skills (`plan-work`,
  `develop-tdd`, `orchestrate-project`) to perform tasks. DO NOT write changes
  directly in response to a user prompt without planning first.
- **Always Green:** Preflight and CI must be green before forward work.
- **Read specs/ before writing code.** Check `specs/state.yaml` for active flow.
- **All planning MUST be written to `specs/` before any IaC change is generated.**
- **Write the minimum change that solves the stated problem.** Nothing extra.
- **Run Preflight after every change.** Show evidence before declaring done.
<!-- END bigpowers:project -->

<!-- BEGIN bigpowers:context-routing -->
## Context Routing (bigpowers-managed)

| Glob | AGENTS.md |
|------|-----------|
| `*` | `./AGENTS.md` (this file) |
<!-- END bigpowers:context-routing -->

<!-- BEGIN bigpowers:learned-preferences -->
## Learned User Preferences (bigpowers-managed)

_None yet — session-state skill appends entries here as preferences are learned._

## Workspace Facts (bigpowers-managed)

_None yet._
<!-- END bigpowers:learned-preferences -->

