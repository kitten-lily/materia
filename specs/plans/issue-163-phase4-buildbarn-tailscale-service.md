# Implementation Plan — Issue #163 Phase 4: Buildbarn as a Tailscale Service

**issue:** https://github.com/kitten-lily/materia/issues/163
**parent plan:** `specs/plans/issue-163-tailscale-backhaul.md`
**risk:** P2. Touches krytis CI's cache path (cert rotation + endpoint
change) and, in the cleanup step, restarts `pangolin.pod` (`PublishPort`
removal), which is a brief total edge outage.
**epic:** #163

## Summary

Move krytis's Buildbarn cache (bb-asset :7981, bb-storage :7982 on bow) off
Pangolin's raw TCP resources onto a **Tailscale Service**, `svc:bst-cache`,
hosted by bow's `tailscale-gateway`. Clients reach it as
`bst-cache.<tailnet>.ts.net:7981/7982`. `bst-cache.<baseDomain>` is dropped
entirely: no Pangolin resource, no published ports, no firewall rule, no
Traefik entryPoints. It never had its own DNS record (the wildcard covered
it), so there is nothing to delete in DNS.

Decisions taken with the user (2026-10-24): krytis-runner resolves the
Service name through the materia `tailscale` component + systemd-resolved
over D-Bus; TLS stays Buildbarn's own self-signed cert, re-issued for the
new name.

## Facts gathered (2026-10-24)

| Fact | Evidence |
|---|---|
| Tailscale Services: stable MagicDNS name + TailVIP, `tcp:` endpoints (TCP is the only transport), host must be tag-based, needs admin-defined Service + host approval (or `autoApprovers.services`), reachable via grants with `dst: ["svc:<name>"]` | Tailscale docs, "Tailscale Services" |
| containerboot reads `Services` from `TS_SERVE_CONFIG` (`ipn.ServeConfig.Services map[ServiceName]*ServiceConfig`, same `TCP`/`TCPForward` handlers) and auto-advertises them (`TS_EXPERIMENTAL_SERVICE_AUTO_ADVERTISEMENT`, default true) | `cmd/containerboot/serve.go:116-142`, `main.go:173`, `ipn/serve.go:38-64` (v1.104.2) |
| Cache clients: krytis `cache-warm.yml` (`runs-on: [self-hosted, linux, x64, krytis-vps]` = krytis-runner) and `mise/tasks/bst` (workstation). `track-bst-sources.yml` (GitHub-hosted) does not use the cache | krytis repo grep |
| krytis pins `quadlet/buildbarn/certs/bow-server.crt`, SAN `DNS:bst-cache.<baseDomain>`, valid to 2028 | `openssl x509` |
| krytis-runner: Debian 13, systemd-resolved stub mode, `/run/dbus/system_bus_socket`, `/dev/net/tun`, podman 5.4.2, no host firewall | SSH |
| **POC on krytis-runner:** containerized kernel-mode tailscaled with only `TS_ACCEPT_DNS=true` + D-Bus socket picked **`direct` mode** (podman gives a `Network=host` container a rewritten resolv.conf without resolved's stub marker) and wrote only the container's resolv.conf | POC log `dns: using "direct" mode` |
| **POC, with the host's `/run/systemd/resolve/stub-resolv.conf` bound over the container's `/etc/resolv.conf`:** `dns: using "systemd-resolved" mode`; resolved got `tailscale0` with `100.100.100.100`, tailnet domain as routing domain, `-DefaultRoute`; the host resolved `bow.<tailnet>.ts.net` and bare `flutterina`; `ens3` DNS unchanged; stopping the container removed it all | POC |
| A cert change does not restart Buildbarn today: `certs/server.crt` is not in either service's `RestartedBy`, and the key is a podman secret | `components/buildbarn/MANIFEST.toml` |

## Changes

### Repo (materia)

1. `tailscale` component, opt-in MagicDNS on the host:
   `{{ if exists "tailscaleMagicDns" }}` adds `TS_ACCEPT_DNS=true`,
   `Volume=/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro`
   and `Volume=/run/systemd/resolve/stub-resolv.conf:/etc/resolv.conf:ro`.
   Opt-in per host: a missing bind source is a hard failure (BUG-005
   class) that would abort materia, and flutterina has no need for it.
   `TS_ACCEPT_DNS` is re-applied by `tailscale set` on every start, so it
   is declarative despite `TS_AUTH_ONCE`.
2. `MANIFEST.toml`: `[Hosts.krytis-runner] Roles = ["tailnet"]`,
   `[Hosts.krytis-runner.Extensions.tailscale.Defaults] tailscaleMagicDns = true`.
   It registers as `krytis-runner` with `tag:server`.
3. `tailscale-gateway/serve/serve.json`: add
   `"Services": {"svc:bst-cache": {"TCP": {"7981": {"TCPForward": "bb-asset:7981"}, "7982": {"TCPForward": "bb-storage:7982"}}}}`.
4. `buildbarn/MANIFEST.toml`: add `certs/server.crt` to both services'
   `RestartedBy`.
5. Cert: unset `components.buildbarn.serverKeyPem` in `attributes/bow.yml`,
   then `mise buildbarn:server-cert-init --hostname bst-cache.<tailnet>.ts.net`
   (writes the key to the vault, the cert to `components/buildbarn/certs/`).
   Update the task's help text, which still talks about raw TCP and
   wildcard DNS.
6. Cleanup (after krytis has switched):
   - remove the gateway's node-port forwards 7981/7982
   - `pangolin.pod`: remove `PublishPort=7981/7982` (pod restart)
   - `traefik_config.yml.gotmpl`: remove `tcp-7981`/`tcp-7982`
   - `config.yml.gotmpl`: remove `allow_raw_resources`
   - delete `components/buildbarn/blueprint-resources.yaml`
   - AGENTS.md: buildbarn entries, layout, the new gotchas

### Tailnet policy + admin console (user)

- Services → Define a Service: `bst-cache`, endpoints `tcp:7981,tcp:7982`.
- Policy:
  ```hujson
  "autoApprovers": {"services": {"svc:bst-cache": ["tag:gateway"]}},
  "grants": [
    {"src": ["tag:server", "autogroup:member"], "dst": ["svc:bst-cache"],
     "ip": ["tcp:7981", "tcp:7982"]},
  ],
  ```
  `tag:server` covers krytis-runner (and flutterina, harmlessly: every RPC
  still needs a JWT); members cover the workstation.

### Pangolin (user)

- Delete the "BST Cache Index" and "BST Cache Storage" raw TCP resources.

### Hetzner (me)

- Delete the `tcp/7981-7982` firewall rule.

### krytis repo

- `quadlet/buildbarn/certs/bow-server.crt` ← new cert.
- `cache-warm.yml` and `mise/tasks/bst`: `bst-cache.<baseDomain>` →
  `bst-cache.<tailnet>.ts.net` (URLs and the `bow-artifact-check.py
  --probe` arguments).
- Committed only with the user's go-ahead (separate repo).

## Rollout order

1. krytis-runner joins the tailnet (repo changes 1–2), materia run.
   Verify `krytis-runner` online with `tag:server`; `getent hosts
   bow.<tailnet>.ts.net` on the host; no `FATA`.
2. User defines the Service + policy. Repo change 3, materia on bow.
   Verify the Service is `Connected` in the admin console; from
   krytis-runner, `bst-cache.<tailnet>.ts.net` resolves to the TailVIP
   and TCP 7981/7982 connect. The old cert still answers (name mismatch
   expected).
3. Cert rotation (repo changes 4–5) + krytis repo update, back to back:
   between bow's deploy and krytis's merge, krytis CI's cache steps fail
   TLS verification. Verify the containers serve the new cert (`openssl
   s_client -connect bst-cache.<tailnet>.ts.net:7982 -servername ...`); if
   bb-* still present the old one, the podman secret went stale (AGENTS.md,
   BUG-003 layer 3): `podman secret rm materia-serverKeyPem` + rerun.
4. krytis: `mise run bst --pull` (workstation) and a `cache-warm.yml` run
   on krytis-runner reach the cache.
5. Cleanup (repo change 6, Pangolin resources, Hetzner rule). The pod
   restart briefly drops the whole edge; verify every public hostname
   afterwards.

## Verify

- verify: `krytis-runner` is `tag:server`, online, and resolves
  `*.<tailnet>.ts.net` on the host
- verify: `svc:bst-cache` `Connected`; `tailscale serve status` on the
  gateway lists it
- verify: from krytis-runner, `openssl s_client` to
  `bst-cache.<tailnet>.ts.net:7981` and `:7982` shows the new cert's
  subject
- verify: krytis `cache-warm.yml` run green with `Pushed artifact` lines
  to the new URL
- verify: Hetzner firewall has no `tcp/7981-7982`; flutterina `ss -ltn`
  shows nothing on 7981/7982; Pangolin has no raw resources
- verify: all public hostnames unchanged after the pod restart

## Rollback

Until step 3, the old path (Pangolin raw resources + old cert) is
untouched. After step 3, rolling back means restoring the old
`serverKeyPem` (git history of `attributes/bow.yml`) and the old cert;
the raw resources then work again until step 5 removes them.

## Results (2026-10-24)

| Step | Result |
|---|---|
| 1. krytis-runner joins | `Result=success`; node `krytis-runner`, `tag:server`; tailscaled used `*dns.resolvedManager`; the **host** resolves `bow.<tailnet>.ts.net`; krytis-runner ↔ bow is **direct** (runner has an easy NAT). flutterina's tailscale was not restarted (template block trims to identical output) |
| 2. Service | Gateway applied the `Services` block, got the `service-host` cap with TailVIP `100.112.231.57` (outside the node `ipPool`, which Services don't use; clear of Pangolin's ranges), but `AdvertiseServices: null`: containerboot's watch loop shadows `sc` and never advertises (AGENTS.md gotcha). One more gateway restart → advertised, TailVIP in bow's `AllowedIPs`, krytis-runner reached 7981/7982 by name |
| 3. Cert | New cert SAN `DNS:bst-cache.<tailnet>.ts.net`, valid to 2029-01-26. materia logged the secret update but the podman secret kept the **old** key → bb-storage/bb-asset `tls: private key does not match public key`, `start-limit-hit`, materia `FATA` on bow (~1 min). `podman secret rm materia-serverKeyPem` + rerun fixed it. From krytis-runner both ports verify against the new cert with hostname check; krytis's own `bow-artifact-check.py --probe` (JWT auth) passes from the PR worktree |
| krytis | starlit-os/krytis#1410 (cert + URLs + docs). Its PR CI skipped building (touches `project.conf`), so the probe above is the end-to-end proof |
