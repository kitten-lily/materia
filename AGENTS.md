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
- **Newt tunnel client: shared `newt-net` network + provisioning keys.** Any
  host that needs to expose container services through the Pangolin edge
  gets the `newt` component via `[Roles.tunneled]`. Newt joins a named
  podman network (`newt-net`); services that should be tunnel-reachable
  also join `newt-net`, and Newt reaches them by **container name** (not
  IP, not `PublishPort`). Container name resolution only works on named
  networks, not the default bridge — this is why `newt-net` exists as a
  `.network` quadlet rather than relying on the default bridge. Services
  NOT on `newt-net` are invisible to the tunnel. `DOCKER_ENFORCE_NETWORK_
  VALIDATION=true` adds defense in depth: Newt validates that a target
  container is on `newt-net` before proxying. No `PublishPort` on Newt —
  it's an outbound-only WebSocket client that dials to the Pangolin edge,
  so it works behind the nftables closed-posture firewall (all outbound
  allowed). Provisioning uses Pangolin **provisioning keys** (`spk_...`):
  Newt exchanges the key for its own `id` + `secret` on first boot and
  persists them to a named volume (`newt-config.volume`). No manual
  "create site in dashboard → copy credentials → sops --set" step. The
  key is consumed once; kept in the vault for re-provisioning. The
  provisioning blueprint (`blueprint.gotmpl`) is **imperative**
  (`--provisioning-blueprint-file`, not `--blueprint-file`): applied once
  at first boot to auto-create the site, then the dashboard is the source
  of truth. See `specs/plans/issue-newt-component.md`.
- **Newt on the edge node (flutterina) too, for health checks.** The edge
  node itself runs Newt not to tunnel external traffic in, but so that
  Pangolin's Health Checks feature can reach standalone containers like
  beszel-hub through the tunnel (by container name on `newt-net`) instead
  of via local-site resources (which require the podman bridge gateway IP
  and don't work with Pangolin's arbitrary HTTP health checks). Both
  flutterina and bow are in `[Roles.tunneled]`.

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
    restic-backup.timer.gotmpl   # attribute-driven schedule (resticOnCalendar), targets the trigger below
    restic-backup-trigger.service # untracked-restart wrapper (systemctl restart), see BUG-004
    ssh_config                   # static /usr/local/etc/ssh_config (sftp SSH options, see BUG-001)
    known_hosts                  # copy of provisioning/storageboxes/<box>/known_hosts
  beszel-hub/                    # beszel monitoring hub (standalone, flutterina-only)
    MANIFEST.toml                # component manifest — Defaults, Services (no Secrets)
    beszel-hub.container.gotmpl  # standalone container, port 8090, routed via Pangolin local site
    beszel-data.volume           # named volume for /beszel_data (root-owned, no User=/Group=)
  beszel-agent/                  # beszel monitoring agent (role-assigned, see below)
    MANIFEST.toml                # component manifest — Secrets = ["beszelToken"], Defaults, Services
    beszel-agent.container.gotmpl # Network=host, podman socket mount, connects to hub via public URL
  newt/                          # Pangolin tunnel client (role-assigned, [Roles.tunneled])
    MANIFEST.toml                # component manifest — Secrets = ["newtProvisioningKey"], Services
    newt.container.gotmpl        # userspace WireGuard tunnel client, joins newt-net network
    newt.network                 # named podman network for tunnel-reachable services
    newt-config.volume           # named volume for Newt's provisioned id/secret
    blueprint.gotmpl             # provisioning blueprint (imperative, applied once at first boot)
  music/                        # Navidrome music server + Aonsoku web client (standalone, bow-only)
    MANIFEST.toml                # component manifest — Defaults, Services (no Secrets)
    navidrome.container.gotmpl    # Navidrome server, joins newt-net, read-only /music bind, navidrome.<baseDomain>
    aonsoku.container.gotmpl      # Aonsoku web client, joins newt-net, SERVER_URL=navidrome public URL, music.<baseDomain>
    navidrome-data.volume         # named volume for /data (DB, cache; root-owned, no User=/Group=)
  grimmory/                     # Grimmory ebook/comic/audiobook library + MariaDB sidecar (standalone, bow-only)
    MANIFEST.toml                # component manifest — Secrets (grimmoryDbPassword, mariadbRootPassword), Services
    grimmory.container.gotmpl     # Grimmory app, joins newt-net, /books bind from LVM data disk, grimmory.<baseDomain>
    grimmory-mariadb.container.gotmpl # Minimus MariaDB sidecar, joins newt-net, no PublishPort, MARIADB_* env
    grimmory-data.volume          # named volume for /app/data (UID 1000)
    grimmory-bookdrop.volume      # named volume for /bookdrop (UID 1000)
    grimmory-mariadb-config.volume # named volume for /var/lib/mysql (UID 1000)
  audiobookshelf/                # Audiobookshelf audiobook + podcast server (standalone, bow-only)
    MANIFEST.toml                # component manifest — Defaults, Services (no Secrets)
    audiobookshelf.container.gotmpl # joins newt-net, ro AudioBooks + rw Podcasts binds from LVM data disk, audiobookshelf.<baseDomain>
    audiobookshelf-config.volume  # named volume for /config (root-owned, no User=/Group=)
    audiobookshelf-metadata.volume # named volume for /metadata (root-owned, no User=/Group=)
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
  required. **Podman secrets can also go stale** — materia doesn't always
  detect that a secret's *value* changed (vs. its *name*). After rotating a
  secret value in the vault, if the container still sees the old value,
  `sudo podman secret rm materia-<name>` the stale one and re-run
  `materia-update` to force recreation (BUG-003, layer 3).
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
- **Never hand off a multi-line secret via manual copy-paste into `sops
  edit`.** `mise hz:storagebox:install-key` used to `cat` a freshly
  generated private key to the terminal with instructions to paste it into
  an interactive editor session under a YAML `|-` block. Terminal
  scrollback reflow, clipboard managers, or one misindented line can
  silently corrupt a multi-line key while leaving it looking plausible
  (BEGIN/END markers intact) — `ssh` then fails to load it with
  `error in libcrypto` (BUG-003), a much harder-to-diagnose failure than an
  outright rejected key. Fix: inject secret file content programmatically
  with `jq -Rs .` (JSON-encodes raw bytes, embedded `\n` escapes, no reflow
  risk) piped into `sops --set '["path"]["to"]["key"] <json>' vault.yml`
  — decrypts, sets, and re-encrypts in place, no human ever retypes the
  value.
- **OpenSSH private keys need a trailing newline after the END marker.**
  `ssh`'s `ssh_config` `IdentityFile` loader fails with `error in libcrypto`
  on an ed25519 key whose final line (`-----END OPENSSH PRIVATE KEY-----`)
  has no trailing newline, even though `ssh-keygen -y` accepts the same
  file (OpenSSH bug #3849). Some `ssh-keygen` builds produce a key without
  the final newline. When storing a key for podman secret mount, ensure the
  trailing newline is present: `tail -c 1 <file> | wc -l` is 0 if the last
  byte isn't a newline — append one with `printf '\n' >> <file>`. Do NOT
  pipe through `sed '$a\'` — that syntax is not portable across GNU/BSD
  `sed` and can silently corrupt the key content (BUG-003, layer 2).
- **`ssh-keygen -y` and `ssh` use different key-loading code paths.**
  `ssh-keygen -y` is more tolerant — it accepts keys with missing trailing
  newlines that `ssh`'s `IdentityFile` loader rejects with `error in
  libcrypto`. Don't trust `ssh-keygen -y` alone as a "key is valid" check;
  always test with an actual `ssh -v` connection attempt (or `ssh -G` for
  config resolution, though note `ssh -G` does NOT load/parse keys — only
  a real connection exercises that path).
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
- **Attribute scoping is strict per-component — a missing key is a fatal
  vault-load error, not a template no-op.** `attributes/vault.yml`'s
  `components.<name>.*` keys are only visible when templating that specific
  component; they are NOT inherited by other components even if the value is
  conceptually shared. `beszel-hub.container.gotmpl`'s `{{ .baseDomain }}`
  referenced a value that existed only under `components.pangolin`, so
  materia-update failed with `map has no entry for key "baseDomain"` while
  loading beszel-hub — and because this is a fatal load error, it aborted
  the *entire* run, blocking reconciliation of every component on the host,
  not just beszel-hub. Fix: any value used by more than one component
  belongs in top-level `globals` (`sops --set '["globals"]["key"] "value"'`
  + `sops unset attributes/vault.yml '["components"]["old-owner"]["key"]'`
  via `fnox exec --`), not duplicated per-component.
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
- **Materia's oneshot final-state wait is currently broken upstream —
  don't pair `Oneshot = true` with `RestartedBy`.** Confirmed against
  `stryan/materia` source (`pkg/services/service_state.go`): the
  internal sentinel used to mean "oneshot service, skip the final-state
  wait" (`services.StateInternalWildcard`, string value `"wildcard"`) is
  deliberately excluded from `serviceStateMap` ("Note we don't put this
  in the map since its internal"). Every place that reconstructs the
  sentinel from its stored string — `executor/execute.go`'s final health
  check and `executor/service_helpers.go`'s `waitService`, both via
  `services.NewServiceState(string)` — gets `StateUnknown` back instead,
  since the lookup silently falls through. `WaitUntilState`'s short
  circuit (`if state == StateInternalWildcard { return nil }`) can then
  never trigger, so it always polls for `ActiveState == "unknown"` (a
  state that never legitimately occurs) until materia's own default
  timeout elapses, then reports `FATA operation timeout: service ...
  did not reach state unknown` — even though the underlying job finished
  and exited 0. This is deterministic, not a race: any `Oneshot = true`
  service with a `RestartedBy` trigger will fail this way every time its
  watched resources change, regardless of job duration. Confirmed on
  flutterina (#31): `restic-backup.service` looked fine for months
  because `RestartedBy` only fires on a resource change, and the first
  real trigger (the `BACKUP_PATHS` quoting fix, commit `d6b4fbd`) hit it
  immediately. Workaround until this is fixed upstream: don't set
  `RestartedBy` on an `Oneshot` service — let its `.timer` pick up
  resource changes on its next natural fire instead of forcing an
  immediate synchronous restart. `restic-backup.service` had its
  `RestartedBy` removed for this reason; resource changes to it now take
  up to 24h (next timer fire) to apply instead of immediately. See
  `specs/plans/issue-31-oneshot-wait-timeout.md`.
- **That plan's "next timer fire" assumption was wrong — `RemainAfterExit=
  yes` makes a `.timer`'s daily fire a permanent no-op after the first
  successful run (BUG-004).** `restic-backup.container.gotmpl`'s generated
  unit has `Type=oneshot` + `RemainAfterExit=yes`, so once the service
  completes successfully it settles into `active (exited)` and stays
  there. `OnCalendar` timers fire by issuing a plain `systemctl start`,
  and `start` on an already-`active` unit is a no-op in systemd — it does
  NOT re-run `ExecStart`. So the *first* successful run permanently
  blocks the timer from ever triggering the service again, until
  something else cycles the unit through `inactive` (a manual `restart`,
  or materia auto-restarting because the `.container.gotmpl` itself
  changed — quadlet `.container` changes always restart their service,
  independent of `RestartedBy`). Symptom: `systemctl status
  restic-backup.timer` shows `Trigger: n/a` forever after the first run,
  even though `list-timers`/`LastTriggerUSec` shows it firing correctly
  on schedule — the fire happens, but silently does nothing. Caught
  2026-07-15 when healthchecks.io flagged both `restic-backup-bow` and
  `restic-backup-flutterina` down: bow's last real run was stuck at
  2026-07-14 17:48 (~22h stale), flutterina's at 2026-07-14 05:00 (~35h
  stale) — in both cases the *only* thing that had been producing real
  runs recently was an incidental `.container.gotmpl` image-digest bump,
  not the timer's own daily schedule. `sudo systemctl restart
  restic-backup.service` immediately fixes a stuck instance (confirmed:
  the backup ran AND `NextElapseUSecRealtime` correctly repopulated with
  the next day's midnight) but is a same-day workaround only — the next
  `OnCalendar` fire hits the identical no-op once that run also settles
  into `active (exited)`. **Do not just drop `RemainAfterExit=yes` to
  fix this** — tried on 2026-07-15 (commit `0b2bb11`, reverted as
  `0620018`) and it broke `materia-update` entirely, on every future
  run: materia's default "quadlet `.container` file changed → always
  restart" health check unconditionally expects the restarted service
  to end up `active`, and that check is NOT covered by `Oneshot = true`
  (that flag only skips a *different* code path — the one issue #31
  patched around). Confirmed live on flutterina: `FATA Execute in
  unhealthy state: Expected map[restic-backup.service:active], Actual
  map[restic-backup.service:inactive]`, which blocks reconciliation of
  every component on the host, not just restic-backup — and recurs on
  every future `restic-backup.container.gotmpl` change (i.e. every
  Renovate digest bump), so it's strictly worse than the original bug.
  **Fix (implemented 2026-07-16):** neither known materia restart
  trigger can correctly restart a `Type=oneshot` service without
  materia either timing out (issue #31's wildcard-sentinel bug, for
  `RestartedBy`-triggered restarts) or asserting a wrong expected state
  (this bug's default-trigger path, confirmed in
  `pkg/planner/planner.go`'s `resourceActionWithMetadata` — it never
  consults `Oneshot` at all for a plain-image container, unlike the
  adjacent `.build`/`.image` branch). Both are materia Go source bugs,
  not fixable in this repo. Workaround: `Settings.NoRestart = true` on
  `components/restic-backup/MANIFEST.toml` disables materia's default
  `.container`/`.pod`-change auto-restart entirely for the component,
  and a new `restic-backup-trigger.service` (`[[Services]]` entry,
  `Stopped = true` — installed but never auto-started; safe because
  materia classifies it as `ResourceTypeService`, which the buggy
  Container/Pod-only auto-restart loop never touches) whose only job is
  `systemctl restart restic-backup.service` is what `restic-backup.timer`
  now targets, instead of the service directly. `systemctl restart`
  (unlike `start`) always re-executes `ExecStart` regardless of the
  target's current state, fixing the original no-op unconditionally.
  Trade-off: ALL `restic-backup` resource changes (not just the
  `RestartedBy`-covered ones #31 already accepted this for) now take up
  to 24h to apply instead of immediately — a real behavior change, since
  quadlet-file changes previously applied immediately (the only thing
  that had been keeping backups running pre-fix). Pending live
  verification across 2+ real unattended timer fires before considered
  fully closed — see
  `specs/plans/issue-38-restic-backup-timer-noop.md` and
  `specs/bugs/BUG-004-restic-backup-timer-remainaftereexit-noop.md`.
- **Minimus images run as non-root (UID 1000), not root like most upstream
  images.** Three things break when switching from an upstream image to a
  minimus equivalent: (1) **privileged port binding** — UID 1000 can't bind
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
  copies manually. **`known_hosts` drift is now CI-gated**
  (`.github/workflows/preflight.yml`'s `known-hosts-drift` job, equivalent
  to `mise check:known-hosts`): a PR that updates a storagebox source
  without refreshing the component copy fails preflight. Run
  `mise check:known-hosts --fix` after `hz:storagebox:keyscan` to copy the
  union of all box sources into the component file (the keyscan task now
  prints this reminder). `hcPingURL` has no such check — it mirrors an
  external Proton Pass field this repo can't read at CI time — so it stays
  a true manual pairing. The `known_hosts` drift bug bit `bow` once
  (issue #34's follow-on): the sub2 subaccount was added to the source
  (`622ee5e`) but the component copy (committed `aa8688a`) was never
  refreshed, so restic-backup failed host-key verification on every run
  until #34's nftables fix unblocked the egress path and surfaced it.
- **Beszel hub is a standalone container, not in `pangolin.pod`.** The hub
  runs outside the pod's shared network namespace and is routed to the public
  internet via Newt tunnel (on flutterina: Newt + beszel-hub share the
  `newt-net` network, so Newt reaches the hub by container name
  `beszel-hub:8090`), not by manual `dynamic_config.yml.gotmpl` changes.
  Joining the pod would put a monitoring service in the same network
  namespace as the edge node's public ingress — a misbehaving hub could
  affect the gateway. Keeping it standalone isolates it. The hub also joins
  `newt-net` so the tunnel path works; the `PublishPort=8090:8090` is kept
  as a safety net for the previous local-site resource path until the
  dashboard is fully reconfigured to route through the tunnel. The hub and
  agent are separate components (`beszel-hub` assigned to
  `Hosts.flutterina`, `beszel-agent` assigned to `[Roles.base]`) to avoid
  the "install but don't start" complexity of conditional resource
  rendering — materia has no native conditional-rendering mechanism. See
  `specs/plans/issue-20-beszel-monitoring.md`.
- **Monitoring the monitor: beszel hub liveness is a Pangolin-native health
  check, not a custom systemd timer.** Beszel is itself the alerting system,
  so a silently-dead hub would leave the whole fleet blind with no alarm.
  Pangolin has a built-in [Health Checks](https://docs.pangolin.net/manage/alerting/health-checks)
  feature (Alerting section) that supports *arbitrary* (standalone) HTTP
  checks against any address a Pangolin site can reach — not just checks
  tied to a routable resource target. An arbitrary HTTP check against the
  hub's pocketbase `/api/health` endpoint, paired with an
  [Alert Rule](https://docs.pangolin.net/manage/alerting/alert-rules)
  (email and/or webhook on unhealthy/recovery), replaces what would
  otherwise be a bespoke systemd timer + healthchecks.io ping — no new
  IaC, configured entirely in the Pangolin dashboard. The check target
  address has the same reachability constraint as the local-site resource
  target (Pangolin's site process cannot use `localhost:8090` for a
  standalone container — see the gotcha above), so it's set up and
  verified alongside that local-site resource, tracked in #22. Agent-down
  alerts, by contrast, are handled *inside* beszel via its native Shoutrrr
  webhook notifications (configured in the hub UI, Settings > Notifications,
  not IaC — beszel stores them in its DB). The split is deliberate: the
  Pangolin health check covers hub-down (which beszel can't self-report),
  beszel's own webhooks cover agent-down (which Pangolin can't see). Both
  are deploy-time dashboard configuration, zero component code. See #24.
- **Beszel agent bootstrap is a two-step, not-automatable deploy — do not
  wire `[Roles.base] Components` until secrets exist.** The hub generates
  `TOKEN` (WebSocket registration) and `KEY` (agent auth) only *after* an
  admin adds the system in its web UI, but `beszel-agent` is assigned via
  `[Roles.base]` (same pattern as `restic-backup` — every host gets it for
  free). If the role assignment lands before `attributes/<server>.yml` has
  `components.beszel-agent.beszelToken`/`beszelKey`, the next
  `materia-update` hits the exact same fatal "map has no entry for key"
  failure as the `baseDomain` incident — one component's missing attribute
  aborts reconciliation of every component on the host. Sequence: (1) land
  `components/beszel-agent/` code without touching `[Roles.base]`; (2) hub
  UI → create admin → add system → get TOKEN/KEY; (3) `sops edit
  attributes/<server>.yml`, set both values (KEY is not secret — only
  `beszelToken` is in the component's `Secrets` list); (4) wire
  `[Roles.base] Components = ["restic-backup", "beszel-agent"]` in the same
  commit/push as step 3, never before. `HUB_URL` (`https://beszel.<baseDomain>`)
  is a global attribute (`beszelHubUrl`) since the agent reaches the hub
  through Pangolin's public TLS endpoint, same as a browser — no inbound
  port needed on agent hosts. `Network=host` + a read-only
  `/run/podman/podman.sock` mount give the agent host network stats and
  container stats; the podman socket is already enabled by every `.bu`
  template's `enable-podman-socket.service`, so no extra provisioning is
  needed for it.
- **Pangolin public resources default to Pangolin's own auth (Platform SSO),
  which breaks the agent's WebSocket handshake.** Confirmed on flutterina:
  `curl -sSD- https://beszel.<baseDomain>/` returned `302` to
  `https://pangolin.<baseDomain>/auth/resource/<uuid>?redirect=...`, and
  `beszel-agent.service` logged `WebSocket connection failed
  err="unexpected status code: 302"` on every retry — even though the
  local-site resource itself was configured correctly (routing worked,
  the redirect target proved the resource exists and Traefik reached it).
  Per Pangolin's docs, *all public resources have Pangolin auth enabled by
  default* — an unauthenticated request gets redirected to an interactive
  login page. Beszel's agent can't complete that flow (it's a headless
  WebSocket client authenticating itself via TOKEN/KEY), and beszel-hub
  already has its own agent authentication — Pangolin's auth layer on top
  is redundant and fatal to the connection. Fix: in the Pangolin dashboard,
  open the `beszel.<baseDomain>` resource and disable authentication (no
  Pangolin auth / public, no SSO) so requests pass straight through to
  Traefik → beszel-hub. Dashboard-only change, no repo/IaC involved — but
  easy to miss since the *routing* half of local-site setup looks correct
  right up until this auth layer silently intercepts every request.
- **nftables.service ships with a `ConditionPathExists=` on its rules
  file, and the exact path depends on the Flatcar/nftables version.** The
  base unit gates its own startup on the rules file existing — a dropin
  that redirects `ExecStart=` to a custom path is not enough: the
  condition is evaluated *before* the dropin's `ExecStart` would run, so
  if the expected file doesn't exist, systemd skips the entire service
  (`Active: inactive (dead)`, `Condition: start condition unmet`) and the
  dropin never executes. The path itself varies by version: older
  nftables builds check `/etc/nftables.conf`, newer builds (Flatcar
  4593+, nftables 1.1.x) check `/etc/nftables/rules/main.nft` and
  `ExecStart` uses `nft 'flush ruleset; include
  "/etc/nftables/rules/main.nft"'` (an include, not `nft -f`). Fix:
  write the rules to the exact path the base unit's condition checks
  (`systemctl cat nftables.service` on the target to confirm) and drop
  the `ExecStart` dropin — the base unit already loads the rules at boot.
  If the unit uses `include` (not `nft -f`), omit `flush ruleset` from
  the rules file — the service flushes before including. Confirmed on
  `bow` (bare-metal, Flatcar 4593.2.4, issue #9): the first implementation
  used a dropin redirecting to `/etc/nftables.d/closed.conf`; the second
  wrote to `/etc/nftables.conf` (the path older Flatcar versions use) —
  both left the condition unmet and `nftables.service` was skipped on
  every boot with no error. The closed-posture firewall never applied.
- **A closed nftables posture must allow podman container traffic in
  BOTH the `forward` AND `input` chains.** Podman containers route
  outbound traffic through the `forward` chain (NAT'd by podman), not
  the `output` chain — so `forward policy drop` with no accept rules
  breaks all container networking (image pulls, tunnel connections,
  DNS). Additionally, container DNS queries to the podman bridge gateway
  arrive on the host's bridge interface → `input` chain, not `forward`
  — so `input policy drop` without a DNS exception causes `lookup: i/o
  timeout` on every hostname resolution from a container. **Match by
  subnet, not interface name** — the podman bridge interface name varies
  by version (`cni-podman0`, `podman0`, `podman1`, etc.); subnets are
  stable. Flutterina (Hetzner) has no nftables, so this only affects
  bare-metal.
- **"The" podman bridge subnet is not one subnet — the default bridge
  and every named network each get their own, from different pools.**
  The nftables fix above originally hardcoded a single subnet
  (`10.89.0.0/24`), discovered by inspecting `bow`'s routing table and
  assumed to be "the podman default bridge subnet." It wasn't: confirmed
  via `podman network inspect podman` that the actual **default** bridge
  (network name `podman`, interface `podman0`, used by any container with
  no explicit `Network=`) is hardcoded to **`10.88.0.0/16`**.
  `10.89.0.0/24` (interface `podman1`) belonged to `newt-net` — a *named*
  network, which draws from a separate default pool that starts at
  `10.89.0.0/24` and increments per network created
  (containers-common's `default_subnet_pools`). Because `newt` happened
  to be the network under test, the fix looked complete (newt's traffic
  passed) while silently leaving the default bridge uncovered. Confirmed
  broken on `bow` (issue #34, found while investigating #31):
  `restic-backup` runs on the default bridge with no `Network=` override,
  so every DNS query, SSH connection, and healthchecks.io ping from that
  container was dropped by the `input`/`forward` chains' default-drop
  policy on every single run, while `newt` worked fine the whole time.
  Fix: match a set covering both allocation ranges —
  `ip saddr { 10.88.0.0/16, 10.89.0.0/16 } udp dport 53 accept` (and the
  `forward` chain's `ip saddr { 10.88.0.0/16, 10.89.0.0/16 } accept`) —
  `10.88.0.0/16` for the default bridge, `10.89.0.0/16` (not just the one
  `/24` in use today) for every named network's auto-allocated block, so
  adding another named network later doesn't need another nftables edit.
  Any new component that creates its own named podman network on
  bare-metal should double check its subnet falls inside `10.89.0.0/16`
  (podman's default pool) before assuming this nftables rule already
  covers it — an explicit `subnet=` on a `.network` quadlet could still
  fall outside it.
  **Butane changes don't reach a running host** (see below) — this fix
  needs a hand-edit of `/etc/nftables/rules/main.nft` +
  `systemctl restart nftables` on any bare-metal box provisioned before
  this fix landed, not just a repo commit.
- **LVM setup-script idempotency must be per-stage, not one big guard.**
  The first `bare-metal.bu` LVM script guarded the entire body with `if
  vgdisplay vg_data; then echo "nothing to do"; exit 0; fi`. A previous
  partial run (VG created, then `lvcreate` failed or was interrupted)
  left `vg_data` present with **0 LVs** — and every subsequent re-run
  exited early at the guard, so `lv_data` was never created, no
  filesystem, no mount, no fstab entry. The `lvm-data.service` marker
  file (`/etc/lvm-data.applied`, touched by `ExecStartPost`) made it
  worse: once touched, the `ConditionPathExists=!/etc/lvm-data.applied`
  gate prevents the service from even *trying* to run again. Confirmed
  on `bow` (bare-metal, issue #9): `lvm-data.service` showed `active
  (exited)`, status=0/SUCCESS, log said "vg_data already present,
  nothing to do" — but `sudo lvs vg_data` returned nothing and
  `/var/lib/materia-data` didn't exist. Fix: the script now guards each
  stage independently (VG → LV → mkfs → fstab), so a partial run
  resumes from where it left off. To recover a box in this state without
  a re-provision: remove the marker (`sudo rm /etc/lvm-data.applied`),
  re-run the script (`sudo /opt/lvm/setup-data-vg.sh`), then `sudo
  systemctl restart lvm-data.service` (or just reboot). The script is
  safe to run repeatedly.
- **Newt container name resolution only works on named podman networks,
  not the default bridge.** When Newt runs on the default bridge
  (`Network=bridge` or no `Network=`), it sends container **IP addresses**
  to Pangolin — which are dynamic (change on restart), making resource
  targets fragile. On a named network (e.g. `newt-net` via a `.network`
  quadlet), Newt sends container **names** (hostnames), which are stable.
  This is why the `newt` component creates a `newt.network` resource and
  the container uses `Network=newt-net` — and why services that should be
  tunnel-reachable must also add `Network=newt-net` to their own
  `.container.gotmpl`. Confirmed via Pangolin docs: "Running in Network
  Mode 'bridge': IP addresses will be used; Running with defined network:
  Hostnames will be used." Do NOT use `Network=host` for Newt — it breaks
  container name discovery entirely and gives access to all host
  interfaces.
- **Newt provisioning keys are consumed once.** The `spk_...` key in the
  vault is exchanged for a unique `id` + `secret` on first boot, which
  Newt persists to `newt-config.volume`. On subsequent boots, Newt reads
  the persisted credentials and ignores the key. If the config volume is
  wiped (`podman volume rm`), Newt can't re-provision with the same key —
  create a new key in the Pangolin dashboard and update the vault. The
  key has a max usage count set at creation time; each host consumes one.
- **`DOCKER_ENFORCE_NETWORK_VALIDATION=true` is defense in depth, not a
  replacement for network segmentation.** Newt validates that a target
  container is on `newt-net` before proxying, and reports unreachable
  targets instead of proxying to the wrong container. But the primary
  isolation is the network itself — a container not on `newt-net` is
  invisible to Newt regardless of this flag. Keep both: the network for
  isolation, the flag for catching misconfigured resource targets.

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
data volume and a closed-inbound nftables posture (SSH allowed for remote
admin — no cloud console fallback on bare metal) — see
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
| `mise hz:podman-gateway` | Print a server's podman bridge gateway IP (for Pangolin local-site resource targets pointing at standalone containers like beszel-hub) |

`hz:pull-config`/`hz:push-config` operate on the named podman volumes
(`systemd-pangolin-config`, `systemd-letsencrypt`), not the materia data dir —
templated configs are re-rendered by materia and don't need backup. The
tarball layout mirrors the container's `/app/config` (letsencrypt as a
subdirectory), so backups made by the old pangolin-edge repo's tasks against
`/var/lib/pangolin/config` push straight into a materia host. `push-config`
works before the first `materia-update` run: it pre-creates the volumes with
the quadlet names and the quadlet units reuse them (`--ignore`).

### iPXE tasks (bare-metal delivery)

Bare-metal servers don't get Ignition via cloud `user_data` — they boot
from a USB stick with iPXE, which chain-loads a `boot.ipxe` script from
a temporary HTTP server on the workstation. The `ipxe:*` tasks handle
the USB firmware + HTTP serving. See `provisioning/BARE-METAL.md` for
the full runbook.

| Task | Description |
|---|---|
| `mise ipxe:download` | Download `ipxe.iso` to cache + print manual `dd` instructions |
| `mise ipxe:firmware` | Download `ipxe.iso` + `dd` to a USB stick (interactive `gum choose` pick) |
| `mise ipxe:serve` | Serve `boot.ipxe` + `materia.ign` (or `materia-debug.ign` with `--debug`) via foreground `podman run nginx:alpine` — requires `--server-name` |

`ipxe:serve` discovers the workstation's LAN IP, renders `boot.ipxe`
with that IP baked into `ignition.config.url`, and maps host `IPXE_PORT`
(default 8080) → container 80 (nginx listens on 80, not 8080). It resolves
`provisioning/servers/<name>/materia.ign`, falling back to
`materia-debug.ign` if the real one doesn't exist yet. Override the
Flatcar channel/version via `FLATCAR_CHANNEL`/`FLATCAR_VERSION` env vars.

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
| `mise hz:storagebox:install-key --box-name <n> --server-name <s>` | Generate ed25519 key, install via `install-ssh-key` (port 23), write private key straight into the vault |

Order per server: `create` → `keyscan` (commit `known_hosts`) →
`subaccount` → `install-key` → the printed `sftp://...` repository
attribute (`components.restic-backup.resticRepository`) and the SSH key
(`components.restic-backup.storageBoxSshKey`) are both written straight
into `attributes/<server>.yml` by `install-key` itself, via `sops --set`
— no manual `sops edit` step remains for either. A
multi-line private key copy-pasted by hand into an interactive editor is
exactly the kind of thing that picks up CRLF/whitespace corruption from
terminal reflow, producing a key that looks plausible (BEGIN/END markers
intact) but fails to load (`error in libcrypto`) — see BUG-003. Passwords
are printed once — store them in Proton Pass (both are resettable via
`hcloud storage-box [subaccount] reset-password`) — one item per box
(`storagebox-<box>`) with a `primary-password` field and a
`<server>-password` field per subaccount. Subaccounts have no
API-side SSH keys; `install-ssh-key` writes `<home>/.ssh/authorized_keys`
in both port-23 (OpenSSH) and port-22 (RFC4716) formats.

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
- **Minimus MariaDB uses `MARIADB_*` env, not `MYSQL_*`; data dir is
  `/var/lib/mysql`, not `/config`.** Upstream's grimmory compose used
  the linuxserver mariadb image (`lscr.io/linuxserver/mariadb`), which
  accepts `MYSQL_ROOT_PASSWORD`/`MYSQL_DATABASE`/`MYSQL_USER`/
  `MYSQL_PASSWORD` and stores data in `/config`. The minimus mariadb
  image (`reg.mini.dev/mariadb`) follows the **official** MariaDB
  convention: `MARIADB_ROOT_PASSWORD`/`MARIADB_USER`/`MARIADB_PASSWORD`/
  `MARIADB_DATABASE` env, data in `/var/lib/mysql`. The `MYSQL_*` env
  vars are **silently ignored** on minimus, leaving the DB
  uninitialized with no error (the app then fails with a connection
  refusal). Both are required translations when switching from the
  linuxserver image to minimus — flagged here so a future contributor
  copying from upstream's compose doesn't carry over the wrong names.
  The minimus registry is `reg.mini.dev` (auth realm `auth.mini.dev`,
  not Docker Hub / GHCR) — same host as the pinned traefik image.
- **Pangolin SSO auth is kept ON for grimmory (unlike beszel-agent
  #23).** Grimmory is a human-facing web UI accessed in a browser —
  authenticating through Pangolin's default Platform SSO before
  reaching the app adds a layer, then the user hits Grimmory's own
  setup wizard / login. Do NOT disable auth on the
  `grimmory.<baseDomain>` resource. This is the opposite of
  beszel-agent, where Pangolon's SSO redirect (302 to the login page)
  broke the headless WebSocket handshake — Grimmory's browser-driven
  UI completes that flow fine.
- **Audiobookshelf: standalone on `newt-net`, only audiobooks +
  podcasts, no ebook library.** Same standalone-container-on-`newt-net`
  pattern as `music`/`grimmory` (no pod — single container, no
  shared-namespace requirement). Deliberately omits upstream's `/books`
  volume from its [podman quadlet example](https://audiobookshelf.org/docs/documentation/install/podman)
  — `grimmory` already owns ebook/comic hosting on `bow`, so wiring a
  second ebook-scanning path would duplicate that content type across
  two components. `AudioBooks` is mounted **read-only** (`:ro,z`) since
  audiobookshelf shouldn't modify source audiobook files; `Podcasts` is
  mounted **read-write** (`:z`) since audiobookshelf downloads new
  episodes directly into that library — the same read-only/read-write
  split exists between navidrome's read-only `Music` mount and
  audiobookshelf's write-needing `Podcasts` mount, so don't copy one
  library's mount mode onto the other without checking whether the app
  writes back into it. `/config` and `/metadata` are named volumes (not
  bind mounts) for the same data-dir-drift reason as every other
  app-writable state directory in this repo (see the data-dir-drift
  gotcha above). Pangolin SSO is kept ON (same reasoning as grimmory,
  not beszel-agent — it's a browser-driven UI, not a headless
  WebSocket client).

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

