# Implementation Plan — Issue #163 Phase 2: `tailscale-gateway` on bow

**issue:** https://github.com/kitten-lily/materia/issues/163
**parent plan:** `specs/plans/issue-163-tailscale-backhaul.md`
**risk:** P2 (new component on bow; a failing unit aborts materia for every
bow component, BUG-010's blast radius). No existing traffic moves in this
phase: Pangolin keeps routing through newt until phase 3.
**epic:** #163
**status:** deployed and verified 2026-10-24 (commit `206e483`)

## Summary

A userspace Tailscale node on bow's `newt-net`, the newt analogue. It
registers as `bow` with `tag:gateway` and uses `tailscale serve` TCP
forwards to expose each app by container name on its own tailnet port, plus
`22 → host.containers.internal:22` for SSH to bow that does not depend on
the edge.

## Facts gathered (2026-10-24)

| Fact | Evidence |
|---|---|
| `TCPForward` is dialled with `b.dialer.SystemDial(ctx, "tcp", backDst)`, a plain system dial | `ipn/ipnlocal/serve.go:688-700` (v1.104.2) |
| **A container hostname works.** Local POC: userspace gateway on a named podman network, serve config `8080 → web:80`; melog → `<gw-ts-ip>:8080` returned 200 | POC |
| `host.containers.internal:22` resolves and is dialled (refused on melog, which runs no sshd; on rootful bow it is the `newt-net` gateway, already confirmed reachable in AGENTS.md) | POC log `dial tcp 169.254.1.2:22: connect: connection refused` |
| Serve config loaded from a directory mount: `tailscale serve status` lists every forward | POC |
| bow: podman 5.7.1, `newt-net` = `10.89.0.0/24` gw `10.89.0.1`, all 10 app containers on it, sshd socket-activated on `*:22`, nftables `input` accepts `tcp dport 22` | SSH |
| Tailnet name `bow` is free (stale device removed in phase 0) | `tailscale status` |

Container names (from `ContainerName=`) and ports:

| Forward | Target | Consumer |
|---|---|---|
| 8080 | `aonsoku:8080` | Pangolin (phase 3) |
| 80 | `audiobookshelf:80` | Pangolin |
| 6060 | `grimmory:6060` | Pangolin |
| 8096 | `jellyfin:8096` | Pangolin |
| 8000 | `mediamanager:8000` | Pangolin |
| 4533 | `navidrome:4533` | Pangolin |
| 7981 | `bb-asset:7981` | krytis-runner, workstation (phase 4; TLS passes through untouched) |
| 7982 | `bb-storage:7982` | same |
| 22 | `host.containers.internal:22` | admin (members) |

The databases (`grimmory-mariadb`, `mediamanager-postgres`) get no forward.

## Decisions

1. **Userspace mode** (`TS_USERSPACE=true`), `Network=newt-net`, no
   capabilities, no `/dev/net/tun`, no `PublishPort`. Inbound tailnet
   traffic terminates in the container's netstack, so bow's host netns and
   nftables are untouched; only outbound UDP is needed, which the closed
   posture already allows from `10.89.0.0/16`.
2. **Tags:** `--advertise-tags=tag:gateway`, `TS_HOSTNAME=bow`, same
   `TS_AUTH_ONCE=true` + `globals.tailscaleAuthKey` as the `tailscale`
   component. No netfilter flag: userspace has none.
3. **Serve config** `serve/serve.json` is a data resource, bind-mounted as
   a **directory** (`{{ m_dataDir }}/serve:/config/serve:ro,Z`) per the
   Tailscale container docs, `TS_SERVE_CONFIG=/config/serve/serve.json`.
   It sits under the data dir but is materia-installed, so no drift.
4. **Health:** `TS_ENABLE_HEALTH_CHECK=true`,
   `TS_LOCAL_ADDR_PORT=127.0.0.1:9002` (the container netns), same
   `HealthCmd`, no `HealthOnFailure=`.
5. **State:** `tailscale-gateway-state.volume`.
6. **Restarts:** `RestartedBy = ["tailscale-gateway.container",
   "serve/serve.json", "tailscale-gateway-state.volume"]`.
7. **Grants (already in the policy):** `tag:server → tag:gateway` on the
   six app ports + 7981-7982; `autogroup:member → *` covers SSH on 22.
   flutterina → bow:22 is not granted (not needed).
8. **Peer relay:** `tag:gateway` is already in the relay grant's `src`, so
   if flutterina ↔ bow cannot go direct it uses flutterina's relay.

## Changes

- `components/tailscale-gateway/MANIFEST.toml`
- `components/tailscale-gateway/tailscale-gateway.container.gotmpl`
- `components/tailscale-gateway/tailscale-gateway-state.volume`
- `components/tailscale-gateway/serve/serve.json`
- `MANIFEST.toml`: add `tailscale-gateway` to `[Hosts.bow] Components`.

## Verify

- verify: `journalctl -u materia-update.service --since -15min | grep -c FATA` on bow → `0`
- verify: `systemctl is-active tailscale-gateway.service` → `active`, healthcheck healthy
- verify (melog): `bow` online with `Tags: ["tag:gateway"]`, IP in `100.64.0.0/12`
- verify: `tailscale serve status` in the container lists all 9 forwards
- verify (flutterina, from a throwaway container on `newt-net`, the path
  newt will use in phase 3): `wget -qO- http://<bow-ts-ip>:8096/health` →
  `Healthy`, and each app port answers
- verify: `tailscale ping <bow-ts-ip>` from flutterina → `direct` or
  `peer-relay`, never DERP
- verify (melog): `ssh -p 22 core@<bow-ts-ip> hostname` → `bow`
- verify: Pangolin public hostnames unchanged (no retargeting yet)

## Rollback

Remove `tailscale-gateway` from bow's `Components` and push. If materia is
aborting on it, `sudo systemctl stop tailscale-gateway.service` first.

## Results (2026-10-24)

| Check | Result |
|---|---|
| materia-update (bow) | `success`, 0 `FATA`; installed the serve dir, file, volume, container, secret; started the unit |
| Unit / health | `active`, healthy (the first probe while `starting` left a transient failed unit, as on flutterina) |
| Node | `bow`, `tag:gateway`, IPv4 inside `100.64.0.0/12` |
| `tailscale serve status` | all 9 forwards listed |
| flutterina → bow from a throwaway container on `newt-net` (newt's phase-3 path) | `8096/health` 200, `4533/ping` 200, `6060/` 200, `8000/` 307 (MediaManager redirect), `8080/` 200, `80/healthcheck` 200; tcp 7981 and 7982 open |
| flutterina → bow:22 | refused by the gateway netstack (`punt!`): the grants give `tag:server` no tcp/22, as intended |
| melog → bow:22 via gateway | `ssh core@<bow-ts-ip>` lands on host sshd as `10.89.0.13 → 10.89.0.1` |
| Path flutterina ↔ bow | `peer-relay` through flutterina's relay, 26 ms. bow shares melog's home NAT (`MappingVariesByDestIP: true`), so direct is impossible without a port forward; without phase 1b this would be DERP |
| Path melog ↔ bow | direct over the LAN |
| Public hostnames | all 9 unchanged |
