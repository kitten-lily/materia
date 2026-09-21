# BUG-009 — restarting `app.service` drains `pangolin.pod`: total edge outage

**status:** fixed (verified live on flutterina 2026-09-21 10:05 UTC)
**found:** 2026-09-21, during the #113 stage-1 healthcheck rollout
**severity:** P0 (every public resource on flutterina unreachable —
connection refused, not 503 — until `pangolin-pod.service` was started by
hand)
**epic:** pangolin (surfaced by issue #113)

## Symptom

A `materia-update` that touched `app.container` and `gerbil.container`
(adding healthchecks) ended with:

```
2026/09/21 09:36:16 FATA error applying service change for app.service: finished with status: dependency
```

and left:

```
app.service      failed
gerbil.service   inactive
traefik.service  failed
pangolin-pod     stopped (infra container gone)
```

Externally, `pangolin.<baseDomain>` and every other hostname stopped
answering entirely (`curl` exit 7 / HTTP `000`) — not the `503 no available
server` of a dead backend, because Traefik itself was gone along with the
pod's published ports. `newt` and `beszel-hub` (standalone containers) were
unaffected and stayed healthy, which is what localised the fault to the pod.

## Root cause

Quadlet creates pods with `--exit-policy stop` **by default**
(`podman-systemd.unit(5)`: "Set the exit policy of the pod when the last
container exits. Default for quadlets is stop."). Confirmed on the host:

```
ExecStartPre=/usr/bin/podman pod create ... --exit-policy stop ... --name pangolin
```

`gerbil.service` and `traefik.service` both declare `Requires=app.service`,
and systemd propagates a stop to units that `Requires=` the unit being
restarted. So restarting **app** stops all three, and the journal shows the
full sequence:

```
09:36:04.706  Stopping gerbil.service
09:36:04.710  Stopping traefik.service
09:36:14.95   Stopped gerbil / traefik
09:36:14.959  Stopping app.service
09:36:15.69   pod stop ... name=pangolin        ← last member gone → exit policy fires
09:36:16.05   container died ... name=pangolin-infra
09:36:16      app.service: Bound to unit pangolin-pod.service, but unit isn't active
              Dependency failed for app.service
```

`app.service` has `BindsTo=pangolin-pod.service`, so once the pod service
went inactive the restart could not proceed, and gerbil/traefik failed
behind it.

This is a latent trap in the component, not something the healthcheck
change introduced: **any** restart of `app.service` can drain the pod — i.e.
every Renovate bump of `app.container`'s image digest was rolling this dice.
AGENTS.md's "Pod restart safety" note claimed the opposite ("Materia
restarts only the service whose resource changed. The pod's infra container
keeps the namespace alive during individual container restarts"), which is
wrong precisely because of the `Requires=app.service` fan-out.

### Reproduction (local, no host needed)

```
podman pod create --name ep-test --exit-policy=stop
podman run -d --rm --pod ep-test --name ep-c1 alpine sleep 300
podman stop ep-c1
podman pod inspect ep-test --format '{{.State}}'   # → Exited

# same with --exit-policy=continue → Running
```

## Fix

`ExitPolicy=continue` in `components/pangolin/pangolin.pod`'s `[Pod]`
section (commit `1ce9be7`). The infra container — and therefore the shared
network namespace and all published ports — now survives every member
restart.

Immediate recovery of the live outage was `sudo systemctl start
pangolin-pod.service` followed by `app`, `gerbil`, `traefik`.

## Verification

- Host, after `materia-update` applied the change:
  `podman pod inspect pangolin` → `state=Running exitPolicy=continue`,
  `materia-update` exit 0.
- **The exact failing scenario, re-run deliberately:** `systemctl restart
  app.service` → `restart_rc=0`, `pod_state=Running` immediately and 25s
  later, with `app`/`gerbil`/`traefik` all `active` and `app`/`gerbil`
  `healthy`. Before the fix this same command is what took the edge down.
- Public: `pangolin.<baseDomain>` 200, `beszel.<baseDomain>/api/health`
  200, `music.<baseDomain>` 200, `jellyfin.<baseDomain>` 302 (SSO redirect
  = reachable). bow's tunnelled resources briefly 502 while newt
  re-established after the pod restart, then recovered on their own.

## Prevention

- AGENTS.md's "Pod restart safety" bullet corrected — it asserted a
  safety property the component did not have.
- Any future pod in this repo must set `ExitPolicy=continue` unless the
  pod is genuinely meant to disappear with its workload.
