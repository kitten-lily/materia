# Implementation Plan — Issue #163 Phase 1: `tailscale` on flutterina

**issue:** https://github.com/kitten-lily/materia/issues/163
**parent plan:** `specs/plans/issue-163-tailscale-backhaul.md`
**risk:** P2 (new component on the public edge host; a failing unit aborts
materia for every flutterina component, see BUG-010's blast radius)
**epic:** #163

## Summary

Add a host-level Tailscale node on flutterina in kernel mode, so its host
netns, and the podman containers routed through it (flutterina's newt, for
the phase-3 T2 targets), can reach tailnet IPs. Nothing is retargeted in
this phase; Pangolin traffic is untouched.

## Facts gathered (2026-10-23)

| Fact | Evidence |
|---|---|
| Image `docker.io/tailscale/tailscale:v1.104.2`, index digest `sha256:b11583ad…849d` | `skopeo inspect` |
| Image is Alpine with busybox `wget` (HealthCmd works), `iptables` → **iptables-legacy**, `iptables-nft` also shipped | `podman run --entrypoint sh` |
| flutterina: Flatcar 4757.2.1, kernel 6.12, podman 5.7.1, netavark 1.17.1, `/dev/net/tun` present, `tun` loaded | SSH |
| netavark uses its **iptables driver over iptables-nft** (`iptables v1.8.13 (nf_tables)`; nft shows `table ip filter is managed by iptables-nft, do not touch!`) | `iptables -V`, `nft list ruleset` |
| Nothing listens on 41641/udp or 9002; sshd is socket-activated on `*:22` | `ss -lunpt` / `ss -tlnp` |
| **Hetzner Cloud firewall `Pangolin` is applied** to flutterina: inbound icmp, tcp 443, udp 51820/21820, tcp 7981-7982, tcp 22 from three source IPs only. 41641/udp is closed | `hcloud firewall describe` |
| containerboot 1.104.2 env: `TS_AUTHKEY`, `TS_AUTH_ONCE`, `TS_EXTRA_ARGS`, `TS_HOSTNAME`, `TS_STATE_DIR`, `TS_USERSPACE`, `TS_ENABLE_HEALTH_CHECK`, `TS_LOCAL_ADDR_PORT`; `--accept-dns=false` unless `TS_ACCEPT_DNS=true` | `cmd/containerboot/settings.go`, `tailscaled.go` |
| A `globals`-only attribute works in a component's `Secrets` and in `secretEnv` | materia v0.7.2 `internal/attributes/main.go:35-59`, `pkg/loader/secret.go:21-36` |
| **The OAuth client mints keys only for its exact tag set.** Token/key requests for `tag:server` or `tag:gateway` alone return `requested tags [...] are invalid or not permitted`; both together succeed | local smoke test + token-endpoint probe |

## Decisions

1. **Kernel mode, `Network=host`**, `AddDevice=/dev/net/tun`,
   `AddCapability=NET_ADMIN NET_RAW`. As in the parent plan.
2. **`--netfilter-mode=off`** instead of the parent plan's "match netavark's
   firewall driver". Neither of Tailscale's modes can match it from this
   image. iptables mode shells out to the image's `iptables`, which is
   legacy, so it would add a legacy table set next to netavark's
   iptables-nft rules. nftables mode writes native rules into the same
   `ip filter`/`ip nat` tables iptables-nft owns
   (`util/linuxfw/nftables_runner.go`: `createTableIfNotExist(..., "filter")`).
   flutterina has no host firewall (FORWARD policy accept), so the only thing
   lost is Tailscale's 100.64.0.0/10 anti-spoof drop on non-tailscale0
   interfaces. Routing (`ip rule` table 52) is not netfilter and still
   happens.
3. **`TS_AUTH_ONCE=true`.** Later starts run `tailscale set`, which tolerates
   manual changes; `tailscale up` on every start would crash-loop (and abort
   materia) if anyone ran `tailscale set` by hand. Cost: changing
   `TS_EXTRA_ARGS` later needs `podman exec tailscale tailscale set ...` on
   the host. Recorded in the quadlet.
4. **Health:** `TS_ENABLE_HEALTH_CHECK=true`,
   `TS_LOCAL_ADDR_PORT=127.0.0.1:9002`,
   `HealthCmd=wget -q -O /dev/null http://127.0.0.1:9002/healthz`. No
   `HealthOnFailure=`. The cloud firewall would block 9002 anyway; the
   loopback bind does not depend on it.
5. **State** in `tailscale-state.volume` (root-owned, `:Z`). Losing it means a
   new node and a new IP.
6. **Assignment** via `[Roles.tailnet]`, flutterina only. krytis-runner joins
   in phase 4.
7. **41641/udp stays closed** at the Hetzner firewall for now. Tailscale's
   NAT traversal should get a direct path through a stateful, non-NAT
   firewall. Phase 2 checks `tailscale ping`; add the rule only if it shows
   DERP.

## Precondition (blocking): OAuth client that can issue either tag

Per Tailscale's OAuth docs (multi-tag pattern):

1. Policy file:
   ```hujson
   "tagOwners": {
     "tag:tailnet-provisioner": ["autogroup:admin"],
     "tag:server":  ["autogroup:admin", "tag:tailnet-provisioner"],
     "tag:gateway": ["autogroup:admin", "tag:tailnet-provisioner"],
   },
   ```
2. Trust credentials → new OAuth client, **Auth Keys: Write**, tag
   `tag:tailnet-provisioner` only. Revoke the old `tag:server`+`tag:gateway`
   client.
3. `mise tailscale:set-auth-key` (hidden prompt). It probes the token
   endpoint once per tag and refuses to touch the vault unless each tag
   alone returns `auth_keys`, then writes `globals.tailscaleAuthKey` with
   the `?ephemeral=false&preauthorized=true` suffix and reads it back.

- verify: the task prints `auth_keys OK` for `tag:server` and `tag:gateway`.

## Changes

- `components/tailscale/MANIFEST.toml`: `Secrets = ["tailscaleAuthKey"]`,
  `tailscale.service` restarted by the container and volume.
- `components/tailscale/tailscale.container.gotmpl`: the decisions above.
- `components/tailscale/tailscale-state.volume`.
- `MANIFEST.toml`: `[Roles.tailnet] Components = ["tailscale"]`, flutterina
  `Roles += "tailnet"`.
- Renovate: covered by the existing `quadlet` manager
  (`*.container.gotmpl`); minor bumps automerge like every other image.

## Rollout

1. Local smoke (userspace, `ephemeral=true`, hostname `ts-smoke`): node
   reaches `Running` with `tag:server`, IP inside `100.64.0.0/12`, `/healthz`
   200 and `podman healthcheck run` healthy. Then remove the container.
2. Snapshot public HTTP status codes for every Pangolin hostname.
3. Push; on flutterina `sudo systemctl start materia-update.service`.

## Verify

- verify: `journalctl -u materia-update.service --since -15min | grep -c FATA` → `0`
- verify: `systemctl is-active tailscale.service` → `active`; `podman healthcheck run tailscale` → exit 0
- verify (melog): `tailscale status --json` lists `flutterina` with `Tags: ["tag:server"]` and an IP in `100.64.0.0/12`
- verify: `ss -ltn | grep 9002` shows only `127.0.0.1:9002`
- verify: `sudo nft list ruleset | grep -c 'ts-'` → `0` (netfilter off)
- verify: `ip rule | grep -c 52` ≥ 1 (Tailscale's routing table is installed)
- verify: every public hostname returns the same status code as the snapshot
- verify (melog): `ssh core@<flutterina-ts-ip> hostname` → `flutterina`
  (host sshd over tailscale0; the Hetzner firewall's tcp/22 allowlist does
  not apply inside the tunnel)

## Rollback

Remove `tailnet` from flutterina's `Roles` and push. If materia itself is
aborting, `sudo systemctl stop tailscale.service` first so the next run can
complete.
