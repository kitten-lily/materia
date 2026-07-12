# Implementation Plan — Issue #20: Add beszel monitoring as a materia component

**issue:** https://github.com/kitten-lily/materia/issues/20
**risk:** P2 (adds a new monitoring component; no changes to existing
services; hub routing through Pangolin's own resource system)
**epic:** standalone

## Summary

Add [Beszel](https://beszel.dev/) — a lightweight hub-and-agent server
monitoring platform — as a materia component. The hub runs as a standalone
container on flutterina (not in the pangolin pod), reachable through
Pangolin's own **local site + resource** routing — no manual Traefik
config or pod membership needed. The agent runs on every server via the
`base` role.

## Architecture decisions (resolved)

### Hub placement: standalone container, routed via Pangolin's local site

The hub runs as its own container (not in `pangolin.pod`) listening on
port 8090. Pangolin's [Local Site](https://docs.pangolin.net/manage/sites/understanding-sites)
feature exposes resources on the same host as the Pangolin server without
tunnels — the admin creates a local site in the Pangolin UI, then adds a
public resource (`beszel.<baseDomain>`) with a target pointing at the
hub's address.

**How the hub is reached from Pangolin:** since the hub is a separate
container (not in the pod's shared namespace), Pangolin's local site
target can't use `localhost:8090` (that would be the pangolin container's
own localhost). Instead, the target uses the host's IP or the podman
bridge gateway. Options:

1. **Podman bridge gateway IP** (`10.88.0.1` or `172.17.0.1`-equivalent
   for podman) — the hub publishes port 8090 on the host, and the local
   site target points at `<host-ip>:8090` or the bridge gateway. This is
   the approach recommended by Pangolin's
   [DNS & Networking docs](https://docs.pangolin.net/self-host/dns-and-networking)
   for services outside the compose/pod network.
2. **Publish port 8090 on the host** — `PublishPort=8090:8090` in the
   hub's `.container.gotmpl`, then the local site target is
   `localhost:8090` *from the host's perspective*. But since Pangolin
   runs inside a container (pod), it needs the host's IP, not localhost.

**Chosen approach:** `PublishPort=8090:8090` on the hub container. The
Pangolin local site resource target is `<flutterina-lan-ip>:8090` (or the
podman bridge gateway IP). The hub is behind Pangolin's Traefik + badger
middleware via the resource config, so it gets TLS + auth automatically —
no manual `dynamic_config.yml.gotmpl` changes needed. This keeps the hub
out of the pod (no shared namespace risk) and uses Pangolin's own routing
the way it was designed.

**Why not in the pod:** joining the pangolin pod puts the hub in the same
network namespace as pangolin/gerbil/traefik — a misbehaving or
resource-hungry hub could affect the edge node's public ingress. Keeping
it standalone isolates it, and Pangolin's local site feature is the
intended way to expose same-host services.

### Agent → Hub connection: WebSocket (outbound-only)

The agent connects to the hub via WebSocket using `HUB_URL` + `TOKEN` +
`KEY` env vars. `HUB_URL` is the *public* URL (`https://beszel.<baseDomain>`)
— the agent goes through Pangolin's public TLS endpoint, same as a browser
would. This is outbound-only from the agent — no inbound port needed on
agent hosts, compatible with the closed-inbound nftables posture on
bare-metal servers.

### Component structure: two components

- `components/beszel-hub/` — assigned to `Hosts.flutterina Components`
- `components/beszel-agent/` — assigned to `[Roles.base] Components`

Two separate components avoid the "install but don't start" complexity of
a single component with conditional hub/agent resources.

### Agent: Network=host, podman socket mount

The agent needs host network stats (`Network=host`) and read-only podman
socket access for container stats. The `hetzner.bu` template already
enables `podman.socket` at `/run/podman/podman.sock` on every host, so the
mount `Volume=/run/podman/podman.sock:/run/podman/podman.sock:ro` works
out of the box. For rootful podman (which is what materia uses), the
socket is at `/run/podman/podman.sock` — no user-namespace path mapping
needed.

### Secrets: per-server TOKEN + KEY in SOPS vault

The hub generates a `TOKEN` (WebSocket registration) and `KEY` (public SSH
key for agent auth) when adding a system in the web UI. These are
per-server secrets stored in `attributes/<server>.yml` under
`components.beszel-agent.beszelToken` and `components.beszel-agent.beszelKey`.
The hub's `APP_URL` is non-secret (derived from `baseDomain`).

The `HUB_URL` for agents is a global attribute:
`https://beszel.<baseDomain>` — stored in `attributes/vault.yml` globals
as `beszelHubUrl`, templated into the agent's
`Environment=HUB_URL={{ .beszelHubUrl }}`.

## Files to create / modify

### 1. `components/beszel-hub/` (new)

**`MANIFEST.toml`:**
```toml
[Defaults]

[[Services]]
Service = "beszel-hub.service"
RestartedBy = ["beszel-hub.container"]
```

**`beszel-hub.container.gotmpl`:**
```ini
[Unit]
Description=Beszel hub
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=beszel-hub
Image=docker.io/henrygd/beszel:0.18.7@sha256:<digest>
PublishPort=8090:8090
Environment=APP_URL=https://beszel.{{ .baseDomain }}
Volume=beszel-data.volume:/beszel_data:z

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

Note: no `Pod=` — standalone container, not in the pangolin pod. Port
8090 is published on the host so Pangolin's local site can reach it.

**`beszel-data.volume`:**
```ini
[Volume]
```

### 2. `components/beszel-agent/` (new)

**`MANIFEST.toml`:**
```toml
Secrets = ["beszelToken"]

[Defaults]

[[Services]]
Service = "beszel-agent.service"
RestartedBy = ["beszel-agent.container"]
```

**`beszel-agent.container.gotmpl`:**
```ini
[Unit]
Description=Beszel agent
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=beszel-agent
Image=docker.io/henrygd/beszel-agent:0.18.7@sha256:<digest>
Network=host
Volume=/run/podman/podman.sock:/run/podman/podman.sock:ro
{{ secretEnv "beszelToken" "TOKEN" }}
Environment=KEY={{ .beszelKey }}
Environment=HUB_URL={{ .beszelHubUrl }}
Environment=SYSTEM_NAME={{ m_facts "hostname" }}

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

Note: `KEY` is a public SSH key (not secret) — regular attribute, not a
podman secret. `TOKEN` is secret → podman secret via `secretEnv`. `HUB_URL`
points at the public Pangolin-routed URL, not the hub's internal port.

### 3. `attributes/vault.yml` — add global `beszelHubUrl`

```yaml
globals:
    beszelHubUrl: <encrypted>
```

Value: `https://beszel.<baseDomain>`.

### 4. `attributes/<server>.yml` — per-server agent secrets

For each server running the agent (starting with flutterina):
```yaml
components:
    beszel-agent:
        beszelToken: <encrypted>
        beszelKey: <encrypted>
```

Generated by the hub's web UI when adding a system. Pasted into the vault
via `sops edit attributes/<server>.yml`.

### 5. `MANIFEST.toml` — wire the components

```toml
[Hosts.flutterina]
Components = ["pangolin", "beszel-hub"]
Roles = ["base"]

[Roles.base]
Components = ["restic-backup", "beszel-agent"]
```

### 6. Pangolin UI configuration (manual, one-time)

After the hub is running:

1. Create a **Local Site** in the Pangolin UI (e.g. "edge-local").
2. Add a **public resource** `beszel.<baseDomain>` with target
   `<flutterina-ip>:8090` (or the podman bridge gateway IP), assigned to
   the local site. Pangolin's Traefik handles TLS + the badger middleware
   automatically — no `dynamic_config.yml.gotmpl` changes needed.
3. Add a DNS record for `beszel.<domain>` pointing at flutterina's public
   IP (Cloudflare, via the existing `cfDnsApiToken` or manually).
4. Create an admin user in the hub UI, add flutterina as a system → get
   TOKEN + KEY → `sops edit attributes/flutterina.yml` → paste.
5. `materia update` on flutterina → agent starts, connects to hub through
   the public URL.

### 7. `AGENTS.md` — document the beszel component

Add to the repo layout and a gotcha about:
- The hub as a standalone container (not in the pangolin pod), routed via
  Pangolin's local site + resource feature (not manual Traefik config)
- The agent using `Network=host` + podman socket mount
- Per-server TOKEN/KEY secrets (generated by the hub UI, stored in SOPS)
- `HUB_URL` pointing at the public Pangolin-routed URL (not the internal
  port)

### 8. `renovate.json5` — verify (likely no change)

The existing `quadlet` manager matches all `.container.gotmpl` files. Both
`henrygd/beszel` and `henrygd/beszel-agent` are on Docker Hub with semver
tags — Renovate should pick them up automatically. Verify after the first
Renovate run via the Dependency Dashboard.

## Implementation steps

1. Create `components/beszel-hub/` (MANIFEST.toml, container, volume) with
   a pinned digest for `0.18.7`.
2. Create `components/beszel-agent/` (MANIFEST.toml, container) with a
   pinned digest for `0.18.7`.
3. Add `beszelHubUrl` to `attributes/vault.yml` globals (user: `sops edit`).
4. Wire `MANIFEST.toml`: hub to flutterina, agent to `base` role.
5. `materia update` on flutterina → hub starts on port 8090.
6. In Pangolin UI: create local site, add `beszel.<domain>` resource with
   target `<flutterina-ip>:8090`.
7. Add DNS record for `beszel.<domain>`.
8. Create admin user in hub UI, add flutterina as a system → get
   TOKEN + KEY → `sops edit attributes/flutterina.yml` → paste.
9. `materia update` on flutterina → agent starts, connects to hub.
10. Verify in the hub UI: flutterina shows green, metrics flowing.
11. Update `AGENTS.md`.
12. Verify Renovate picks up both images.

## Risks

- **Port 8090 exposed on the host**: the hub publishes port 8090 on
  flutterina's public IP. Without the Pangolin resource config (which
  adds TLS + badger auth), the hub is directly accessible on 8090 without
  TLS. Mitigation: either (a) bind to localhost only
  (`PublishPort=127.0.0.1:8090:8090`) so only Pangolin's local site can
  reach it (the local site runs on the same host), or (b) rely on the
  firewall to block 8090 externally. Option (a) is cleaner — the hub
  doesn't need to be directly internet-accessible, only Pangolin needs to
  reach it.
- **Agent `Network=host`**: the agent sees all host network interfaces.
  Acceptable for a trusted monitoring agent (upstream recommends this for
  accurate stats).
- **Per-server secret bootstrapping**: TOKEN/KEY are generated by the hub
  UI after the hub is running, but the agent needs them before connecting.
  Two-step deploy: start hub → add system in UI → get secrets → vault →
  `materia update` → agent starts. Not fully automatable (hub generates
  secrets interactively). Document clearly.
- **Local site target address**: Pangolin's local site needs to reach the
  hub. If the hub binds to `127.0.0.1:8090` (localhost only), the
  Pangolin container (in the pod) can't reach `localhost:8090` (that's
  the pod's localhost, not the host's). Need to use the host's IP or the
  podman bridge gateway. This is the same issue documented in
  [pangolin issue #456](https://github.com/fosrl/pangolin/issues/456).
  Mitigation: use the podman bridge gateway IP (e.g. `10.88.0.1:8090` for
  podman's default bridge) as the local site target, and bind the hub to
  `0.0.0.0:8090` (or `PublishPort=8090:8090` without a localhost bind).
  Alternatively, join a shared podman network with the pangolin pod —
  but that's a lighter-touch version of the pod approach. **This needs
  testing** during implementation to confirm which address works.
