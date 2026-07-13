# Implementation Plan — Newt tunnel client component

**issue:** new (follow-up to bare-metal provisioning #9 + beszel monitoring #20)
**risk:** P2 (adds a new component; no changes to existing edge/pangolin flow;
no production service affected until a newt component is assigned to a host)
**epic:** standalone

## Summary

Add a `newt` component — Pangolin's userspace WireGuard tunnel client — as a
materia-managed component. This lets any host in the fleet (bare-metal or
Hetzner) expose its container services through the Pangolin edge (flutterina)
via a zero-trust tunnel, without opening inbound firewall ports.

**Architecture decision: Option C — one Newt per host on a shared `newt-net`
podman network.** Services that should be tunnel-reachable join `newt-net`;
Newt reaches them by container name (hostname). No `PublishPort` needed on
those services. Services not on `newt-net` are invisible to the tunnel.

**Provisioning model: Pangolin provisioning keys.** Instead of pre-creating a
site in the Pangolin dashboard and copying `NEWT_ID` + `NEWT_SECRET` into the
vault, the component uses a single provisioning key per host. Newt exchanges
the key for its own `id` + `secret` on first boot, persisting them to a config
file in a named volume. This eliminates the manual "create site in dashboard →
copy credentials → sops --set" step — same pattern as the beszel-agent
bootstrap, but fully automated.

## How provisioning keys work (reference)

1. A provisioning key (`spk_...`) is created once in the Pangolin dashboard
   (Provisioning → Create Key). It has a max usage count + optional expiry.
2. Newt starts with `--provisioning-key spk_...` (or `NEWT_PROVISIONING_KEY`
   env var) instead of `--id` + `--secret`.
3. Newt connects to Pangolin, exchanges the key for a unique `id` + `secret`,
   and persists them to `--config-file` (default:
   `~/.config/newt-client/config.json`; we override to a named volume path).
4. On subsequent boots, Newt reads the persisted `id` + `secret` from the
   config file and ignores the provisioning key. The key is consumed (one
   use against the max count).
5. An optional `--provisioning-blueprint-file` applies a blueprint YAML once
   at provisioning time (imperative bootstrap — dashboard edits afterward are
   not overwritten). We use this to auto-create the site + initial resources
   on first boot.

Key: the provisioning key is NOT a secret in the same sense as `NEWT_SECRET`
— it's a one-use bootstrap token, not a long-term credential. But it should
still be stored in the vault (it's not committed to git).

## Files to create

### 1. `components/newt/MANIFEST.toml`

```toml
Secrets = ["newtProvisioningKey"]

[Defaults]

[[Services]]
Service = "newt.service"
RestartedBy = ["newt.container", "newt.network"]
```

- `newtProvisioningKey` — the `spk_...` provisioning key from Pangolin.
  Declared as a secret (podman secret, injected via `secretEnv`). One per host
  (in `attributes/<server>.yml` under `components.newt.newtProvisioningKey`).
  After first boot, Newt persists its own `id`/`secret` and the key is no
  longer needed — but keeping it in the vault allows re-provisioning (a new
  key would need to be issued if the config volume is wiped).

### 2. `components/newt/newt.network`

```ini
[Network]
NetworkName=newt-net
```

A podman named network. Newt + any tunnel-reachable service joins this
network. Container name resolution works on named networks (not the default
bridge), so resource targets in Pangolin use container names (e.g.
`beszel-hub:8090`), not IPs or published ports.

### 3. `components/newt/newt-config.volume`

```ini
[Volume]
VolumeName=newt-config
```

Named volume for Newt's persisted config file (`/var/newt/config.json`).
After the provisioning exchange, Newt writes its `id` + `secret` here. On
reboot, it reads from this file instead of re-provisioning. The volume
survives container restarts and image updates.

### 4. `components/newt/newt.container.gotmpl`

```ini
[Unit]
Description=Newt tunnel client (Pangolin site connector)
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=newt
Image=docker.io/fosrl/newt:latest@sha256:<pinned-digest>

# Join the newt-net network — container name resolution works here,
# so resource targets in Pangolin use container names (e.g. beszel-hub:8090).
# No PublishPort needed — Newt dials OUT to Pangolin via WebSocket.
Network=newt-net

# Persist the provisioning-exchanged id/secret across restarts.
# Newt writes config.json here after exchanging the provisioning key;
# on subsequent boots it reads from this file instead of re-provisioning.
Volume=newt-config.volume:/var/newt:z

# Docker socket for container discovery — lets Pangolin inspect containers
# on newt-net, and enables DOCKER_ENFORCE_NETWORK_VALIDATION.
Volume=/run/podman/podman.sock:/var/run/docker.sock:ro

# The provisioning key (spk_...) — consumed once on first boot, then Newt
# persists its own id/secret to the config volume. After that the key is
# unused (but kept in the vault for re-provisioning if the volume is wiped).
{{ secretEnv "newtProvisioningKey" "NEWT_PROVISIONING_KEY" }}

# Pangolin server endpoint — the edge node's public URL.
# Uses the global baseDomain (same as beszel-hub).
Environment=PANGOLIN_ENDPOINT=https://pangolin.{{ .baseDomain }}

# Site name — the server's hostname, so the site appears as "bow" in the
# Pangolin dashboard. Supports {{env.VARIABLE_NAME}} templating in Newt,
# but we pass it directly as an env var instead.
Environment=NEWT_NAME={{ m_facts "hostname" }}

# Config file path inside the container (on the named volume).
Environment=CONFIG_FILE=/var/newt/config.json

# Docker integration — container discovery via the podman socket.
Environment=DOCKER_SOCKET=unix:///var/run/docker.sock

# Enforce that resource targets must be on the same network as Newt
# (newt-net). This prevents Newt from proxying to containers on other
# networks — defense in depth beyond the network segmentation itself.
Environment=DOCKER_ENFORCE_NETWORK_VALIDATION=true

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**Notes:**
- `Network=newt-net` — NOT `Network=host`. Host mode breaks container name
  resolution and gives access to all host interfaces. Bridge + named network
  = container names work, and only newt-net containers are reachable.
- No `PublishPort` — Newt is an outbound-only WebSocket client. It dials to
  the Pangolin edge (flutterina) over the public internet; no inbound ports
  needed. This works behind the nftables closed-posture firewall (which allows
  all outbound).
- `DOCKER_SOCKET` points at `/var/run/docker.sock` inside the container —
  mapped to the host's podman socket. Podman's socket is Docker-compatible.
- `DOCKER_ENFORCE_NETWORK_VALIDATION=true` — Newt validates that target
  containers are on `newt-net` before proxying. Without this, a misconfigured
  resource target could reach containers on other networks.
- Image pin: use `@sha256:<digest>` once the image is pulled. Renovate covers
  `fosrl/newt` via the existing quadlet manager (matches `.container.gotmpl`).
- `m_facts "hostname"` — same macro the materia-update quadlet uses for
  per-host naming. The site name in Pangolin = the server's hostname.

### 5. `components/newt/blueprint.gotmpl` (optional — provisioning blueprint)

A blueprint applied once at provisioning time (`--provisioning-blueprint-file`)
to auto-create the site + initial resources on first boot. This is a data
resource (installed to the materia data dir, bind-mounted into the container).

```yaml
sites:
  {{ m_facts "hostname" }}:
    name: {{ m_facts "hostname" }}
    docker-socket-enabled: true
```

This creates the site in Pangolin with Docker socket discovery enabled. No
resources defined here yet — those are either added in the dashboard afterward
(provisioning-blueprint is imperative, not declarative), or via container
labels on the target services.

**Whether to include this file depends on a decision (see Open Questions
below).** If we use `--blueprint-file` (declarative) instead of
`--provisioning-blueprint-file` (imperative), the blueprint stays the source
of truth and dashboard edits get overwritten — which is more GitOps-y but
less flexible for per-host resource tuning.

## Files to modify

### `MANIFEST.toml` — assign newt to hosts

The `newt` component is NOT in `[Roles.base]` — not every host needs a tunnel
client (the edge node itself doesn't). It's assigned per-host:

```toml
[Hosts.bow]
Components = []
Roles = ["base"]
# Add newt to bow's components (alongside the base role's restic-backup + beszel-agent):
# Components = ["newt"]
```

Or via a new role if multiple hosts need it:

```toml
[Roles.tunneled]
Components = ["newt"]

[Hosts.bow]
Components = []
Roles = ["base", "tunneled"]
```

**Decision: per-host `Components = ["newt"]` for now** — only `bow` needs it
currently, and a role with one component is premature. If a second tunneled
host appears, extract the role then.

### `attributes/<server>.yml` — provisioning key

For each host that gets `newt`, add the provisioning key to its vault:

```yaml
components:
  newt:
    newtProvisioningKey: spk_...
```

The key is created in the Pangolin dashboard (Provisioning → Create Key).
Set max usage to the number of hosts + a small buffer, no expiry (or a long
one). Each host consumes one use on first boot.

### Existing services — add `Network=newt-net` to make them tunnel-reachable

Services that should be reachable through the Newt tunnel add
`Network=newt-net` to their `.container.gotmpl`. This is per-service, not
automatic — only services explicitly added to `newt-net` are exposed.

For `bow`'s `beszel-hub` (if one is deployed there — currently the hub is on
flutterina only):

```ini
# In beszel-hub.container.gotmpl, add:
Network=newt-net
# And remove:
PublishPort=8090:8090   # no longer needed — Newt reaches it by container name
```

For services in the `pangolin.pod` (on flutterina) — they already share a
network namespace and are the edge's own services; they don't join `newt-net`
(the edge doesn't tunnel to itself).

### `AGENTS.md` — document the newt component + architecture

Add to:
- Repo layout: `components/newt/` entry
- Architecture decisions: the `newt-net` shared network model + provisioning
  key flow
- Gotchas: the network-mode-matters-for-hostname-resolution trap, the
  provisioning-key-is-consumed-once behavior, the `DOCKER_ENFORCE_NETWORK_
  VALIDATION` defense

## Provisioning flow (end-to-end)

1. **Create a provisioning key in Pangolin** (dashboard → Provisioning → Create
   Key). Note the `spk_...` value.
2. **Add the key to the host's vault:**
   ```sh
   _key_json=$(jq -Rn --arg v "spk_..." '$v')
   sops --set '["components"]["newt"]["newtProvisioningKey"] '"$_key_json"'' attributes/bow.yml
   ```
3. **Add `newt` to the host's components in `MANIFEST.toml`:**
   ```toml
   [Hosts.bow]
   Components = ["newt"]
   Roles = ["base"]
   ```
4. **Commit + push.** The next `materia update` on the host installs the
   `newt.network`, `newt-config.volume`, and `newt.container` quadlets, creates
   the `newtProvisioningKey` podman secret, and starts the service.
5. **Newt first boot:** exchanges the provisioning key for `id` + `secret`,
   persists to `/var/newt/config.json` (on the named volume), creates the site
   in Pangolin (named after the hostname, e.g. "bow"), applies the provisioning
   blueprint (if included).
6. **Add resources** in the Pangolin dashboard (or via container labels):
   target = `container-name:port` (e.g. `beszel-hub:8090`), site = `bow`.

## Out of scope

- **Pangolin CLI / Integration API for blueprint application** — the CLI
  (`pangolin apply blueprint`) requires an API key and is a separate
  automation path. The provisioning-blueprint-file approach is simpler and
  doesn't need an API key.
- **Container label-based resource discovery** — supported by Newt's Docker
  socket integration, but requires labels on target containers. Future work
  if we want fully declarative resource definitions.
- **Native WireGuard mode** (`--native` / `USE_NATIVE_INTERFACE`) — userspace
  netstack is the default and works without `NET_ADMIN`. Native mode is faster
  but needs kernel module + capabilities. Not needed for the current fleet.
- **mTLS** — Newt supports mTLS with the Pangolin server. Not configured here;
  the WebSocket connection uses TLS via the Pangolin edge's Traefik.

## Open questions

1. **`--blueprint-file` (declarative) vs `--provisioning-blueprint-file`
   (imperative)?** Declarative = GitOps source of truth, dashboard edits
   overwritten. Imperative = bootstrap only, dashboard is the source of truth
   after first boot. Recommendation: **imperative** for now (matches the
   "provisioning key = bootstrap" model, and resources are easier to manage
   in the dashboard for a small fleet). Switch to declarative if we want
   blueprint YAML in the repo as the source of truth.

2. **Should `newt` be a role (`[Roles.tunneled]`) or per-host?** Per-host for
   now (only bow). Extract a role when a second tunneled host appears.

3. **Image pin:** need to pull `fosrl/newt:latest` and pin by digest. The
   image is not yet in the repo — first `materia update` on bow will pull it.
   Pin the digest after the first successful run (same pattern as
   restic-backup / beszel).

## Verification (once implemented)

1. `butane --strict` — not applicable (no .bu changes).
2. `mise clean` — no template errors.
3. On bow after `materia update`:
   - `sudo systemctl status newt.service` — active (running)
   - `sudo podman exec newt cat /var/newt/config.json` — has `id` + `secret`
     (provisioning exchange succeeded)
   - Pangolin dashboard → Sites → "bow" appears, status online
   - `sudo podman network inspect newt-net` — exists, newt container attached
   - Add a resource in the dashboard targeting `beszel-hub:8090` (if
     beszel-hub is on bow + newt-net) → accessible via the tunnel URL
4. `git status` — no unexpected files (no gitops/, argocd, etc.)

## Risks

- **Provisioning key consumed on first boot** — if the config volume is wiped
  (e.g. `podman volume rm`), Newt can't re-provision with the same key (it's
  already been used). Fix: create a new key in the dashboard and update the
  vault. The config volume is persistent and not materia-managed (same as
  other named volumes), so this shouldn't happen in normal operation.
- **Newt can't reach Pangolin** — if the edge node (flutterina) is down or the
  domain is misconfigured, Newt fails to connect. The service restarts
  (`Restart=always`), so it recovers automatically when the edge is back.
- **Container name resolution breaks if a service leaves newt-net** — if a
  container is removed from `newt-net` but a Pangolin resource still targets
  it by name, Newt can't reach it. `DOCKER_ENFORCE_NETWORK_VALIDATION=true`
  catches this — Newt reports the target as unreachable rather than proxying
  to the wrong container.
- **Podman socket security** — mounting the podman socket read-only into the
  newt container gives it read access to container metadata (names, IPs,
  labels, port mappings). It does NOT give write access (read-only mount).
  Newt uses this for discovery only. The socket is already mounted into
  beszel-agent (same pattern).
