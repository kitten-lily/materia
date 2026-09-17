# Implementation Plan — Issue #26: `User=1000` for beszel hub + agent

**issue:** https://github.com/kitten-lily/materia/issues/26
**risk:** P3 (hardening only; drop-on-failure was the accepted outcome per
the issue itself — no architecture change, no data migration)

## Summary

Local podman verification (this session, rootless substitute for the
plan's rootful requirement — no sudo on this workstation) confirmed both
official upstream images run cleanly as UID 1000:

- **Hub** (`henrygd/beszel:0.18.7`): started, served `/api/health` 200,
  wrote `/beszel_data` with the volume pre-chowned `1000:1000`. No
  permission errors.
- **Agent** (`henrygd/beszel-agent:0.18.7`): started, stable, no crash
  loop; only the expected "must set TOKEN" warning (no real hub pairing
  tested). No permission errors on the read-only podman socket mount or
  the agent's internal data dir.

Findings posted to the issue: https://github.com/kitten-lily/materia/issues/26#issuecomment-5712356490

## Design

Adopt the `User=1000`/`Group=1000` pattern already used by every minimus
(non-root) component in this repo (`pangolin/letsencrypt.volume`,
`grimmory/*.volume`, `mediamanager/*`):

1. `components/beszel-hub/beszel-hub.container.gotmpl` — add
   `User=1000`/`Group=1000` to `[Container]`.
2. `components/beszel-hub/beszel-data.volume` — add
   `User=1000`/`Group=1000` to `[Volume]` (was previously unset — image
   ran as root). Comment updated to reflect the UID-1000 verification.
3. `components/beszel-agent/beszel-agent.container.gotmpl` — add
   `User=1000`/`Group=1000` to `[Container]`. No `.volume` resource
   exists for the agent (its `/var/lib/beszel-agent` data dir is
   container-layer only, never bind-mounted), so no volume ownership
   change is needed there.

## Residual risk — not locally verifiable

The agent's podman socket mount (`/run/podman/podman.sock:...:ro`) targets
the **rootful** socket in production (materia runs containers rootful).
This session's local test substituted the **rootless** socket
(`$XDG_RUNTIME_DIR/podman/podman.sock`, user-owned, mode 660) because
sudo isn't available on this workstation — that socket is owned by the
invoking user, so it can't reproduce a scenario where UID 1000 lacks
group membership on a root-owned rootful socket. Production's rootful
`/run/podman/podman.sock` ownership/permissions on Flatcar (via the
`enable-podman-socket.service` workaround, see AGENTS.md) are unconfirmed
for UID-1000 readability.

**Mitigation:** this is exactly the class of failure the issue's own
pass/fail criteria calls out ("permission-denied on the podman socket...
is the fail signal that closes #26"). Since it can't be checked before
deploy from here, the concrete follow-up is a live-host check after the
next `materia-update` on flutterina: confirm `beszel-agent.service`
reaches `active (running)` with no `permission denied` on the socket
path in its logs. If it fails there, this is a one-line revert (drop
`User=`/`Group=` from `beszel-agent.container.gotmpl`) — the hub's
result is unaffected either way (its volume ownership is set explicitly,
no shared-socket dependency).

## Steps

1. Edit the three files above (done).
2. Preflight: `mise clean && mise ign --server-name flutterina`.
3. Commit as a single `feat:` commit.
4. Push; next `materia-update` on flutterina applies it (image/volume
   `.container`/`.volume` changes restart their service by default —
   no `NoRestart` on these components).
5. Post-deploy: check `beszel-hub.service`/`beszel-agent.service` status
   and logs on flutterina for the residual socket-permission risk above.
   If clean, close #26. If the agent fails on socket permissions, revert
   just the agent's `User=`/`Group=` lines (hub can stay).

## Out of scope

- Adding a named volume for the agent's `/var/lib/beszel-agent` — not
  requested by the issue, and the current ephemeral (container-layer)
  storage already worked fine as UID 1000 in local testing.
- Any change to `beszel-agent`'s `Network=host` or socket mount path.
