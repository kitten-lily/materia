# BUG-017: bow Newt credentials reference a deleted server record

**Status:** open
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

## Decision required

Determine whether bow's Newt site was deliberately deleted during the
Tailscale backhaul migration:

1. If Newt is no longer part of bow's architecture, remove bow from the
   `[Roles.tunneled]` assignment (or otherwise remove only its Newt component)
   and remove any remaining Pangolin resources that target that site.
2. If Newt remains required, create a new provisioning key/site, update the
   vault, remove `newt-config.volume`, and let Newt provision a fresh ID. The
   existing provisioning key cannot repair a consumed/deleted identity.

Do not reset the failed unit alone: the next one-minute healthcheck recreates
it while the credential error persists.
