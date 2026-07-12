# Implementation Plan — Issue #20: Add beszel monitoring as a materia component

**issue:** https://github.com/kitten-lily/materia/issues/20
**risk:** P2 (adds a new monitoring component; no changes to existing
services; hub placement in the pangolin pod is the main architectural
decision)
**epic:** standalone

## Summary

Add [Beszel](https://beszel.dev/) — a lightweight hub-and-agent server
monitoring platform — as a materia component. The hub runs on flutterina
behind the existing Traefik reverse proxy (pangolin pod), and the agent
runs on every server via the `base` role (like `restic-backup`). Provides
CPU/memory/disk/network/temperature/container metrics and configurable
alerts for the fleet, without Prometheus/Grafana overhead (~23–50 MB RAM
for the hub).

## Architecture decisions (resolved)

### Hub placement: in the pangolin pod, behind Traefik

The hub joins `pangolin.pod` (shared network namespace) and listens on
`localhost:8090`. Traefik, already in the pod, reverse-proxies
`beszel.<baseDomain>` → `localhost:8090` with TLS via the existing
letsencrypt cert resolver + badger middleware. This gives automatic HTTPS
with no additional port publishing or cert management.

**Why not standalone:** a standalone hub would need its own published port
(8090) or its own Traefik routing config. Joining the pod is zero-config
TLS, consistent with how pangolin/gerbil/traefik already work.

### Agent → Hub connection: WebSocket (outbound-only)

The agent connects to the hub via WebSocket using `HUB_URL` + `TOKEN` +
`KEY` env vars. This is outbound-only from the agent — no inbound port
needed on agent hosts, which is critical for the closed-inbound nftables
posture on bare-metal servers. The SSH tunnel fallback (port 45876) is
not used.

### Component structure: single `beszel` component, two containers

One `components/beszel/` directory containing both the hub and agent
quadlets. The hub is assigned to flutterina directly (via `Hosts.flutterina
Components`), the agent is assigned to the `base` role (every server gets
it). Materia installs both quadlets on every host, but the hub
`Stopped = true` on non-edge hosts (the `RestartedBy`/service logic ensures
only the assigned host starts it). Actually — simpler: two separate
components (`beszel-hub` and `beszel-agent`) to avoid the "install but
don't start" complexity. The hub component is assigned to flutterina; the
agent component is in `base`.

**Revised: two components:**
- `components/beszel-hub/` — assigned to `Hosts.flutterina Components`
- `components/beszel-agent/` — assigned to `[Roles.base] Components`

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

The `HUB_URL` for agents is a global attribute: `https://beszel.<baseDomain>`
— stored in `attributes/vault.yml` globals as `beszelHubUrl`, templated into
the agent's `Environment=HUB_URL={{ .beszelHubUrl }}`.

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
After=app.service
Requires=app.service

[Container]
Pod=pangolin.pod
ContainerName=beszel-hub
Image=docker.io/henrygd/beszel:0.18.7@sha256:<digest>
Environment=APP_URL=https://beszel.{{ .baseDomain }}
Volume=beszel-data.volume:/beszel_data:z

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**`beszel-data.volume`:**
```ini
[Volume]
```

### 2. `components/beszel-agent/` (new)

**`MANIFEST.toml`:**
```toml
Secrets = ["beszelToken", "beszelKey"]

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

Note: `KEY` is a public key (not secret), so it's a regular attribute, not
a podman secret. `TOKEN` is secret → podman secret via `secretEnv`.

### 3. `attributes/vault.yml` — add global `beszelHubUrl`

```yaml
globals:
    beszelHubUrl: <encrypted>
```

Value: `https://beszel.<baseDomain>` (derived from the existing
`baseDomain` attribute — or hardcoded as the full URL since it's a
fixed value for this fleet).

### 4. `attributes/<server>.yml` — per-server agent secrets

For each server running the agent (starting with flutterina):
```yaml
components:
    beszel-agent:
        beszelToken: <encrypted>
        beszelKey: <encrypted>
```

These are generated by the hub's web UI when adding a system. They need to
be pasted into the vault via `sops edit attributes/<server>.yml` (or a
future mise task could automate this, similar to the `install-key` pattern
from BUG-003).

### 5. `MANIFEST.toml` — wire the components

```toml
[Hosts.flutterina]
Components = ["pangolin", "beszel-hub"]
Roles = ["base"]

[Roles.base]
Components = ["restic-backup", "beszel-agent"]
```

### 6. `components/pangolin/traefik/dynamic_config.yml.gotmpl` — add beszel router

Add a router for `beszel.<baseDomain>` pointing at `localhost:8090`:

```yaml
    beszel-router:
      rule: "Host(`beszel.{{ .baseDomain }}`)"
      service: beszel-service
      entryPoints: [websecure]
      middlewares: [badger]
      tls:
        certResolver: letsencrypt
```

And the service:
```yaml
    beszel-service:
      loadBalancer:
        servers:
          - url: "http://localhost:8090"
```

### 7. `AGENTS.md` — document the beszel component

Add to the repo layout, architecture decisions, and a gotcha about:
- The hub joining the pangolin pod (shared namespace, behind Traefik)
- The agent using `Network=host` (required for network-interface stats)
- The podman socket mount (read-only, already enabled by the .bu template)
- Per-server TOKEN/KEY secrets (generated by the hub UI, stored in SOPS)

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
5. Add beszel router + service to `dynamic_config.yml.gotmpl`.
6. Add a DNS record for `beszel.<domain>` (Cloudflare, via the existing
   `cfDnsApiToken` — or manually, since DNS isn't automated by materia).
7. `materia update` on flutterina → hub starts, accessible at
   `https://beszel.<domain>`.
8. Create admin user in the hub UI, add flutterina as a system → get
   TOKEN + KEY → `sops edit attributes/flutterina.yml` → paste.
9. `materia update` on flutterina → agent starts, connects to hub.
10. Verify in the hub UI: flutterina shows green, metrics flowing.
11. Update `AGENTS.md`.
12. Verify Renovate picks up both images.

## Risks

- **Hub in the pangolin pod**: if the hub crashes or misbehaves, it's in
  the same network namespace as pangolin/gerbil/traefik. A
  resource-consuming hub could affect the edge node's public ingress.
  Mitigation: set memory/CPU limits on the hub container
  (`Memory=`/`CPUQuota=` in the `[Service]` section).
- **Agent `Network=host`**: the agent sees all host network interfaces and
  can bind to any port. It only listens on 45876 (or the configured
  `LISTEN`), but `Network=host` is broader than necessary if we only need
  *read* access to network stats. Mitigation: the upstream docs recommend
  `Network=host` for accurate network stats; accept the tradeoff (the
  agent is a trusted, lightweight Go binary).
- **Per-server secret bootstrapping**: the TOKEN/KEY are generated by the
  hub UI *after* the hub is running, but the agent needs them *before* it
  can connect. This means a two-step deploy: start the hub → add system in
  UI → get secrets → put in vault → `materia update` → agent starts. Not
  fully automated (can't be, since the hub generates the secrets
  interactively). Mitigation: document the flow clearly; consider a
  future mise task that calls the hub's API to add a system + extract
  TOKEN/KEY programmatically.
- **`beszelKey` as a non-secret attribute**: `KEY` is a public SSH key
  (safe to expose), but it's stored in the SOPS vault alongside the
  secret `TOKEN`. This is fine (SOPS encrypts everything by default), but
  it means the key is in the encrypted vault, not in a plaintext
  attribute file. If we want it plaintext, it could go in
  `components.beszel-agent.beszelKey` in the host-specific vault — but
  SOPS encrypts all values, so it's ciphertext regardless. No action
  needed; just documenting the choice.
