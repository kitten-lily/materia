# Implementation Plan — Add `chatto` component (flutterina)

**issue:** https://github.com/kitten-lily/materia/issues/44
**risk:** P2/P1 boundary (adds a new component on `flutterina` exposed
via existing Newt tunnel + `newt-net`, same pattern as `beszel-hub` —
but, per user direction, LiveKit's three media ports are exposed as
Pangolin raw TCP/UDP resources rather than direct container
`PublishPort`, which means editing the shared `pangolin` component's
`pangolin.pod` and `traefik_config.yml.gotmpl` — a pod-file change that
restarts the whole pod, affecting every other tunneled/proxied resource
on `flutterina`, not just `chatto`)
**epic:** standalone

## Summary

Add a `chatto` component running [Chatto](https://chatto.run) (self-hosted
chat) on `flutterina`, replacing the reference stack's bundled Caddy with
our existing Pangolin/Traefik edge. Three containers: `chatto` (app),
`nats` (JetStream persistent store), `livekit` (voice/video calls).
Reference: [Chatto Docker Compose docs](https://docs.chatto.run/guides/deployment/docker-compose/).

## Architecture decisions

### Component structure: three standalone containers, no pod

None of the three containers need a shared network namespace — they
reach each other by **container name** on `newt-net`
(`nats:4222`, `livekit:7880`), the same pattern as `grimmory`/`music`
(app + sidecar, no pod). This differs from `pangolin.pod`, whose pod
exists specifically so Traefik can reach Gerbil's CGNAT tunnel IPs —
that requirement doesn't apply here.

### Reverse proxy: existing Pangolin/Traefik replaces Caddy entirely

Per the docs' "Use Your Existing Reverse Proxy" section, Chatto only
needs two HTTP reverse-proxy routes:

- Chatto HTTPS hostname → `chatto:4000` (web app, APIs, realtime, LiveKit
  webhooks)
- LiveKit secure WebSocket hostname → `livekit:7880` (API + WS signaling)

Both containers join `newt-net`; Newt (already running on `flutterina`
via `[Roles.tunneled]`, originally added for beszel-hub health checks)
reaches them by container name, same as every other tunneled service in
this repo. Two Pangolin resources configured at deploy time in the
dashboard (no `dynamic_config.yml.gotmpl` change needed — this is the
established newt-net pattern, not the pod/local-site pattern):

- `chat.{{ .baseDomain }}` → `chatto:4000`
- `livekit.{{ .baseDomain }}` → `livekit:7880`

The `caddy` service, `Caddyfile`, and `caddy_data`/`caddy_config` volumes
from the reference compose are dropped entirely — Pangolin's Traefik
already terminates TLS and handles WebSocket upgrades for every other
component in this repo.

### LiveKit media ports: Pangolin raw TCP/UDP resources through Gerbil, not direct PublishPort

WebRTC media does not go through a normal HTTP reverse proxy (the docs
call this out explicitly — "Keep LiveKit's TCP and UDP `ports` entries").
The real `compose.yml` in the Chatto repo (not the older docs page,
which describes a wider historical UDP range) publishes exactly three
ports directly from the LiveKit container:

- `7881/tcp` — WebRTC media fallback when UDP is unavailable
- `7882/udp` — direct WebRTC media
- `3478/udp` — embedded TURN/STUN relay

**Revised per user direction:** instead of `PublishPort=` on
`livekit.container.gotmpl` (which would bind these ports directly on
the `livekit` container, bypassing Pangolin/Gerbil entirely), use
Pangolin's [raw TCP/UDP resources](https://docs.pangolin.net/manage/resources/public/raw-resources)
feature — already enabled in this repo (`flags.allow_raw_resources: true`
in `components/pangolin/config/config.yml.gotmpl`). Confirmed via the
docs: "Pangolin supports raw TCP and UDP traffic because Newt can pass
anything through the tunnel" — a raw TCP/UDP resource binds a port on
the **Pangolin server host** (i.e. `flutterina`, via Gerbil/Traefik,
same as every HTTP resource) and forwards through the site connector to
a target, exactly like an HTTP resource's target — so `livekit` stays a
plain `newt-net` container with **no `PublishPort` of its own**, fully
consistent with every other tunneled service in this repo (beszel-hub's
`PublishPort=8090:8090` is the one exception already flagged as a
legacy safety net in `AGENTS.md`, not a pattern to repeat here).

This moves the port exposure into the **`pangolin` component itself**
(not `chatto`) — confirmed against Pangolin's own self-hosted setup
docs, which require three coordinated changes for each proxied raw
resource, none of which touch the backend service's own container:

1. **`pangolin.pod`** — add `PublishPort=` for each port. This repo
   already publishes ports at the **pod** level (not per-container —
   see the pod's existing `PublishPort=80:80/tcp` etc.), which lines up
   with the docs' "Configure Docker: add port mappings to `gerbil:
   ports:`" step (Gerbil owns the network namespace Traefik shares, and
   in this repo's pod that's equivalent to a pod-level `PublishPort=`):
   ```ini
   PublishPort=7881:7881/tcp
   PublishPort=7882:7882/udp
   PublishPort=3478:3478/udp
   ```
2. **`components/pangolin/traefik/traefik_config.yml.gotmpl`** — add
   `entryPoints`, named `protocol-port` (Pangolin's docs call this
   naming **required** for its dynamic configuration to wire the
   resource to the entry point):
   ```yaml
   entryPoints:
     # ...existing web/websecure...
     tcp-7881:
       address: ":7881/tcp"
     udp-7882:
       address: ":7882/udp"
     udp-3478:
       address: ":3478/udp"
   ```
3. **Pangolin dashboard** — create three "Raw TCP/UDP resource" entries
   (mapped ports 7881/tcp, 7882/udp, 3478/udp), each targeting
   `livekit:7881`/`livekit:7882`/`livekit:3478` respectively (same
   `newt-net` container-name target addressing as every HTTP resource in
   this repo — the docs confirm raw resources use the same
   [targets](https://docs.pangolin.net/manage/resources/public/targets)
   mechanism as HTTP/HTTPS resources).

**Blast radius note:** unlike every other component in this plan, steps
1–2 modify the shared `pangolin` component, not a new isolated one —
`pangolin.pod`'s `PublishPort=` list changing means the pod restarts
(pod only restarts on `.pod` file changes, per the existing pod-restart-
safety gotcha; individual container restarts don't drain it, but a pod
file change does cycle the whole pod). Plan this as a deliberate,
visible edit to `pangolin.pod`/`traefik_config.yml.gotmpl` alongside the
new `chatto` component, not an incidental side effect.

Raw TCP/UDP resources are explicitly **unauthenticated at the Pangolin
layer** ("they do not enforce Pangolin authentication or access
rules") — expected and fine here, since LiveKit's own media path has no
HTTP-level auth model to hook into anyway (WebRTC/TURN auth happens via
LiveKit's own token/ICE-credential mechanism, independent of Pangolin).

`flutterina` is a Hetzner Cloud VPS with no nftables (only bare-metal
hosts have the closed-posture firewall in this repo), so no repo-side
firewall change is needed, but the **Hetzner Cloud firewall** (if one is
attached to the server) still needs these three ports opened — same as
it already needs for 80/443/51820/21820 — a manual/Hetzner-console step,
not templated by this repo today (flagged as an open question below).

### NATS: external container, embedded mode disabled

Matches the docs' recommended production topology
(`CHATTO_NATS_EMBEDDED_ENABLED=false`, `CHATTO_NATS_CLIENT_URL=nats://nats:4222`)
— decouples Chatto's process lifecycle from its data, same reasoning the
docs give for not using the standalone-binary's embedded NATS. `nats-data.volume`
holds all persistent chat data (JetStream streams, KV stores, and by
default file attachments/media too — S3 offload is a documented future
option, out of scope here). Root-owned (official `nats:latest` image runs
as root) — same reasoning as `beszel-data.volume`.

### Secrets vs. plain attributes

**Secrets** (`Secrets = [...]` in the component manifest, injected via
`secretEnv` into the `chatto` container):

- `natsToken` — shared between `nats`'s `--auth=` flag and Chatto's
  `CHATTO_NATS_CLIENT_TOKEN`. **Same value used two ways**: the `nats`
  container needs it as a command-line arg (`--auth=${NATS_TOKEN}`), not
  an env var Podman secret can populate directly — so `nats.container.gotmpl`
  interpolates it directly into `Exec=` via `{{ .natsToken }}` (plain
  attribute read, not `secretEnv` — quadlet's `Exec=`/`command:` has no
  secret-injection mechanism), while `chatto.container.gotmpl` gets it
  via `{{ secretEnv "natsToken" "CHATTO_NATS_CLIENT_TOKEN" }}`. Being
  in `Secrets` still makes the plain `{{ .natsToken }}` template value
  available (component-scoped attributes are readable in any template of
  that component regardless of the `Secrets` list — the list only
  controls *additional* podman-secret creation), so no attribute
  duplication is needed, but the *nats* container's copy of this value
  ends up in `podman inspect`'s command-line output (not secret-hidden)
  — a real exposure gap, worth flagging to the user rather than silently
  treating it as fully secret.
- `chattoCookieSigningSecret`
- `chattoCookieEncryptionSecret`
- `chattoCoreSecretKey`
- `chattoCoreAssetsSigningSecret`
- `chattoLivekitApiSecret` — **also** needed as plaintext inside
  `livekit.yaml`'s `keys:` map (LiveKit reads its API key/secret pairs
  from its mounted config file, not env/podman secrets — no
  `secretMount`/`secretEnv` equivalent exists for LiveKit). So this
  value is used two ways too: `{{ secretEnv "chattoLivekitApiSecret" "CHATTO_LIVEKIT_API_SECRET" }}`
  on the `chatto` container, and `{{ .chattoLivekitApiSecret }}`
  interpolated directly into `livekit.yaml.gotmpl` (a data resource,
  installed to the component data dir with normal host filesystem
  permissions — not podman-secret-protected). Same class of gap as
  `natsToken` above: LiveKit's config-file requirement means this secret
  can't be fully podman-secret-shielded end to end. Worth a comment in
  the file and in this plan; not a blocker (materia's data dir is
  root-only on the host by default) but a real deviation from the
  `secretEnv`-everywhere pattern the rest of the repo uses.
- `chattoSmtpPassword` (only if the SMTP server requires auth — see open
  questions)

**Plain attributes** (global or component-scoped, not secret):

- `chattoOwnersEmails` — comma-separated list, becomes the initial owner
  account(s)
- `chattoLivekitApiKey` — paired identifier for the secret above, not
  itself secret (same "identifier vs. secret" split as `beszelToken`/
  `beszelKey`)
- SMTP host/port/tls-mode/username/from — non-secret connection details
- `baseDomain` — already a global, reused for `chat.{{ .baseDomain }}`,
  `livekit.{{ .baseDomain }}`, `CHATTO_WEBSERVER_URL`, and the LiveKit
  webhook URL

### Push notifications: omitted from initial scope

`CHATTO_PUSH_*` (VAPID keys) are optional per the docs and add another
secret + manual keypair generation step. Left out of the first pass;
straightforward to add later (one more `Secrets` entry + env lines) if
wanted.

### Images: pin by digest once resolved (not yet done — planning phase)

`ghcr.io/chattocorp/chatto:latest`, `nats:latest`, and
`livekit/livekit-server:latest` are all unpinned `:latest` in the
reference compose. Per this repo's Renovate/pinned-digest convention,
each needs `skopeo inspect` to resolve a real version tag + digest
before the component ships (`nats` and `livekit-server` publish real
version tags upstream, unlike `latest`-only images like `aonsoku`).
Deferred to implementation.

## Files to create (implementation phase, not yet written)

### `components/chatto/MANIFEST.toml`

```toml
Secrets = [
  "natsToken",
  "chattoCookieSigningSecret",
  "chattoCookieEncryptionSecret",
  "chattoCoreSecretKey",
  "chattoCoreAssetsSigningSecret",
  "chattoLivekitApiSecret",
  "chattoSmtpPassword",
]

[Defaults]

[[Services]]
Service = "nats.service"
RestartedBy = ["nats.container"]

[[Services]]
Service = "livekit.service"
RestartedBy = ["livekit.container"]

[[Services]]
Service = "chatto.service"
RestartedBy = ["chatto.container"]
```

### `components/chatto/nats-data.volume`

Named volume for `/data` (JetStream store). Root-owned — official
`nats` image runs as root.

### `components/chatto/nats.container.gotmpl`

- `Network=newt-net` (not strictly needed for tunnel exposure — NATS
  isn't tunneled — but must share a network with `chatto` for
  name resolution; `newt-net` is the existing shared network on
  `flutterina`, reused rather than creating a second named network for
  just these three containers)
- `Exec=--jetstream --store_dir=/data --auth={{ .natsToken }}`
- `Volume=nats-data.volume:/data:z`
- `HealthCmd=nats-server --help` (matches reference compose's healthcheck)
- No `PublishPort` — NATS must never be publicly reachable (docs: "do
  not expose NATS port 4222 publicly")

### `components/chatto/livekit.yaml.gotmpl`

Templated data resource, installed to
`{{ m_dataDir "chatto" }}/livekit.yaml`, bind-mounted read-only into the
`livekit` container. Based on the real `livekit.yaml` from the Chatto
repo (single UDP media port, not a wide range):

```yaml
port: 7880
rtc:
  tcp_port: 7881
  udp_port: 7882
  use_external_ip: true

turn:
  enabled: true
  udp_port: 3478

keys:
  {{ .chattoLivekitApiKey }}: {{ .chattoLivekitApiSecret }}

webhook:
  urls:
    - https://chat.{{ .baseDomain }}/webhooks/livekit
  api_key: {{ .chattoLivekitApiKey }}

logging:
  level: info
```

### `components/chatto/livekit.container.gotmpl`

- `Network=newt-net`
- `Exec=--config /etc/livekit.yaml`
- `Volume={{ m_dataDir "chatto" }}/livekit.yaml:/etc/livekit.yaml:ro,z`
- **No `PublishPort` at all** — all four ports (7880 signaling, 7881/tcp,
  7882/udp, 3478/udp) are reached exclusively via `newt-net` container
  name (`livekit:<port>`), same as every other tunneled service. Public
  exposure for the three media ports is handled entirely by the
  `pangolin` component's raw TCP/UDP resources (see the architecture
  decision above) — not by this container.
- `HealthCmd=wget -q --spider http://localhost:7880`

### `components/pangolin/pangolin.pod` (modify existing)

Add to the existing `[Pod]` block, alongside `PublishPort=80:80/tcp` etc.:

```ini
PublishPort=7881:7881/tcp
PublishPort=7882:7882/udp
PublishPort=3478:3478/udp
```

### `components/pangolin/traefik/traefik_config.yml.gotmpl` (modify existing)

Add to the existing `entryPoints:` block (naming is `protocol-port`,
required by Pangolin's dynamic config wiring):

```yaml
  tcp-7881:
    address: ":7881/tcp"
  udp-7882:
    address: ":7882/udp"
  udp-3478:
    address: ":3478/udp"
```

### `components/chatto/chatto.container.gotmpl`

- `Network=newt-net`
- `Requires=nats.service` / `After=nats.service`,
  `Requires=livekit.service` / `After=livekit.service` (mirrors the
  reference compose's `depends_on: condition: service_healthy` — quadlet
  ordering only, same caveat as `grimmory.container.gotmpl`'s comment
  about `Requires=`/`After=` being start-order, not readiness)
- `Environment=CHATTO_NATS_EMBEDDED_ENABLED=false`
- `Environment=CHATTO_NATS_CLIENT_URL=nats://nats:4222`
- `Environment=CHATTO_NATS_CLIENT_AUTH_METHOD=token`
- `{{ secretEnv "natsToken" "CHATTO_NATS_CLIENT_TOKEN" }}`
- `Environment=CHATTO_WEBSERVER_URL=https://chat.{{ .baseDomain }}`
- `Environment=CHATTO_WEBSERVER_PORT=4000`
- `{{ secretEnv "chattoCookieSigningSecret" "CHATTO_WEBSERVER_COOKIE_SIGNING_SECRET" }}`
- `{{ secretEnv "chattoCookieEncryptionSecret" "CHATTO_WEBSERVER_COOKIE_ENCRYPTION_SECRET" }}`
- `{{ secretEnv "chattoCoreSecretKey" "CHATTO_CORE_SECRET_KEY" }}`
- `{{ secretEnv "chattoCoreAssetsSigningSecret" "CHATTO_CORE_ASSETS_SIGNING_SECRET" }}`
- `Environment="CHATTO_OWNERS_EMAILS={{ .chattoOwnersEmails }}"` (quoted
  — comma-separated list is one value, but quoting defensively per the
  `Environment=` space-splitting gotcha, in case of a typo with spaces
  after commas)
- `Environment=CHATTO_LIVEKIT_ENABLED=true`
- `Environment=CHATTO_LIVEKIT_URL=wss://livekit.{{ .baseDomain }}`
- `Environment=CHATTO_LIVEKIT_API_KEY={{ .chattoLivekitApiKey }}`
- `{{ secretEnv "chattoLivekitApiSecret" "CHATTO_LIVEKIT_API_SECRET" }}`
- `Environment=CHATTO_SMTP_ENABLED=true`
- `Environment=CHATTO_SMTP_HOST={{ .chattoSmtpHost }}`
- `Environment=CHATTO_SMTP_PORT={{ .chattoSmtpPort }}`
- `Environment=CHATTO_SMTP_TLS={{ .chattoSmtpTls }}`
- `Environment=CHATTO_SMTP_USERNAME={{ .chattoSmtpUsername }}`
- `{{ secretEnv "chattoSmtpPassword" "CHATTO_SMTP_PASSWORD" }}`
- `Environment=CHATTO_SMTP_FROM={{ .chattoSmtpFrom }}`
- `Environment=CHATTO_LOG_LEVEL=info`
- `Environment=CHATTO_LOG_FORMAT=json`
- No `PublishPort` — reached only via `newt-net` for the
  `chat.{{ .baseDomain }}` resource
- No data volume — Chatto is stateless; all persistent data lives in
  NATS (per the docs' "Why a Separate NATS Server?" section)

### `MANIFEST.toml`

```toml
[Hosts.flutterina]
Components = ["pangolin", "beszel-hub", "chatto"]
Roles = ["base", "tunneled"]
```

### `attributes/vault.yml` (or `attributes/flutterina.yml`)

New `components.chatto.*` keys for every secret + attribute listed above.
Given `chatto` is single-host (flutterina-only, like `beszel-hub`), these
can live under `attributes/flutterina.yml` instead of the global vault —
matching the "host-specific secrets" convention already documented for
per-server attribute files. `baseDomain` itself stays a global (already
shared by every component that needs it).

## Deploy-time steps (dashboard/manual, not IaC)

1. Create two Pangolin **HTTP** resources pointing at `newt-net`
   container names: `chat.{{ baseDomain }}` → `chatto:4000`,
   `livekit.{{ baseDomain }}` → `livekit:7880`. Keep Pangolin SSO **ON**
   for `chat.*` (browser-driven UI, same reasoning as
   `grimmory`/`audiobookshelf`/`jellyfin`) but it likely needs to be
   **OFF** for `livekit.*` — LiveKit's own WS signaling handshake is a
   headless client connection from the browser's JS, not a full-page
   navigation, and Chatto's LiveKit webhook calls
   `chat.{{ baseDomain }}/webhooks/livekit` server-to-server. This needs
   the same live verification `beszel-agent` needed (#23) before
   considering it closed — flagging as an explicit open question, not an
   assumption to bake into the plan as fact.
2. Create three Pangolin **Raw TCP/UDP** resources (mapped ports
   7881/tcp, 7882/udp, 3478/udp), each targeting `livekit` on the same
   port over `newt-net`. Raw resources are unauthenticated at the
   Pangolin layer by design (see architecture decision above) — nothing
   to configure there beyond the target.
3. Open Hetzner Cloud firewall (if attached to `flutterina`) for
   `7881/tcp`, `7882/udp`, `3478/udp`, in addition to the existing
   80/443/51820/21820.
4. Generate all `chattoCookie*`/`chattoCore*`/`chattoLivekitApiSecret`
   values with `openssl rand -hex 32` (per the docs' own generation
   instructions) and `sops --set` them into
   `attributes/flutterina.yml`, same non-interactive-injection pattern
   used for the storage-box SSH key (BUG-003 — no manual paste into
   `sops edit`).

## Open questions for the user

1. **Which domain(s)?** Plan assumes `chat.{{ baseDomain }}` +
   `livekit.{{ baseDomain }}` (reusing the existing global `baseDomain`,
   consistent with every other component). Confirm, or provide different
   subdomains.
2. **SMTP provider** — direct email/password registration needs SMTP
   creds. Which provider, and does it require STARTTLS:587 or
   implicit-TLS:465?
3. **Owner email(s)** — which address(es) go in `CHATTO_OWNERS_EMAILS`?
4. **Voice/video calls: keep or drop?** LiveKit is the most operationally
   heavy piece (3 extra public ports + Hetzner firewall change). If calls
   aren't needed yet, the docs' "Disabling Voice and Video Calls" section
   removes `livekit.container.gotmpl`, `livekit.yaml.gotmpl`, and all
   `CHATTO_LIVEKIT_*`/media-port items above — meaningfully smaller
   component (two containers, no extra public ports). Worth deciding
   before implementation, not after.
