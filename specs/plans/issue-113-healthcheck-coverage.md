# Implementation Plan — Issue #113: podman healthcheck coverage

**issue:** https://github.com/kitten-lily/materia/issues/113
**risk:** P2 (adds observability; the only behavioural risk is a probe that
wrongly reports unhealthy, or — where `Notify=healthy` is used — a bad probe
turning into a start-up hang)

## Scope of this stage (stage 1 of 5)

flutterina only, and only the containers that need **no** prerequisite config
change:

| container | change |
|---|---|
| `gerbil` | `HealthCmd=wget -q -O /dev/null http://127.0.0.1:3003/healthz` (busybox wget; `/healthz` probed live → 200) |
| `beszel-hub` | `HealthCmd=["/beszel","health","--url","http://localhost:8090"]` — JSON-array direct-exec form, mandatory: the image is FROM scratch with no `/bin/sh` |
| `newt` | `Environment=HEALTH_FILE=/tmp/newt-health` + `HealthCmd=test -f /tmp/newt-health` |
| `app` | add `HealthStartPeriod=30s` only |

Deferred to later stages: traefik (needs a `ping:` block in
`traefik_config.yml.gotmpl` first — stage 2), all bow containers (stage 3),
AGENTS.md documentation (stage 4), bb-storage/bb-asset non-coverability note
(stage 5). See the issue for the full per-container table and evidence.

## Design decisions

- **No `HealthOnFailure=`** anywhere in this stage. The default (`none`)
  reports an unhealthy container without acting on it, which is what feeds
  beszel's container-health alerts (henrygd/beszel#2225; the agent reads
  podman health via `getPodmanContainerHealth`). `kill` — which would make
  a wedged-but-alive container self-heal through the existing
  `Restart=always` — is a behaviour change worth deciding separately, and
  it must never be set on `newt` (an edge outage would become a restart
  loop).
- **No new `Notify=healthy`.** Nothing on flutterina orders itself after
  gerbil, newt or beszel-hub; `app` already has it.
- **`newt` uses the health file, not the metrics server.** The alternative
  (`NEWT_METRICS_PROMETHEUS_ENABLED=true` + scraping
  `newt_websocket_connected` off 127.0.0.1:2112) needs a new listener and a
  label-sensitive grep. The health file is first-class: `newt/ping.go`
  writes `ok` when the tunnel ping to the Pangolin server succeeds
  (lines 170/207/321) and **removes** the file when the connection is lost
  (line 297), so `test -f` tracks real tunnel state rather than process
  liveness. Env var name is bare `HEALTH_FILE` (`newtconfig.go:455`), not
  `NEWT_HEALTH_FILE`.
- **`app` keeps `HealthInterval=3s`.** Upstream ships 10s, and 3s means
  ~300 curl execs during a long cold migration — but the 3s interval is
  what keeps `Notify=healthy` boot-gating tight, and the exec is cheap.
  Only `HealthStartPeriod=30s` is added, so expected start-up failures stop
  counting as real failures.
- **Timings** follow the "cheap probe, slow to condemn" shape already used
  by `mediamanager-postgres`: 30s interval, 3 retries, 5-10s timeout, with
  a start period sized to the app's real cold start.

## Verification

Live on flutterina after `materia-update`:
1. `systemctl is-active` for all four services.
2. `podman inspect <c> --format '{{.State.Health.Status}}'` → `healthy` for
   gerbil, newt, beszel-hub, app.
3. `podman healthcheck run <c>; echo $?` → 0 for each, to prove the probe
   itself (not just a cached status) passes.
4. `https://beszel.<baseDomain>/api/health` still 200 (hub restart is a
   side effect of the quadlet change).

Pre-deploy, already proven locally (see issue #113):
- JSON-array direct exec works on a shell-less image (real
  `henrygd/beszel:0.20.0`): `test=[CMD /beszel health --url
  http://localhost:8090]`, first probe `rc=1 connection refused`, then
  `rc=0 out=ok` → `healthy`.
- `/healthz` on gerbil returns 200 and the other candidate paths 404
  (probed on the live container).
- `newt --help` on the live container lists `-health-file`.

## Out of scope

- `beszel-agent`: no meaningful probe exists. `/agent health` is a
  tautology on Linux — `agent/health/health.go` creates
  `/dev/shm/beszel_health` at package init, before `Check()` stats it.
- `restic-backup`: oneshot/timer-driven; liveness is meaningless and
  healthchecks.io already covers it.
