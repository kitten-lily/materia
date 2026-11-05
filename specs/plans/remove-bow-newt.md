# Plan: remove broken Newt from bow

## Goal

Remove bow's dead Newt client and its consumed credentials after the Tailscale
backhaul migration. Keep flutterina's Newt client: Pangolin still uses the
flutterina site to retain target health checks while forwarding to bow's
Tailscale gateway.

## Evidence

- The user chose removal rather than reprovisioning after BUG-017.
- Bow's Newt retries every three seconds with Pangolin API status 400,
  `No newt found with that newtId`; its healthcheck failing streak reached 2319.
- Live Pangolin Traefik config has seven bow HTTP applications plus Beszel on
  the same flutterina site endpoint (`100.89.128.4`). Home Assistant uses a
  different endpoint. No HTTP service uses a bow-site endpoint.
- Buildbarn is exposed through Tailscale Service `svc:bst-cache`, not Pangolin.
- `tailscale-gateway` forwards every bow application and host SSH port from the
  tailnet; issue #163 phases 0–4 are complete.

## Constraint: `newt-net` outlives Newt

Removing bow's `tunneled` role removes the entire `newt` component, including
`newt.network`. That network cannot be deleted: every bow application and the
Tailscale gateway use `Network=newt-net` for stable container-name resolution.

Decision: copy the two-line `newt.network` resource into the
`tailscale-gateway` component before removing bow's role assignment. On bow,
Tailscale gateway becomes the owner of the shared network it requires. On
flutterina, the Newt component remains assigned and continues owning the same
network name. The components are never assigned together after the cutover, so
there is one owner per host.

A separate generic network component would add indirection for one resource and
is unnecessary. Renaming `newt-net` would require changing every consumer and
recreating the live network; keep the stable network name in this change.

## Changes

1. `components/tailscale-gateway/newt.network`: copy the existing network
   definition (`NetworkName=newt-net`).
2. `components/tailscale-gateway/MANIFEST.toml`: include `newt.network` in
   `RestartedBy` so a future network definition change cycles the gateway.
3. `MANIFEST.toml`: remove `tunneled` from `Hosts.bow.Roles`; keep `base`.
4. `AGENTS.md`: document per-host ownership of `newt-net` and that bow no longer
   runs Newt.
5. Mark BUG-017 fixed and update state.

## Expected bow plan

The same reconciliation must install the gateway-owned `newt.network` and
remove Newt's service, container, config volume, provisioning secret, blueprint,
manifest and component. The network unit must remain installed; reject any plan
that removes `newt.network` without also installing it under tailscale-gateway.

No application container, database, media volume, Tailscale state volume or
serve config should be removed. A host reload and gateway restart are expected
because its manifest gains ownership of the network resource; no application
service should restart. Newt's failed transient healthcheck disappears with its
container and healthcheck timer.

## Deployment

1. Run repository preflight.
2. Push/sync repository state as required by materia's git source, then run a
   bow plan and inspect it against the expected actions.
3. Run `materia-update.service` on bow.
4. Confirm the obsolete Newt transient healthcheck disappears after
   `newt.service`, the container and its healthcheck timer are removed.

## Verification

- `newt.service` and container are absent on bow.
- `newt-network.service` remains loaded from the gateway component; `podman
  network inspect newt-net` succeeds with every consumer still attached.
- All bow application services and `tailscale-gateway.service` remain active;
  gateway health is healthy.
- Container-name resolution still works through every serve forward. Probe the
  live gateway forwards from flutterina or via their existing public routes.
- No new failed unit remains after the gateway's restart-time health probe
  settles; the obsolete Newt transient is gone.
- A second materia v0.8 plan reports `No changes made`.
- Flutterina's Newt service remains active and healthy.

## Rollout evidence (2026-11-05)

- Bow's plan matched the expected removal/install cutover and completed without
  `FATA`.
- `newt.service`, its container, config volume, secret and component directories
  are absent. The gateway-owned network unit is loaded, and `newt-net` retains
  all 11 consumers.
- All bow application services are active. The Tailscale gateway is running and
  healthy with failing streak zero, still advertises `svc:bst-cache`, and can
  resolve and connect to all nine configured forward targets by name.
- Navidrome, Aonsoku, Grimmory, Audiobookshelf and Jellyfin returned 2xx/3xx
  over their public routes. Media Manager returned its expected protected-route
  401.
- The initial gateway health probe failed during restart, then the next probe
  passed. `systemctl --failed` is empty. The sync task now waits for these
  restart-time probes and rejects only failures added by reconciliation.
- A repeated apply reported `No changes made` and preserved v0.8's structured
  last-run diagnostics.
