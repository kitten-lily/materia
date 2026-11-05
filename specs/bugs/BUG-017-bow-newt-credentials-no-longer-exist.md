# BUG-017: bow Newt credentials reference a deleted server record

**Status:** fixed
**Severity:** P1
**Found:** 2026-11-05
**Epic:** newt

## Symptom

The post-#173 bow smoke check found one failed systemd unit: Podman's transient
healthcheck unit for the `newt` container. The container itself is running but
has health status `unhealthy`; its healthcheck failing streak was 2319.

The Newt journal retries every three seconds with:

```text
Failed to get token with status code: 400
message: "No newt found with that newtId"
```

`/tmp/newt-health` is therefore never created and the configured healthcheck
(`test -f /tmp/newt-health`) fails once a minute. `HealthOnFailure` remains
unset as designed, so the container is not restarted into a loop.

## Evidence that #173 did not cause it

- The failing container ID was `77f6…` with main process PID `2808754`; #173's
  v0.8 permission-update plan did not restart `newt.service`.
- A failing streak of 2319 one-minute probes predates the materia upgrade by
  more than a day.
- The error is an application-level Pangolin API rejection of the persisted
  Newt ID, not a materia planner or file-permission error.

## Impact

- Bow's Newt tunnel is down.
- Its healthcheck transient keeps `systemctl --failed` non-empty, weakening the
  host-wide smoke detector.
- Resources already moved to the Tailscale backhaul may be unaffected, but any
  remaining Pangolin target using bow's Newt site cannot work.

## Resolution

Bow no longer needs Newt. All seven bow HTTP applications had already moved to
the flutterina Pangolin site backed by bow's Tailscale gateway; Buildbarn uses
Tailscale Service `svc:bst-cache`. No live HTTP route used the deleted bow site.

The fix removes bow from `[Roles.tunneled]`, which removes its dead Newt
container, consumed config volume, provisioning secret and component resources.
Bow's application containers still require the named `newt-net` network for
container-name resolution, so `components/tailscale-gateway/newt.network` now
owns that resource on bow. Flutterina remains in `[Roles.tunneled]`.

The live cutover completed without `FATA`. Newt and its stale transient
healthcheck are absent; the gateway is healthy; all nine configured forward
targets resolve and accept connections from the gateway; the five unprotected
public application routes return 2xx/3xx, and Media Manager returns its expected
Pangolin-auth 401. A second materia plan reports `No changes made`, and
`systemctl --failed` is empty.
