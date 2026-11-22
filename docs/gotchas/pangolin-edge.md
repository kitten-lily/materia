# Pangolin edge

Read this guide when working on the shared edge pod, Traefik, badger, HTTP/3, or Pangolin resource settings.

- **Pod restart safety requires `ExitPolicy=continue` — quadlet's default
  (`stop`) makes ANY `app.service` restart a total edge outage.** This
  bullet previously claimed the pod-drain issue was a reconciler-script
  problem that materia avoids by restarting only the changed service.
  That was wrong, and it cost a P0 on 2026-09-21 (BUG-009). Two facts
  combine: (1) `podman-systemd.unit(5)` — "Set the exit policy of the pod
  when the last container exits. **Default for quadlets is stop**", so
  podman stops the pod (killing the infra container, the shared netns and
  every `PublishPort`) the instant its last member exits; (2)
  `gerbil.service` and `traefik.service` both `Requires=app.service`, and
  systemd propagates a stop to units that `Requires=` a unit being
  restarted — so restarting *app alone* stops all three, app leaves last,
  and the pod drains. `app.service` has `BindsTo=pangolin-pod.service`, so
  its restart then fails outright: `Bound to unit pangolin-pod.service,
  but unit isn't active` → `Dependency failed`. Externally this is not a
  503: Traefik and the published ports are gone, so every hostname just
  refuses the connection. Every Renovate bump of `app.container`'s digest
  was rolling this dice. Fix: `ExitPolicy=continue` in the `[Pod]` section
  (verified live — `systemctl restart app.service` now keeps
  `pod_state=Running` and all three services active). Recovery if it ever
  happens again: `sudo systemctl start pangolin-pod.service` then app,
  gerbil, traefik. Any new pod in this repo should set
  `ExitPolicy=continue` unless it is genuinely meant to disappear with its
  workload. The pod itself still only restarts when the `.pod` file
  changes.

- **A Pangolin health check against an app that validates `Host` needs a
  `Host` header.** Pangolin probes the target IP (`hcHostname` = the bow
  tailnet IP). SilentSuite (Django `ALLOWED_HOSTS` + FastAPI
  `TrustedHostMiddleware`) answers `400 Invalid host header` to that. Set
  `hcHeaders: [{name: "Host", value: "<public hostname>"}]` and
  `hcStatus: 200` on the target (done through the API for resource 14,
  2026-11-18; Pangolin then reports it healthy).

- **Startup ordering, not networking.** `connection refused to localhost:3001`
  is a race: Gerbil/Traefik must be `After=app.service`/`Requires=app.service`,
  and `app` uses `Notify=healthy` + `HealthCmd` so dependents wait until it
  serves.

- **Containers reach each other over localhost.** In a pod, all containers
  share one network namespace. Traefik/Gerbil configs reference `localhost:3001`,
  not `app:3001`. The `server.internal_hostname` in `config.yml` is `localhost`.
- **HTTP/3 on the edge needs three switches, and Pangolin ships the first
  two commented out.** Pangolin's manual-install docs
  ([podman quadlets](https://docs.pangolin.net/self-host/manual/podman-quadlets),
  [docker compose](https://docs.pangolin.net/self-host/manual/docker-compose))
  have `# PublishPort=443:443/udp` in the pod and `# http3: advertisedPort:
  443` under Traefik's `websecure`, each saying the other must be enabled
  too. This repo had only the first (`pangolin.pod` publishes `443/udp`),
  and the Hetzner firewall `Pangolin` had no udp/443 rule. So QUIC was dead
  end to end while looking half-configured: no `Alt-Svc` header, every
  client on HTTP/2. Enabled 2026-10-24: `http3: {}` in
  `traefik_config.yml.gotmpl` plus the firewall rule "Traefik HTTP/3
  (QUIC): Pangolin public edge". `{}` instead of upstream's
  `advertisedPort: 443` is equivalent: Traefik advertises the entrypoint's
  own port when it is unset (live `alt-svc: h3=":443"; ma=2592000`).
  Verify with `curl --http3-only -sI https://<host>/` (needs a curl built
  with HTTP3), which must return the same status as plain HTTPS. All 9
  hostnames did. Dropping any one of the three silently falls back to
  HTTP/2, so nothing breaks visibly. **One divergence from that same
  upstream block is still open:** it sets
  `http.encodedCharacters.allowEncodedSlash` and
  `allowEncodedQuestionMark` on `websecure`, and this repo does not. If an
  app behind the edge starts rejecting URLs containing `%2F` or `%3F`,
  check that first.
- **Gerbil is the networking edge.** In the official architecture, Traefik
  shares Gerbil's network namespace (docker-compose uses
  `network_mode: service:gerbil`). A pod achieves the same: all containers share
  one namespace, ports published at the pod level. Gerbil's SNI proxy can route
  TLS traffic in multi-node deployments; in single-node it's bypassed (443→443
  direct to Traefik).

- **A bad `badgerVersion` bump is a total edge outage, and it looks like a
  routing bug.** Traefik validates every remote plugin against its catalog:
  it downloads the archive, then calls
  `GET plugins.traefik.io/public/validate/<module>/<version>` with
  `X-Plugin-Hash: <hex sha256 of the archive>` (`pkg/plugins/downloader.go`
  `RegistryDownloader.Check`, `manager.go` `computeHash`). A non-200
  disables **all** plugins, and since every router — this repo's
  `dynamic_config.yml` ones *and* every resource router Pangolin generates
  through the HTTP provider — references the `badger` middleware, Traefik
  then has zero valid routers and answers a bare `404 page not found` for
  every hostname, dashboard included. All three pod services stay `active
  (running)`, materia's run is green, and nothing is in `--failed`: the only
  evidence is `journalctl -u traefik.service` (`Plugins are disabled because
  an error has occurred` + one `invalid middleware "badger@…"` line per
  router). In September (BUG-007), badger v1.6.0/v1.6.1/v1.7.0 got 404
  from that endpoint while v1.5.0 got 200. That was recorded as a
  catalog-side breakage (fosrl/badger#31, traefik/piceus#156) with the
  endpoint "ignoring `X-Plugin-Hash`". **The catalog has changed since:
  as of 2026-11-05 it enforces the hash** (BUG-014), and it has
  re-published the v1.6.1 archive (new sha256). For every badger version and for
  `traefik/plugindemo`, a missing, empty or wrong hash gets 404 and the
  right hash gets 200, all uncached (`cf-cache-status: DYNAMIC`). v1.6.x and
  v1.7.0 now validate. So **never probe `validate` with a bare `curl`**: it
  always says 404. Send the hash the way traefik does, as the
  `badger-catalog` workflow does. [INFERENCE] Cloudflare caches by URL, not
  by that header, so a cached hashless 404 explains BUG-011/BUG-013's
  per-edge disagreements. It could also reach a real traefik startup.
  Renovate PR #52's v1.5.0 → v1.6.1 bump took flutterina down this way
  (BUG-007). The outage waited for the next `traefik.service` restart,
  because the running process kept serving with the old plugin loaded.
  The `<=1.5.0` hold was lifted on 2026-11-05. Upstream says v1.6.0–v1.7.0
  were re-released after a plugin-registry outage that Traefik fixed on
  2026-08-27 (traefik/traefik#13771). badger is now `v1.8.0`, after it
  passed the hash check and loaded in a local traefik run (upstream
  v3.7.16 and minimus v3.7.13, with a `v9.9.9` control that reproduces the
  outage). Badger bumps are **never automerged** (`renovate.json5`): the
  global automerge rule sets `ignoreTests`, so it would not wait for the
  `badger-catalog` workflow. That workflow gates the pin. It runs only when
  `components/pangolin/MANIFEST.toml` (or the workflow) changes, retries
  for ~2 min, and logs `cf-ray`/`cf-cache-status`/`age` on every attempt.
  Run the local reproduction below on every bump before merging.
  To reproduce any plugin question locally without touching
  a host: `podman run --rm --tmpfs /plugins-storage -v <dir>:/etc/traefik:ro,Z
  docker.io/library/traefik:<tag> --configFile=/etc/traefik/traefik.yml` — the
  `--tmpfs` is required, or the plugin manager fails earlier with `mkdir
  plugins-storage: permission denied` and masks the real error.

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

## Resource map

```text
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
```

## Temporary Traefik access log

The access log in `components/pangolin/traefik/traefik_config.yml.gotmpl` was added on 2026-11-22 for the #179 Phase 4 E6 baseline. Remove it after the seven-day collection. [Traefik configuration template](../../components/pangolin/traefik/traefik_config.yml.gotmpl)
