# Implementation Plan — Issue #32: beszel container-level stats

**issue:** https://github.com/kitten-lily/materia/issues/32
**risk:** P3 (monitoring visibility only; no change to what's monitored,
no data path affecting production traffic)

## Summary

Local test (this session) with a real hub/agent pairing (beszel 0.19.0,
real KEY/TOKEN, two dummy containers) narrowed the "no container stats"
gap to issue #32's own hypothesis #3: a missing config flag, not a
version gap or Docker-socket-path mismatch. `DOCKER_HOST` must be set
explicitly to the podman socket path — it is never auto-detected for
Podman (confirmed against `beszel.dev/guide/podman`: "either the Podman
API or the Docker API, not both at the same time"). With it set, the
hub's `/containers` page populated correctly (CPU/memory/net/health/
image/status per container). Without it, the agent gives zero log
output either way — a silent gap, which is why #23's original rollout
never surfaced it.

Findings posted: https://github.com/kitten-lily/materia/issues/32#issuecomment-5712621333

## Design

Add one line to `components/beszel-agent/beszel-agent.container.gotmpl`:

```
Environment=DOCKER_HOST=unix:///run/podman/podman.sock
```

The socket is already mounted at exactly that path
(`Volume=/run/podman/podman.sock:/run/podman/podman.sock:ro`, added in
#23), so no new mount or secret is needed — purely an agent-side
config flag telling it where to look.

## Steps

1. Edit `beszel-agent.container.gotmpl` (done).
2. Preflight: `mise clean && mise ign --server-name flutterina`.
3. Commit as a single `feat:` commit.
4. Push; next `materia-update` on flutterina applies it (the
   `.container.gotmpl` change restarts `beszel-agent.service` by
   default — no `NoRestart` on this component).
5. Post-deploy: confirm the hub's Containers page on flutterina shows
   real production containers (pangolin pod, beszel-hub, beszel-agent
   itself, etc.), then close #32.

## Out of scope

- Quadlet/systemd unit health correlation (#32's "should quadlet state
  be correlated" open question) — not addressed here, container-level
  stats only.
- Volume disk usage per component — separate open question in #32, not
  addressed by this change.
