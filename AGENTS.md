# Materia Podman Orchestration

> **Process rules** (Always Green, Discovered Defects, Conventional Commits,
> Agent Workflow Mandate) live in [CONVENTIONS.md](CONVENTIONS.md) — read it before any git
> operation.

## Goal

Manage Podman-hosted services with [Materia](https://primamateria.systems/). Materia is the single GitOps reconciler. It syncs the repo, templates resources, installs Quadlets and configs, manages Podman secrets, and restarts services.

## Where this sits

Pangolin, Gerbil, and Traefik run on the Hetzner edge node `flutterina`, the public entry point for the zero-trust gateway. The repo also manages standalone services on other hosts. Kubernetes is separate work using sysext-bakery, CAPI/Typhoon, and Argo/Flux, with KubeStellar on the hosting cluster. Clusters dial out via Newt and keep inbound traffic closed. KubeStellar and Pangolin sit above the node layer.

## Materia concepts and reconciliation

- The root [MANIFEST.toml](MANIFEST.toml) assigns hosts and roles to components. A component is a service or group of services under `components/`, along with its resources and its own manifest for defaults, services, secrets and restart dependencies.
- A resource is a component file. Quadlets (`.container`, `.network`, `.volume`, `.pod`, etc.) install to `/etc/containers/systemd/<component>/`. Data resources install to `/var/lib/materia/components/<component>/`. Materia renders Go templates and strips the `.gotmpl` suffix. Use `{{ m_dataDir "pangolin" }}` for the installed component data path. App-writable state belongs in named volumes.
- Attributes can be scoped to globals, hosts, roles, and components. `attributes/vault.yml` is the global vault, with optional `attributes/<host>.yml` and `attributes/<role>.yml`. SOPS encrypts the values with age. Ignition installs the private key at `/etc/materia/key.txt`, and `mise.toml` pins the toolchain. For normal vault edits use `env SOPS_AGE_KEY="$(fnox get SOPS_AGE_KEY)" sops edit attributes/vault.yml`. For multiline secrets use the file-based workflow in the [Materia guide](docs/gotchas/materia-behaviour.md).
- On `materia update`, Materia syncs into `/var/lib/materia/source`, selects the host's components, renders and installs the resources, updates declared secrets, and daemon-reloads if Quadlets changed. It restarts services for changed resources according to `RestartedBy` and component settings, then starts stopped services as configured. Check the live service after a failed plan or a migration.

## Locked architecture decisions

- **Shared Pangolin pod.** Pangolin, Gerbil, and Traefik share the `pangolin.pod` network namespace and reach each other over localhost. The pod publishes ports. Traefik must share the namespace to reach tunnel endpoint IPs on WireGuard interfaces created by Gerbil.
- **Materia owns the secret lifecycle.** Use top-level `Secrets = ["attr"]` in the component manifest and `secretEnv` or `secretMount` in templates. Keep the install and reconciliation path free of seed-secrets services, a hand-rolled reconciler, and webhooks.
- **Configs are templated data resources.** Use `.gotmpl` and attributes for domain and other settings, with individual read-only config bind mounts where appropriate. Materia provides the rendered files directly, avoiding deployment-time substitution and a separate Pangolin environment file.
- **Git pins images and plugin versions.** Pin image digests, with Renovate PRs replacing registry auto-updates. Plugin versions belong in manifest `[Defaults]` and flow into templates, so the Renovate regex updates the source pin.
- **Generic backups follow the base role.** `[Roles.base]` assigns `restic-backup` to hosts opting into `Roles = ["base"]`. The same job backs up the host's Materia data and Podman volumes. Restic is a timer-activated `Type=oneshot` with `Stopped = true` and `Oneshot = true` in the component manifest. Give the timer `Static = true` and `WantedBy=timers.target` and omit `[Install]` on the job.
- **Newt reaches apps on the named `newt-net` network.** A named Podman network provides DNS by container name, which the default bridge lacks. Join services that should be reachable to that network and keep unrelated services off it. Newt's outbound WebSocket connection works with closed inbound firewalls and needs no published port. Keep container target network validation enabled. See the guide for its scope.
- **Newt provisions once.** The provisioning key exchanges for the client ID and secret, which persist in a named volume. Newt uses the imperative `--provisioning-blueprint-file` for first boot and the dashboard manages the site afterward. Keep the key in the vault for the re-provisioning workflow.
- **Flutterina uses Newt for health checks.** The edge's standalone services, such as Beszel, get Pangolin health checks through Newt because local sites lack health checks, private resources, and socket scanning. Flutterina is currently the only `[Roles.tunneled]` host. Bow uses the Tailscale gateway and that component owns its `newt-net`.
- **Materia pulls changes.** The timer runs updates. For faster rollout use a shorter cadence or trigger `materia update` externally through authorized automation.

## Repo layout

- [MANIFEST.toml](MANIFEST.toml) assigns hosts and roles. `attributes/` holds SOPS vaults and `components/` holds deployable units and data.
- `images/` builds the restic-backup image and Go wrapper. `provisioning/` holds Butane templates, server and Storage Box definitions, the bare-metal runbook, and Bluefin pilot fixtures.
- `mise.toml` pins tools and `.mise/tasks/` holds render, provisioning, backup, and verification tasks. `fnox.toml` defines Proton Pass lookups, `.sops.yaml` defines vault recipients, and `renovate.json5` defines pin updates.
- `.github/workflows/` holds CI and preflight gates. `specs/` holds plans, bugs, and project state. [docs/gotchas/](docs/gotchas/README.md) holds operational guides.

Components under `components/`:

- `pangolin` — edge app, Gerbil, Traefik, shared pod, and ACME storage.
- `restic-backup` — host backup and retention job with an SSH Storage Box backend.
- `beszel-hub` — standalone monitoring hub on the edge, reached through Newt.
- `beszel-agent` — role-assigned host and container monitoring.
- `newt` — role-assigned outbound tunnel client and its provisioning blueprint.
- `tailscale` — role-assigned host Tailscale node in kernel mode.
- `tailscale-gateway` — bow's userspace node and container-name TCP forwarding.
- `music` — Navidrome server and Aonsoku client.
- `grimmory` — ebook, comic, and audiobook library with MariaDB.
- `audiobookshelf` — audiobook server. PinePods now handles podcasts.
- `jellyfin` — TV and film streaming with hardware transcoding.
- `mediamanager` — TV and film management with Postgres and a shared video bind for hardlinks.
- `pinepods` — podcast server and gPodder sync with Postgres and Valkey.
- `buildbarn` — BuildStream cache for krytis, reachable as the `bst-cache` Tailscale Service.
- `usb-drive` — LUKS2 USB hotplug, TPM2 auto-unlock, and mount.
- `silentsuite` — end-to-end encrypted calendar, contacts, and tasks sync with Postgres.
- `db-dump` — nightly logical database dumps on bow, backed up by restic.
- `sqlite-dump` — nightly consistent Pangolin and Beszel SQLite copies on flutterina.

## Multi-server identity

A server's name is its OS hostname, its key under `Hosts` in [MANIFEST.toml](MANIFEST.toml), its directory under `provisioning/servers/`, and its Hetzner Cloud name where applicable. The manifest lists current assignments. Server-scoped tasks take `--server-name` explicitly. Use `mise server:new` to scaffold, `mise ign` to render, and `mise hz:create` or the [bare-metal runbook](provisioning/BARE-METAL.md) to provision. See [Provisioning and Flatcar](docs/gotchas/provisioning-flatcar.md) for adopted hosts and the shared trust domain.

## Outage guardrails

- **Set `ExitPolicy=continue` on persistent pods.** Restarting Pangolin app also stops its dependents. Quadlet's default policy would drain the shared pod, remove its published ports, and block app restart. [Pangolin edge](docs/gotchas/pangolin-edge.md)
- **Gate every badger bump.** Require a green `badger-catalog` check and verify plugin loading in a local Traefik run before merging. A bad pin invalidates the routers and takes down the edge. [Pangolin edge](docs/gotchas/pangolin-edge.md)
- **Treat a single-component failure as a whole-host reconciliation failure.** Check attribute scopes, place `Secrets` before the first TOML table, create bind sources before rollout, and execute any required state migration on each host. Verify that the next reconciliation succeeds. [Materia behaviour](docs/gotchas/materia-behaviour.md) · [Bind-source prerequisites](docs/gotchas/provisioning-flatcar.md)
- **Recover missed restarts after a failed run.** Materia can install units before aborting and skip their restarts on the next pass because the files already match. Check the failed run's planned restarts, daemon-reload, restart the missed services, and verify their live state. [Materia behaviour](docs/gotchas/materia-behaviour.md)
- **Roll out Butane changes to existing hosts explicitly.** Ignition runs at first boot. A live Materia image bump requires `mise materia:sync-image --target <user@host>` and verification on each affected host. [Provisioning and Flatcar](docs/gotchas/provisioning-flatcar.md) · [Materia behaviour](docs/gotchas/materia-behaviour.md)
- **Verify secret rotations against live Podman.** A rotation can leave the old value even when the update log and timestamp say it changed. Check the stored value safely, recreate a stale secret through Materia, and restart the consumer. [Materia behaviour](docs/gotchas/materia-behaviour.md)
- **Preserve unit syntax.** Put Quadlet comments on their own lines. Quote the full `Environment="KEY=value with spaces"` assignment so systemd keeps the complete value. [Podman and Quadlet](docs/gotchas/podman-quadlet.md)
- **Use JSON-array `HealthCmd=` when arguments need quoting.** Bow's Podman 5.7.1 can drop a closing quote in string-form probes. With `Notify=healthy` the bad command can stall the unit and the entire reconciliation. Prefer an array invoking a mounted script for complex probes. [Podman and Quadlet](docs/gotchas/podman-quadlet.md)
- **Write multiline secrets from files.** Use `sops --set` with escaped file contents. Manual paste can corrupt private keys or JSON while leaving the result visually plausible. [Materia behaviour](docs/gotchas/materia-behaviour.md)
- **Fetch secrets with `fnox get` only.** Keep `env = false` so the shell and ordinary mise tasks do not receive secret exports automatically. [Materia behaviour](docs/gotchas/materia-behaviour.md)
- **Remove the temporary Traefik access log after the seven-day collection.** It was added to `components/pangolin/traefik/traefik_config.yml.gotmpl` on 2026-11-22 for the #179 Phase 4 E6 baseline.

## Development conventions

Follow [CONVENTIONS.md](CONVENTIONS.md) for the agent workflow, preflight, and discovered defects. Keep changes focused and use Conventional Commit subjects of at most 50 characters. Keep deployment domains, addresses, and secrets in encrypted vaults. Get permission before posting issues, PRs, or comments upstream. Record new findings in the relevant topic guide and add an outage guardrail here when a rule protects the entire host or edge.

## Topic guides

Open the relevant guide when needed. The [guide index](docs/gotchas/README.md) lists the same topics.

- [Pangolin edge](docs/gotchas/pangolin-edge.md). Read when working on the shared edge pod, Traefik, badger, HTTP/3, or Pangolin resource settings.
- [Materia behaviour](docs/gotchas/materia-behaviour.md). Read when changing manifests, templates, attributes, secrets, reconciliation, or release gates.
- [Podman and Quadlet](docs/gotchas/podman-quadlet.md). Read when writing units, health checks, environment values, mounts, or non-root containers.
- [Restic and database backups](docs/gotchas/restic-backup.md). Read when changing backups, restoring a database, provisioning a Storage Box, or evaluating Proton Drive.
- [Beszel](docs/gotchas/beszel.md). Read when deploying the hub or agent, bootstrapping enrollment, or changing alerts and monitored paths.
- [Tailscale and Newt](docs/gotchas/tailscale-newt.md). Read when changing tunnel clients, the gateway, container discovery, or tailnet routing.
- [Buildbarn](docs/gotchas/buildbarn.md). Read when changing cache auth, TLS, CAS sizing, or metrics.
- [Provisioning and Flatcar](docs/gotchas/provisioning-flatcar.md). Read when rendering Ignition, provisioning or adopting hosts, or changing nftables, LVM, USB, or sysupdate.
- [Media apps and SilentSuite](docs/gotchas/media-apps.md). Read when changing media apps, SilentSuite, DB sidecars, hardlinks, image pins, or SSO.
- [Sizing benchmarks](docs/gotchas/bench.md). Read when running or comparing bench tasks and interpreting their results.

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

