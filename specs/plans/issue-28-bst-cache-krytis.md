# Issue #28: BuildStream cache server for krytis

## Problem

`starlit-os/krytis` (BuildStream-based OS image project, same shape as
`projectbluefin/dakota`) currently points its `project.conf` `artifacts`/
`source-caches` at two external gRPC CAS servers it doesn't own
(`gbm.gnome.org:11003`, `cache.projectbluefin.io:11001`). Issue #28 asks for
a krytis-owned equivalent.

## Findings (see conversation for full trace)

- A BuildStream cache is a `bst-artifact-server` (buildbox-casd) process: a
  gRPC CAS (Content-Addressable Storage) service doing high-volume small-blob
  random-access reads/writes under CI load — not a bulk/sequential file store.
- Reference deployment (`cache.projectbluefin.io`) runs on a dedicated
  bare-metal box with local NVMe, not network-mounted storage.
- Hetzner Storage Box (SFTP/CIFS/rsync-only) is a poor fit as the *live* CAS
  backing store — same class of problem as mounting a database over sshfs.
  **User confirmed storagebox is not a hard requirement** — drop it as the
  backing store; local disk (podman volume or LVM data-disk bind, per this
  repo's existing pattern) is the right call.

## Decisions (this conversation)

- **Storage:** local disk on whichever host runs it, not the Storage Box.
  On `bow` (bare-metal), that means a bind mount under
  `/var/lib/materia-data/` (same pattern as `grimmory`'s `Books` bind) rather
  than a podman named volume on root storage — CAS data will grow large and
  shouldn't compete with root fs, and named volumes are the wrong pattern for
  this same reason media components already established.
- **Host:** start on `bow` (already has `newt` for tunnel reachability,
  already has an LVM data disk). Explicitly a temporary placement — plan to
  migrate to a dedicated new server entry (multi-server model, `mise
  server:new`) once real usage/load is known. Don't over-invest in
  bow-specific wiring that would block that move.
- **Push auth:** open — no existing pattern in this repo for gRPC mTLS (only
  precedent is Pangolin's app-level auth and Newt's provisioning-key
  exchange, neither of which fit a gRPC CAS server). Proposed approach for
  plan-work to firm up:
  - `bst-artifact-server` supports `--server-key`/`--server-cert` (TLS) and
    `--client-certs` (CA bundle) — pull can stay anonymous, push requires a
    client cert signed by that CA.
  - Generate a small private CA once (age/SOPS-managed like other secrets in
    this repo), issue one client cert for krytis CI (stored as a GitHub
    Actions secret in the krytis repo, out of scope for this repo to manage
    beyond generating it), and mount CA + server cert/key via podman secrets
    (`secretMount`, hand-written `Secret=` line if mode 0400 is needed — see
    BUG-002 gotcha).
  - Server TLS cert needs a real hostname (`bst-cache.<baseDomain>` via Newt
    tunnel, same shape as beszel-hub/grimmory) — Traefik terminates public
    TLS as usual; whether the internal gRPC hop from Traefik to the cache
    container also needs client-cert auth or can rely on Traefik same-pod
    trust is a plan-work detail.

## Open questions for plan-work

1. **Container image** — no known official minimus/upstream OCI image for
   `bst-artifact-server`. Likely needs a custom `images/bst-cache/Dockerfile`
   (same shape as `images/restic-backup/`), built from the `buildstream`
   Python package. Needs a quick spike to confirm feasibility before writing
   the component.
2. **Disk sizing on bow** — how much of the LVM data disk to carve out
   (dakota's `cache: quota: 50G` client-side setting is unrelated to server
   storage size; server needs to hold every architecture's built artifacts
   krytis cares about, likely larger).
3. **Traefik routing** — standalone container on `newt-net` (grimmory/music
   pattern) vs. does gRPC/HTTP2 need any special Traefik config beyond the
   existing dynamic_config template.
4. **CA/cert generation and rotation tooling** — does this get a `mise`
   task (like `hz:storagebox:install-key`) or is it a one-time manual
   `openssl`/`step` step documented in this file.

Next step: spike the image build (#1) before committing to the full
component plan, since that's the biggest unknown.

## Spike result (paused)

Spiked the `bst-artifact-server` image build. Confirmed via PyPI + the wheel
contents (BuildStream 2.7.0):

- `pip install BuildStream` ships prebuilt `manylinux_2_28` wheels
  (cp310-cp314), bundling BuildBox binaries — no static-build pain, unlike
  `restic-backup`'s OpenSSH story.
- BUT the standalone `bst-artifact-server` CLI documented in
  `man/bst-artifact-server.1` (port, `--server-key`, `--server-cert`,
  `--client-certs`, `--enable-push`, `--quota`) **no longer exists as an
  installable entry point**. The wheel's `entry_points.txt` only registers
  `bst`, with no server subcommand. The man page is stale, dated 2020
  (BuildStream 1.x era).
- The real server logic (`buildstream._cas.casserver.create_server()`) is
  fully implemented and does everything the man page describes (TLS,
  push/pull servicers, quota) — but it's an **underscore-prefixed internal
  module**, only used today by BuildStream's own test suite
  (`tests/testutils/artifactshare.py`), not a public/stable API.
- Standing this up would require writing and maintaining a small (~50-100
  line) wrapper script that imports that internal module and reimplements
  the CLI — with no upstream compatibility guarantee across BuildStream
  versions.

**Decision:** paused, not pursuing further right now. Findings posted to
issue #28. Revisit if/when there's appetite for the internal-API
maintenance risk, or if BuildStream reintroduces a public server command.
