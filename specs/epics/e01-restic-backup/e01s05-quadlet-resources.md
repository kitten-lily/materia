# Story e01s05 — Quadlet resources: .container.gotmpl (Image= pull), .timer

**type:** feat
**risk:** P1
**context:** infra
**epic:** e01-restic-backup
**source:** https://github.com/kitten-lily/materia/issues/2
**blocks_on:** e01s03 (needs the published image digest to pin)

## Context

**Published image digest (from e01s03, run 29161722813, 2026-07-11):**
`ghcr.io/kitten-lily/materia/restic-backup@sha256:dd42ac9516ee12655d475dd44b5d19aaa74bc14ca30321ab069b8613c7c1b97a`

Wire the `restic-backup` component's systemd/Podman resources. Unlike the
original #2 plan (which proposed a `.build` quadlet compiling on-host), this
pulls the CI-built image from GHCR with a pinned digest — the same GitOps
convention as pangolin/traefik. The container is a `Type=oneshot` job
(timer-activated, not long-running), bind-mounts the two backup paths
read-only, mounts the SSH key + `known_hosts` from podman secrets / a data
resource, and sets env vars consumed by the wrapper (e01s04).

## Materia manifest semantics (confirmed against docs)

- `[[Services]] Service = "restic-backup.container"` with `Oneshot = true` →
  Materia does not treat a clean exit as a failure. `Static = true` for the
  `.timer` (quadlet-generated). `Stopped = true` for the build service (not
  applicable here — no `.build`).
- `Secrets = ["resticPassword", "storageBoxSshKey"]` MUST be the first lines
  in the component `MANIFEST.toml`, before `[Defaults]` / `[[Services]]`
  (TOML table-assignment gotcha from ce520f1).
- `{{ secretEnv "resticPassword" "RESTIC_PASSWORD" }}` → env-from-secret.
  `{{ secretMount "storageBoxSshKey "/run/secrets/ssh_key:..." }}` → file mount.
- `{{ m_dataDir "restic-backup" }}` → `/var/lib/materia/components/restic-backup`
  (for the `known_hosts` data resource path).

## Requirements

#### ADDED: .container.gotmpl pulls the published image with a pinned digest

`components/restic-backup/restic-backup.container.gotmpl` sets
`Image=ghcr.io/kitten-lily/materia/restic-backup@sha256:<digest>` where the
digest is the one published by e01s03/#17. No `.build` quadlet. Renovate's
existing quadlet manager (already extended to `.container.gotmpl`) bumps the
digest.

#### ADDED: Type=oneshot, timer-activated, no [Install] WantedBy=

`[Service] Type=oneshot` and `RemainAfterExit=yes` (so the service status is
inspectable after the job exits). No `[Install] WantedBy=` — the service is
timer-activated, not enabled directly. The timer unit (separate resource)
carries `WantedBy=timers.target`.

#### ADDED: Two read-only bind mounts for the backup scope

`Volume=/var/lib/materia/components:/var/lib/materia/components:ro` and
`Volume=/var/lib/containers/storage/volumes:/var/lib/containers/storage/volumes:ro`.
These are host paths, bind-mounted read-only — the container backs up
everything under them generically (no per-component/per-volume enumeration).

#### ADDED: SSH key + known_hosts wired for restic's sftp backend

- `storageBoxSshKey` podman secret → mounted as a file
  (`{{ secretMount "storageBoxSshKey" "/run/secrets/ssh_key" }}`).
- `known_hosts` → a data resource installed to
  `{{ m_dataDir "restic-backup" }}/known_hosts` (e01s08), bind-mounted
  read-only into the container.
- `Environment=RESTIC_REPOSITORY=sftp:...` is NOT set here directly — the
  repository string is an attribute, templated in. But the SSH *options* that
  restic's sftp backend passes to `ssh` must be set so scratch (no `$HOME`)
  works: `Environment=RESTIC_SFTP_ARGS=-o
  UserKnownHostsFile=/run/secrets/known_hosts -o StrictHostKeyChecking=yes -i
  /run/secrets/ssh_key` (restic's sftp backend passes these to `ssh`).

#### ADDED: Env vars consumed by the wrapper (e01s04)

`Environment=` lines for: `RESTIC_REPOSITORY` (templated from attribute),
`HC_PING_URL` (from attribute — reuse the same healthchecks base URL),
`HC_SLUG=restic-backup-{{ m_facts "hostname" }}`, `KEEP_DAILY`,
`KEEP_WEEKLY`, `KEEP_MONTHLY` (templated, with defaults), `BACKUP_PATHS`
(the two bind-mounted paths). `RESTIC_PASSWORD` comes from the podman secret
via `{{ secretEnv "resticPassword" "RESTIC_PASSWORD" }}`.

#### ADDED: .timer resource with attribute-driven schedule

`components/restic-backup/restic-backup.timer` (not `.gotmpl` — systemd timer
files are not templated by Materia unless they end in `.gotmpl`; if the
`OnCalendar=` value needs to be per-host, make it `.timer.gotmpl` and template
`{{ .onCalendar }}`). `OnCalendar=` from an attribute (default daily),
`WantedBy=timers.target`, `Unit=restic-backup.service`.

## Steps

1. Create `components/restic-backup/restic-backup.container.gotmpl` with
   `[Unit] Description=...`, `[Container] Image=ghcr.io/kitten-lily/materia/restic-backup@sha256:<digest-from-e01s03>`,
   `ContainerName=restic-backup`, the two read-only `Volume=` bind mounts,
   the SSH key secret mount, the `known_hosts` bind mount, the `Environment=`
   lines, and `{{ secretEnv "resticPassword" "RESTIC_PASSWORD" }}`.
   → verify: `grep -q 'ghcr.io/kitten-lily/materia/restic-backup' components/restic-backup/restic-backup.container.gotmpl`.

2. Set `[Service] Type=oneshot` + `RemainAfterExit=yes` and NO `[Install]`
   section in the `.container.gotmpl`. → verify: `grep -q 'Type=oneshot' components/restic-backup/restic-backup.container.gotmpl && ! grep -q 'WantedBy=' components/restic-backup/restic-backup.container.gotmpl`.

3. Set `Environment=RESTIC_SFTP_ARGS=-o UserKnownHostsFile=/run/secrets/known_hosts -o StrictHostKeyChecking=yes -i /run/secrets/ssh_key`
   so restic's sftp backend invokes `ssh` with explicit paths (scratch has no
   `$HOME` to write to). → verify: `grep -q 'RESTIC_SFTP_ARGS' components/restic-backup/restic-backup.container.gotmpl`.

4. Create `components/restic-backup/restic-backup.timer.gotmpl` with
   `OnCalendar={{ .onCalendar }}`, `Unit=restic-backup.service`,
   `[Install] WantedBy=timers.target`. (Use `.timer.gotmpl` so the schedule
   is per-host attribute-driven; Materia strips the `.gotmpl` → installs as
   `restic-backup.timer`.) → verify: `grep -q 'OnCalendar' components/restic-backup/restic-backup.timer.gotmpl`.

5. Set the `known_hosts` bind mount:
   `Volume={{ m_dataDir "restic-backup" }}/known_hosts:/run/secrets/known_hosts:ro,Z`.
   (The `known_hosts` data resource itself is e01s08; here we only wire the
   mount.) → verify: `grep -q 'known_hosts' components/restic-backup/restic-backup.container.gotmpl`.

6. Run `materia plan` (if a materia binary is available locally) or a template
   dry-render to confirm the `.gotmpl` files parse and the attribute refs
   resolve. → verify: `materia plan` exits 0, or `grep -c '{{' components/restic-backup/*.gotmpl` shows expected template markers and no syntax errors on a manual render.

## Verification Script (Step-by-Step)

1. `grep -q 'ghcr.io/kitten-lily/materia/restic-backup@sha256:' components/restic-backup/restic-backup.container.gotmpl` — image pinned by digest.
2. `grep -q 'Type=oneshot' components/restic-backup/restic-backup.container.gotmpl` — oneshot service.
3. `! grep -q 'WantedBy=' components/restic-backup/restic-backup.container.gotmpl` — no direct enable (timer-activated).
4. `grep -q 'WantedBy=timers.target' components/restic-backup/restic-backup.timer.gotmpl` — timer enables.
5. Both backup paths are read-only bind mounts: `grep -c ':ro' components/restic-backup/restic-backup.container.gotmpl` ≥ 2.
6. SSH key + known_hosts mounts present: `grep -c 'ssh_key\|known_hosts' components/restic-backup/restic-backup.container.gotmpl` ≥ 2.
7. `materia plan` (if available) validates templating/manifest wiring.

## Out of scope

- The component `MANIFEST.toml` (Secrets, Services, Defaults) — e01s06.
- The `known_hosts` data resource itself — e01s08.
- The repo-level `[Roles.base]` wiring — e01s07.
- The wrapper binary behavior — e01s04.
- The image build — e01s03/#17.

## Risks

- **`TimeoutStartSec` is not available for `Type=oneshot`.** Per Podman
  quadlet docs, `TimeoutStartSec` doesn't apply to oneshot units. A slow
  first-run backup (large initial snapshot) could hit systemd's default
  oneshot timeout. Mitigation: set `TimeoutStartSec=` in the `[Service]`
  section of the `.container.gotmpl` (systemd honors it for the wrapper's
  exec even if quadlet docs warn about it) — or set `TimeoutStopSec=` and
  test. If systemd kills the job, raise it. Detect early in e01s11.
- **`RESTIC_SFTP_ARGS` env name.** Restic's sftp backend reads
  `RESTIC_SFTP_ARGS` (space-separated args passed to `ssh`). Confirm the env
  var name against restic docs during implementation — if it's
  `RESTIC_SSH_ARGS` or similar, adjust. (This is the DISCOVERY MANDATE item
  for this story.)
- **SELinux labels on host bind mounts.** `/var/lib/containers/storage/volumes`
  may need `:z` not `:ro` — test on an enforcing-SELinux host (flutterina is
  Flatcar, permissive by default, so this won't bite immediately but keep
  `:ro,Z` for portability per the repo convention).
- **`known_hosts` port.** The committed `known_hosts` (from
  `provisioning/storageboxes/backup/known_hosts`) has entries for both port 22
  (mod_sftp) and port 23 (OpenSSH). The Storage Box subaccount uses port 23
  for `install-ssh-key`; restic's sftp backend connects on the standard SSH
  port. Confirm which port the repository URL encodes and that `known_hosts`
  has a matching entry. The `resticRepository` attribute in
  `attributes/flutterina.yml` already encodes this — verify during e01s11.
