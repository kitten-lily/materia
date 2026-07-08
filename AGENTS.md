# Materia Podman Orchestration

Context brief: repo structure, materia concepts, conventions, gotchas.

## Goal

Manage Podman-hosted services via [Materia](https://primamateria.systems/) — a
GitOps tool that templates resources, installs quadlets/configs, manages podman
secrets, and restarts services. No hand-rolled reconciler, no webhook, no
seed-secrets service. Materia is the single source of truth enforcement.

## Where this sits in the larger stack

- **Edge node (this repo):** Pangolin (app + Gerbil + Traefik) on a public VPS.
  Single public entry point for the zero-trust gateway.
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
provisioning/
  materia.bu                    # Butane config (OS setup + materia quadlet + age key)
  ghostty.terminfo.b64          # pre-compiled Ghostty terminfo (base64)
mise.toml                       # pinned toolchain (age, sops, fnox, hcloud, butane, etc.)
fnox.toml                       # fnox secret injection (Proton Pass provider)
.sops.yaml                      # SOPS creation rules (age recipient)
renovate.json5                  # Renovate config (image + plugin updates)
.mise/tasks/                    # mise file tasks (ign, hz/*, clean)
```

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

## Provisioning (Butane/Ignition)

The node is provisioned via Butane → Ignition on Flatcar. The `.bu` carries only
OS-level setup + materia installation — no reconciler scripts, no seed-secrets
service, no GitHub App credentials (materia replaces all of those).

### What the .bu installs

- **Pure-podman sysext** — `podman` enabled in `enabled-sysext.conf`; Docker and
  containerd disabled via `/dev/null` symlinks on their `.raw` sysext files (the
  `-docker` syntax in `enabled-sysext.conf` doesn't work — flatcar/Flatcar#1481).
  No service masking needed — the sysext units don't exist if the extension is
  removed.
- **`/etc/containers/policy.json`** — Flatcar doesn't ship one; every
  `podman pull` fails without it.
- **Reboot window** — single public ingress, auto-reboot confined to low-traffic.
- **WireGuard module** — `/etc/modules-load.d/wireguard.conf` for Gerbil.
- **Age private key** → `/etc/materia/key.txt` — for SOPS vault decryption.
- **Materia config** → `/etc/materia/config.toml` — source URL + SOPS engine.
- **Materia quadlet** — `materia-update.container` + `materia-update.timer`
  inlined in the .bu. Runs materia rootful containerized, pulls the repo,
  decrypts the vault, installs quadlets/configs, manages podman secrets,
  restarts services. Timer fires daily; for faster syncs, trigger externally.
- **SSH key** for `core` user — baked from Proton Pass.

### Butane changes don't reach a running host

Ignition runs once, at first boot. Committing a change to `materia.bu` (e.g.
the materia quadlet's env vars) does nothing to an already-provisioned server —
the host keeps running the config it was born with. Either rebuild the server
(`mise hz:rebuild`) or hand-edit the target file on the host (e.g.
`/etc/containers/systemd/materia-update.container` + `systemctl daemon-reload`)
and mirror the change in the .bu for the next provision.

### Transpile flow

1. `mise ign` — fetches age private key + SSH pubkey from Proton Pass via fnox,
   detects REPO_URL from git origin, substitutes placeholders in the .bu, runs
   `butane --strict`, emits `provisioning/materia.ign`. Treat the .ign as
   secret — never commit.
2. `mise hz:upload-image` — one-time Flatcar snapshot upload to Hetzner.
3. `mise hz:create` — creates server; Hetzner passes .ign as `user_data` to
   Flatcar at first boot.

### Hetzner tasks

All `hz:*` tasks use the `hcloud` CLI (not raw HTTP) and resolve `HCLOUD_TOKEN`
via `fnox exec`. Override the server name with `--server-name` or by setting
`HCLOUD_SERVER_NAME` in `.mise.local.toml`.

| Task | Description |
|---|---|
| `mise hz:upload-image` | Upload Flatcar image as a Hetzner snapshot |
| `mise hz:ensure-image` | Ensure a fresh snapshot exists (refreshes if stale) |
| `mise hz:create` | Create server from snapshot + Ignition |
| `mise hz:delete` | Delete server (`--confirm` required) |
| `mise hz:rebuild` | Rebuild server in-place with latest snapshot + Ignition |
| `mise hz:ssh` | SSH into server as `core@<ip>` |

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

- **Butane/provisioning:** lives in this repo (`provisioning/materia.bu`).
  The .bu carries OS setup + materia quadlet + age key. Materia replaces the
  old reconciler, seed-secrets, webhook, and GitHub App credentials entirely.
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
- Pangolin docker compose: https://docs.pangolin.net/self-host/manual/docker-compose
- Pangolin podman quadlets: https://docs.pangolin.net/self-host/manual/podman-quadlets
- Pangolin Newt Helm: charts.fossorial.io (newt chart)
- Renovate: https://docs.renovatebot.com
