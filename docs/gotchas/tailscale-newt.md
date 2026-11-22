# Tailscale and Newt

Read this guide when changing tunnel clients, the gateway, container discovery, or tailnet routing.

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
  of via local-site resources (Pangolin's docs: local sites support no
  health checking at all, nor private resources or Docker socket
  scanning). Flutterina is the only current `[Roles.tunneled]` host. Bow uses
  Tailscale for transport instead; its gateway component owns the still-shared
  `newt-net` network.

- **Newt is userspace WireGuard** — unprivileged, no kernel module. Gerbil
  (server side, VPS) needs NET_ADMIN/SYS_MODULE, may need `PodmanArgs=--privileged`
  if WireGuard can't initialise on the kernel.

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
- **A Pangolin site resource's `destination` is resolved *inside the newt
  container*, so the host's own hostname does not work — and the failure
  looks like an SSH/policy problem, not a DNS one.** A `mode: "host"`
  site resource pointing at a service on the newt host itself (rather
  than at a container on `newt-net`) must use an address the container
  can resolve and route to: the host's LAN IP, the `newt-net` gateway
  (`10.89.0.1` with podman's default named-network pool), or
  `host.containers.internal` (podman writes it into the container's
  `/etc/hosts`, pointing at that gateway). All three were confirmed to
  reach a host-side `sshd` from a throwaway container on `newt-net`;
  `127.0.0.1`/`localhost` reaches only the newt container's own loopback,
  and a bare hostname like the box's own name is `NXDOMAIN` — aardvark-dns
  only answers for container names on the named network. Symptom of any
  of the three wrong values: the tunnel **accepts** the TCP connection and
  closes it ~1s later with zero bytes (`kex_exchange_identification:
  Connection closed by remote host` for SSH), which reads like the edge
  blocking the port. It isn't — newt dials the target with a plain
  `net.Dialer` and there is no port-22 case or loopback filter anywhere in
  its proxy path. A *filtered* (rather than refused/unresolvable) target
  would instead hang until newt's 5s `tcpConnectTimeout`. Inspect and fix
  without the dashboard via the API (session token from
  `~/.config/pangolin/accounts.json`, cookie `p_session_token` plus header
  `X-CSRF-Token: x-csrf-protection`):
  `GET /api/v1/org/<org>/site/<siteId>/resources` shows
  `destination`/`tcpPortRangeString`/`alias`, and
  `POST /api/v1/site-resource/<siteResourceId>` with
  `{"destination": "<ip>"}` updates it — newt is pushed the change, no
  restart. Prefer an IP: the update schema's refine
  (`server/routers/siteResource/updateSiteResource.ts`) accepts a bare
  hostname only when `alias` is present *in the same payload*.
  Reaching the host this way also depends on the bare-metal nftables
  `input` chain accepting the port from the podman subnets (SSH is already
  covered by its blanket `tcp dport 22 accept`; another service is not).
- **A Tailscale OAuth client issues auth keys only for tags it owns one by
  one, not for each tag it was created with.** The `tailscaleAuthKey`
  client was first created with `tag:server` + `tag:gateway`. Its token
  request returned `scope: auth_keys`, which looked fine, but a node
  registering with *one* tag got `requested tags [tag:server] are invalid
  or not permitted`. The endpoint only accepted the exact pair (#163,
  phase 1). In a container that is a crash loop, so on materia it aborts
  the whole host. Fix: one owner tag (`tag:tailnet-provisioner`) listed in
  `tagOwners` for every node tag, and the client created with that tag
  only. Set or rotate the secret with `mise tailscale:set-auth-key`. It
  probes each tag alone and leaves the vault alone unless all pass. The
  stored value carries `?ephemeral=false&preauthorized=true`: an OAuth
  secret defaults to *ephemeral* nodes, which are deleted while offline
  and come back with a new IP.
- **The `tailscale` component runs `--netfilter-mode=off`, and flutterina
  has a Hetzner Cloud firewall the repo does not manage.** netavark on
  flutterina drives iptables over nf_tables. The tailscale image's
  `iptables` is iptables-legacy, and Tailscale's nftables mode writes into
  the `ip filter`/`ip nat` tables iptables-nft owns. Either mode mixes
  backends. With no host firewall, netfilter-off costs only Tailscale's
  100.64.0.0/10 anti-spoof drop. Separately, the Hetzner firewall
  `Pangolin` (label selector, so a rebuilt server gets it too) is applied
  to flutterina (`hcloud firewall describe`). Inbound: tcp/443 and udp/443
  (Traefik HTTPS and HTTP/3), udp/51820 and udp/21820 (Gerbil),
  udp/40000 (Tailscale peer relay, #163 phase 1b), and icmp, each with a
  description. **There is no tcp/22 rule** (removed 2026-10-24): SSH to
  flutterina goes over the tailnet only (`core@<flutterina-ts-ip>`, host
  sshd via `Network=host`; tailnet grants decide who may connect), with the
  Hetzner web console as the fallback. `hz:ssh`, `hz:pull-config`,
  `hz:push-config` and `hz:podman-gateway` use the tailnet IP whenever the
  server is an online peer of the workstation (`hz:_tailnet-ip`) and fall
  back to the public IP otherwise. **A rebuild has no SSH at all** until
  materia-update has run and the new node has joined the tailnet (and with
  a fresh state volume it joins as a new node with a new IP; delete the old
  `flutterina` device first so the name is reused). For `hz:push-config`
  right after `hz:rebuild`, add a temporary tcp/22 rule for your own IP and
  remove it afterwards. The firewall is also why "flutterina has no host
  firewall" does not mean "every port is open": it blocks `tailscaled`'s
  own UDP port, which is random in the container anyway, so a peer behind a
  hard NAT cannot reach flutterina directly. Instead flutterina is a peer
  relay on udp/40000 (set once with `tailscale set
  --relay-server-port=40000`, stored in the state volume; the
  `tailscale.com/cap/relay` grant targets `tag:relay` in the tailnet
  policy, not in this repo). Firewall rules are invisible to the repo:
  re-provisioning flutterina keeps them, but the relay setting must be
  re-applied. See `specs/plans/issue-163-phase1-tailscale-flutterina.md`.
- **`tailscale-gateway` forwards to container names through a serve config
  file, which materia manages.** `TS_SERVE_CONFIG` is loaded as is, and
  `TCPForward` is dialled with a plain system dial
  (`ipn/ipnlocal/serve.go`, `b.dialer.SystemDial`). So `"8096":
  {"TCPForward": "jellyfin:8096"}` resolves through the container's
  resolver (aardvark-dns on `newt-net`), exactly as newt does. Confirmed by
  a local POC and live on bow (#163 phase 2). The current CLI would also
  accept it (`tcp://jellyfin:8096`; a remote target needs the scheme, and
  only the legacy CLI was localhost-only), but CLI changes live in the
  state volume, outside git. Three things that look like
  faults but are not: (1) a port the tailnet grants do not allow is
  refused inside the gateway's netstack, so a client sees the connection
  closed at once (busybox `nc` prints `punt!`). flutterina → bow:22 does
  exactly that, because `tag:server` has no tcp/22 grant; (2) SSH via the
  gateway arrives at bow's sshd from the gateway container's `newt-net`
  address (`10.89.0.x → 10.89.0.1`), not from the client's tailnet IP;
  (3) flutterina ↔ bow is `peer-relay`, never `direct`: bow sits behind a
  hard home NAT (`MappingVariesByDestIP: true`), and only flutterina's
  relay (udp/40000) keeps it off DERP. Add a forward by editing
  `components/tailscale-gateway/serve/serve.json`; materia restarts the
  gateway (`RestartedBy`), which briefly drops every forwarded connection.
  **A new port also needs a tailnet grant, which is outside this repo.**
  The policy's `tag:server → tag:gateway` grant lists each app port
  (Tailscale admin console → Access controls). With only the `serve.json`
  forward, the gateway refuses flutterina's connections. Pangolin then
  marks the target `unhealthy`, and Traefik answers `503 no available
  server`, while the app looks fine from any peer the policy does allow
  (e.g. the workstation). Caught on #196 (PinePods, `tcp:8040`). Add the
  grant in the same change as the forward, and check that the Pangolin
  target turns `healthy` before relying on the route. This also means the
  same SSH session that triggers materia gets cut when the gateway
  restarts: SSH to bow goes through its port-22 forward.
- **containerboot (tailscale image v1.104.2) drops a Tailscale Service's
  advertisement on every restart, and only sometimes restores it.** Two
  upstream behaviours combine: (1) on shutdown it unadvertises every
  Service (`EnsureServicesNotAdvertised`, `main.go:491`, a graceful drain),
  which persists in the state volume; (2) on start, its serve-config watch
  loop never re-advertises (`sc, err := readServeConfig(...)` in
  `serve.go` shadows the outer `sc`, so `refreshAdvertiseServices` gets
  `nil`), and the startup path only catches the config if another netmap
  notification arrives after the file config lands. Symptom:
  `tailscale serve status` lists the Service and the node holds the
  `service-host` cap, but `tailscale debug prefs` shows
  `AdvertiseServices: null`, control drops the TailVIP from the host's
  `AllowedIPs`, and clients resolve the name but cannot connect. It took
  svc:bst-cache down for ~2 min after an ordinary materia restart on
  2026-10-24; a manual restart "fixing" it earlier was luck.
  Fix: `tailscale-gateway`'s `ExecStartPost` runs `advertise-services`,
  which calls `tailscale serve advertise` for every `svc:` in `serve.json`
  until the prefs show them (verified across 3 consecutive restarts). It is
  non-fatal, so check the unit journal for `advertised:` / `failed to
  advertise`. Any other containerized Service host needs the same. Not
  reported upstream.
- **Retargeting a Pangolin resource to the tailnet means changing the
  target's Site *and* host. Changing only the host takes the resource
  down.** With T2 (#163 phase 3) every bow app's target is site
  `flutterina`, host `<bow-ts-ip>:<port>`. Twice the dashboard save
  changed the host but left Site on `bow`. That makes bow's newt dial a
  tailnet IP it cannot route (bow's host is not on the tailnet, only the
  `tailscale-gateway` container is), and Jellyfin answered `503` until the
  site was fixed. Check after every retarget: in the `app` container,
  `curl -s http://localhost:3001/api/v1/traefik-config` must show the
  service URL on flutterina's site endpoint (the same `100.89.128.x` as
  Beszel), not bow's. The public hostname alone is not proof: while only
  the port or health check changed, the old route still answered 200.
- **Newt provisioning keys are consumed once.** The `spk_...` key in the
  vault is exchanged for a unique `id` + `secret` on first boot, which
  Newt persists to `newt-config.volume`. On subsequent boots, Newt reads
  the persisted credentials and ignores the key. If the config volume is
  wiped (`podman volume rm`), Newt can't re-provision with the same key —
  create a new key in the Pangolin dashboard and update the vault. The
  key has a max usage count set at creation time; each host consumes one.

  The inverse failure is equally permanent: if the Pangolin-side Newt record
  is deleted while the volume survives, Newt retries token exchange every
  three seconds with `400 "No newt found with that newtId"` and its
  `/tmp/newt-health` probe stays unhealthy forever. The stored provisioning
  key is ignored and cannot repair that ID. Caught on bow during #173
  (BUG-017; failing streak 2319). Bow's site was intentionally retired, so bow
  was removed from `[Roles.tunneled]`; `tailscale-gateway` now owns the
  still-required `newt-net` resource. On a host that still needs Newt, create a
  fresh provisioning key/site and remove `newt-config.volume` so it provisions
  a new identity. Resetting the transient failed healthcheck unit alone is a
  one-minute cosmetic fix.
- **`DOCKER_ENFORCE_NETWORK_VALIDATION=true` only filters container
  *discovery* — it does not gate proxying.** The flag reaches exactly one
  place in newt's source (`docker.ListContainers`, called from
  `newt/handlers.go`): it resolves newt's own container, adds a
  `network=<each of newt's networks>` filter to the Docker/podman
  container list, and hard-errors the listing if newt can't identify
  itself. So the dashboard only ever offers containers that share
  `newt-net` as resource targets. There is *no* dial-time check: the
  proxy path uses a plain `net.Dialer`, and `docker.IsWithinHostNetwork`
  (the function that would enforce it, error text "target address not
  within host container network") has zero callers in newt `main` as of
  2026-09-23. That is why a non-container `destination` — the host's own
  LAN IP, per the site-resource gotcha above — proxies fine with the flag
  on. The real isolation is the network itself: a container not on
  `newt-net` is invisible to Newt regardless of this flag. Keep it for
  the narrowed discovery list, but don't count on it to block a
  misconfigured target.

## Resource map

```text
  newt/                          # Pangolin tunnel client (role-assigned, [Roles.tunneled]; currently flutterina-only)
    MANIFEST.toml                # component manifest — Secrets = ["newtProvisioningKey"], Services
    newt.container.gotmpl        # userspace WireGuard tunnel client, joins newt-net network
    newt.network                 # named network for Newt hosts; gateway owns the same name on bow
    newt-config.volume           # named volume for Newt's provisioned id/secret
    blueprint.gotmpl             # provisioning blueprint (imperative, applied once at first boot)
  tailscale/                     # host-level Tailscale node, kernel mode (role-assigned, [Roles.tailnet], #163)
    MANIFEST.toml                # component manifest — Secrets = ["tailscaleAuthKey"] (vault globals), Services
    tailscale.container.gotmpl   # Network=host, /dev/net/tun, --netfilter-mode=off, health on 127.0.0.1:9002
    tailscale-state.volume       # named volume for node identity (losing it = new node, new tailnet IP)
  tailscale-gateway/             # userspace Tailscale node on newt-net, bow-only (the newt analogue, #163)
    MANIFEST.toml                # component manifest — Secrets = ["tailscaleAuthKey"] (vault globals), Services
    tailscale-gateway.container.gotmpl # tag:gateway, no caps/PublishPort, TS_SERVE_CONFIG from the serve/ dir
    newt.network                 # owns bow's stable newt-net after the Newt-to-Tailscale cutover
    serve/serve.json             # TCP forwards by container name (one tailnet port per app) + 22 → host sshd; Services block hosts svc:bst-cache
    advertise-services           # ExecStartPost helper: re-advertises every svc: in serve.json (containerboot bug workaround)
    tailscale-gateway-state.volume # named volume for node identity (losing it = new node, new tailnet IP)
```

The Pangolin Newt Helm chart is available from `charts.fossorial.io`. For the edge's shared namespace and Gerbil, see [Pangolin edge](pangolin-edge.md).
