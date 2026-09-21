# BUG-008 — beszel hub crash-loops after `User=1000`: pre-existing volume is root-owned

**status:** implemented-pending-verification
**found:** 2026-09-21, reported as "beszel is down"
**severity:** P1 (monitoring + alerting blind for ~4 days; no other service
affected)
**epic:** standalone (beszel-hub / beszel-agent, issue #26)

## Symptom

`https://beszel.<baseDomain>/` and `/api/health` both return `503` with the
body `no available server` (Traefik's "service has no healthy backend"
response), while the rest of the edge is healthy:

```
beszel.<baseDomain>/api/health   503   no available server
pangolin.<baseDomain>/           200
music.<baseDomain>/              200
jellyfin.<baseDomain>/           302   (Pangolin SSO redirect = reachable)
navidrome.<baseDomain>/          302
```

So: Traefik, Pangolin, Gerbil, and every bow-tunneled resource are fine —
only the flutterina-local beszel hub backend is gone.

Nothing alerted. Beszel *is* the alerting system, so a dead hub cannot
report itself; the Pangolin-native health check that exists for exactly
this reason (#24) either wasn't configured or its alert rule didn't fire —
worth re-checking once the hub is back.

## Root cause

Commit `7a33daa` ("feat: run beszel hub + agent as UID 1000 (#26)",
2026-09-17) added:

- `User=1000` / `Group=1000` to `beszel-hub.container.gotmpl`
- `User=1000` / `Group=1000` to `beszel-data.volume`
- `User=1000` / `Group=1000` to `beszel-agent.container.gotmpl`

`User=`/`Group=` in a `.volume` quadlet are **creation-time** arguments.
Flutterina's `systemd-beszel-data` volume has existed since #20 (July),
populated by a root-run hub, so those keys were ignored entirely — podman
only auto-chowns a named volume to the container user when the volume is
**empty** at first use. The UID-1000 hub therefore started against a
root-owned `/beszel_data` (PocketBase `data.db`, `auxiliary.db`, WAL files,
`id_ed25519`, all `root:root 0644`), failed its first write, and exited:

```
2026/09/21 08:26:43 attempt to write a readonly database (1544)
```

`Restart=always` turned that into a crash loop; Traefik's beszel service
has no healthy server; every request gets `503 no available server`.

The failure is **version-independent** — `0.19.0` and `0.20.0` produce the
identical error under the same conditions. The same-day Renovate automerges
(#111 `beszel` → 0.20.0, #112 `beszel-agent` → 0.20.0, both at 04:46 UTC on
2026-09-21) are a red herring; the hub has been down since the first
`materia-update` after `7a33daa` landed on 2026-09-17.

### Reproduction (local rootless podman, no host access needed)

```
podman volume create bz-repro
podman run --rm -d --name bz -v bz-repro:/beszel_data -p 18090:8090 \
  docker.io/henrygd/beszel:0.19.0      # root run, as production had been
curl -o /dev/null -w '%{http_code}\n' localhost:18090/api/health   # 200
podman stop bz

podman run --rm --user 1000:1000 -v bz-repro:/beszel_data \
  docker.io/henrygd/beszel:0.20.0
# -> attempt to write a readonly database (1544), immediate exit

podman unshare chown -R 1000:1000 "$(podman volume inspect bz-repro \
  --format '{{.Mountpoint}}')"
podman run --rm -d --user 1000:1000 -v bz-repro:/beszel_data -p 18091:8090 \
  docker.io/henrygd/beszel:0.20.0
curl -o /dev/null -w '%{http_code}\n' localhost:18091/api/health   # 200
```

The #26 plan's local verification passed only because it used a **fresh,
empty** volume — the greenfield path podman does chown. No local test of a
greenfield volume can catch this class of bug; the differentiator is
pre-existing data.

## Secondary defect found while diagnosing

`beszel-agent`'s `User=1000` breaks issue #32's container stats. The mount
`/run/podman/podman.sock` is the **rootful** socket, and `podman.socket`
ships `SocketMode=0660` with no `SocketUser=`/`SocketGroup=`, i.e.
`root:root 0660`. A UID-1000 agent gets EACCES on connect. The agent fails
*soft* — it stays `active (running)` and keeps reporting host metrics, just
with zero container stats — so there is no failed unit and no obvious
symptom, only the silent regression of #32. This is precisely the residual
risk `specs/plans/issue-26-beszel-uid1000.md` flagged as unverifiable from
the workstation.

## Fix

Repo revert of #26 (`beszel-hub.container.gotmpl`, `beszel-data.volume`,
`beszel-agent.container.gotmpl` back to root), because the fleet is
GitOps-pull and a repo change is the only remedy that needs no shell on
flutterina — SSH to the host is filtered from the current network, and the
hub's data must not be wiped (PocketBase DB holds users, systems, alert
rules, and metric history).

The alternative — keep `User=1000` and run
`sudo podman unshare chown -R 1000:1000 "$(sudo podman volume inspect \
systemd-beszel-data --format '{{.Mountpoint}}')"` on flutterina, then
`systemctl restart beszel-hub.service` — is the correct way to *re-attempt*
#26 later: do the chown first, land the commit second. Doing the chown now
is harmless either way (a root-run container writes fine to a 1000-owned
directory).

## Verification

- Local repro above: root-run healthy, UID-1000-on-root-owned-data fails
  with the exact production-consistent error, chown + UID 1000 healthy.
- Post-deploy (pending): after the next `materia-update` on flutterina,
  `beszel.<baseDomain>/api/health` returns `200` and
  `beszel-hub.service` is `active (running)` without restart churn. Force
  it sooner with `sudo systemctl start materia-update.service` on the host.
- Then re-check #24's Pangolin health check + alert rule — a 4-day hub
  outage should not have gone unannounced.

## Prevention

Two AGENTS.md gotchas added: (1) switching an already-deployed component to
non-root needs a host-side chown of the existing volume first, and the
greenfield case silently passes; (2) non-root containers cannot read the
rootful podman socket (`0660 root:root`).
