# Beszel

Read this guide when deploying the hub or agent, bootstrapping enrollment, or changing alerts and monitored paths.

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
- **Monitoring the monitor: beszel hub-down alerting is a Pangolin alert
  rule — and Pangolin email alerts go nowhere, because Pangolin has no
  SMTP server configured.** Beszel is itself the alerting system, so a
  silently-dead hub leaves the whole fleet blind. The original design
  (#24) was an *arbitrary* Pangolin
  [Health Check](https://docs.pangolin.net/manage/alerting/health-checks)
  on the hub's pocketbase `/api/health`, paired with an
  [Alert Rule](https://docs.pangolin.net/manage/alerting/alert-rules)
  (email and/or webhook), instead of a bespoke systemd timer +
  healthchecks.io ping. What is live (Pangolin API, 2026-10-23): the probe
  is the **target-linked** health check on the Beszel resource (flutterina
  site, `beszel-hub:8090`, path `/api/health`), and the alert rule
  "Beszel Down" (`health_check_unhealthy` on that check) was only created
  on 2026-10-23; before that the org had zero alert rules and hub-down
  alerted nobody. Its only action is an email to the admin user, and
  **that email is never delivered**: `config.yml.gotmpl` ships
  `email.smtp_host: ""`. Because the `email:` block exists, Pangolin still
  builds a nodemailer transport (`server/emails/index.ts`), which falls
  back to `localhost`, and `sendAlertEmail.ts` logs and **swallows** every
  per-recipient failure — the rule shows as enabled, nothing errors in
  the UI, and no mail arrives. Confirmed with a test alert
  (`POST /api/v1/org/<org>/test-alert-rule`,
  `{"eventType": "health_check_unhealthy", "userIds": ["<id>"]}`, session
  cookie + CSRF header as in the [Newt site-resource notes](tailscale-newt.md)): the API
  answered `success`, and no email was received. Until the rule gets a
  webhook action (Pangolin's alert rules support webhooks natively) or
  Pangolin gets real SMTP settings, hub-down is still unmonitored.
  Re-check delivery with the same test endpoint after any change, not by
  reading the rule's config. Agent-down alerts, by contrast, are
  handled *inside* beszel via its native Shoutrrr webhook notifications
  (hub UI, Settings > Notifications, stored in beszel's DB, not IaC). The
  split is deliberate: Pangolin covers hub-down (which beszel can't
  self-report), beszel's own webhooks cover agent-down (which Pangolin
  can't see).
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

- **A beszel system's `host` field is a live SSH fallback target, and a
  wildcard DNS record makes every host name resolve to the edge — so one
  system's record silently starts showing another's data.** Each system
  row in the hub stores `host:port` (default agent port `45876`) from the
  "add system" dialog; when an agent's WebSocket is not connected the hub
  falls back to SSH-polling that address. `*.kittenlily.net` is wildcarded
  onto flutterina, so `bow.kittenlily.net` resolves to **flutterina's**
  public IP (`getent hosts bow.kittenlily.net` == `getent hosts
  flutterina.kittenlily.net` == `getent hosts kittenlily.net`) and the
  hub polled flutterina's agent for the Bow record. Symptom (2026-09-21):
  Bow's dashboard entry showed flutterina's metrics — identical
  `system_stats` rows 2s apart, `m: 3.72` (flutterina's 4 GB VPS) where
  Bow had always reported `31.08`, and the Bow record's container list was
  the flutterina pangolin stack (`app`, `gerbil`, `traefik`,
  `pangolin-infra`, `newt`, `beszel-hub`) — while the Flutterina record
  had no containers at all. Fingerprints were NOT colliding (distinct
  per system in the `fingerprints` table, and flutterina's matched
  `podman exec beszel-agent /agent fingerprint`), which is what rules out
  the agent-identity explanation and points at address resolution. When
  debugging beszel data attribution, the hub's SQLite DB is the fastest
  ground truth: `tar` `data.db`/`-wal`/`-shm` out of
  `/var/lib/containers/storage/volumes/systemd-beszel-data/_data`, then
  compare `systems`, `fingerprints`, `containers` and `system_stats`
  (delete the copy afterwards — it holds user records). Grouping
  `system_stats` by `json_extract(stats,'$.m')` dates the exact moment a
  record's data source changed. Give each system a host address that
  actually reaches that machine and is not swallowed by the wildcard.
- **A containerized beszel-agent reports NO systemd services until the
  system D-Bus socket is mounted — and it fails silently.** The collector
  (`agent/systemd.go`) talks to `org.freedesktop.systemd1` over the system
  bus, but first runs `isSystemdAvailable()`, which stats
  `/run/systemd/system`, `/run/dbus/system_bus_socket` and
  `/var/run/dbus/system_bus_socket`. None exist in the scratch agent
  image, so the whole collector is skipped with a single
  `DEBUG Systemd not available` line (invisible at the default log level)
  — no error, no UI section, nothing in the hub's `systemd_services`
  table. A *binary* agent (e.g. a Home Assistant box) needs no such
  config, which is why one host can show services while every
  containerized one shows none. Fix:
  `Volume=/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro`
  (target path per beszel.dev/guide/systemd, also go-systemd's default bus
  address). **Never add `:z`/`:Z`** — relabelling the host's system bus
  socket affects every other consumer on the box. Needs systemd 243+
  (`ListUnitsByPatterns`); flutterina has 260, krytis-build 257. Verified
  A/B locally before deploy (without the mount: the debug line and no
  service data; with it: `Services:[97 …]` = [total, failed] in the stats
  payload) and live afterwards: 79 services, 0 failed for Flutterina.
  `SERVICE_PATTERNS` (comma-separated, `.service` appended automatically)
  narrows the default `*.service` if the list is too noisy.
  Caveat for any new host: a missing bind source is a hard failure
  (`Error: statfs …: no such file or directory`, exit 125 — same class as
  BUG-005), not a graceful skip, and `beszel-agent` is assigned to every
  host via `[Roles.base]` — so confirm the socket exists on a new box
  before it reconciles.

## Resource map

```text
  beszel-hub/                    # beszel monitoring hub (standalone, flutterina-only)
    MANIFEST.toml                # component manifest — Defaults, Services (no Secrets)
    beszel-hub.container.gotmpl  # standalone container, port 8090, routed via Pangolin through Newt
    beszel-data.volume           # named volume for /beszel_data (root-owned, no User=/Group=)
  beszel-agent/                  # beszel monitoring agent (role-assigned)
    MANIFEST.toml                # component manifest — Secrets = ["beszelToken"], Defaults, Services
    beszel-agent.container.gotmpl # Network=host, podman socket mount, connects to hub via public URL; optional per-host extra disk
```

For UID transitions on existing volumes, see [Podman and Quadlet](podman-quadlet.md). For restoring the SQLite database, see [Restic and database backups](restic-backup.md).
