# Provisioning and Flatcar

Read this guide when rendering Ignition, provisioning or adopting hosts, or changing nftables, LVM, USB, or sysupdate.

- **Flatcar pure-podman: sysext symlinks, not service masking.** Docker and
  containerd are opt-out sysexts. The `-docker`/`-containerd` syntax in
  `enabled-sysext.conf` doesn't work (flatcar/Flatcar#1481). Instead, symlink
  `/etc/extensions/docker-flatcar.raw` and `containerd-flatcar.raw` to
  `/dev/null` — this removes the entire extension (binaries + units) so no
  service masking is needed.

- **A unit that starts on hotplug: install it with materia, enable it
  outside materia.** `usb-drive-unlock.service` (#86) has
  `WantedBy=dev-disk-by\x2dlabel-usbbackup.device`, so plugging the drive
  in starts it. materia must never start it or health-check it: a failed
  check while the drive is absent would fail `materia-update` for every
  component on the host. Units *not* listed in `[[Services]]` get
  exactly that treatment on every version checked (v0.7.0, v0.8.0):
  installed, daemon-reloaded, never enabled, started, stopped or
  checked. `mise usb-drive:enroll` runs the one-time
  `systemctl enable`, which also reloads systemd. On v0.7.1+ the
  declarative alternative is `Static` + `Stopped` + `Oneshot`, but
  materia enables *after* its only daemon-reload, so it would still need
  an extra reload.

  Templates have no string-replace function, so a UUID can't be turned
  into the `\x2d`-escaped device unit name. Match the drive by a
  dash-free LUKS2 label instead (`cryptsetup config --label`); udev
  creates `by-label` links for `crypto` devices too.

  **A device unit's `Wants=` covers hotplug only, not a device present
  at boot.** After the 2026-11-06 reboot, bow's drive was found **in the
  initrd** (`sdb` at 4.7 s, journal hostname `localhost`). Its device unit
  ended up `plugged` with `Wants=usb-drive-unlock.service`, yet nothing
  even tried to start the unit (no journal entries). [INFERENCE] The device
  was already plugged when the real root took over, so there was no
  dead→plugged transition to start its `Wants=`; a replug does produce one.
  Fix: `usb-drive-boot.service`, `WantedBy=multi-user.target` with
  `ConditionPathExists=/dev/disk/by-label/usbbackup`, runs
  `systemctl --no-block start usb-drive-unlock.service`. Don't add
  `WantedBy=multi-user.target` to a unit that has `BindsTo=` on a device:
  every boot without the drive would wait 90 s for the device and leave a
  failed unit.

  **A mount pulled in by a service must carry `Options=nofail`.** A
  `.mount` unit otherwise gets an implicit `Before=local-fs.target`, and
  the service it is ordered after has the default `After=sysinit.target`.
  With the drive attached at boot that is a cycle, and systemd resolves it
  by deleting boot jobs, `local-fs.target` among them.
  `systemd-analyze verify` on the two unit files shows it locally before
  any deploy.

  Keys for such drives: a TPM2 token with **no PCRs**
  (`--tpm2-pcrs=`). On Flatcar, PCR 7 changes with shim SBAT and dbx
  updates, and with Secure Boot off it protects almost nothing. Never
  bind-mount `/mnt/usb` into a container: an absent drive makes podman
  fail the container (BUG-005 class) and blocks `materia-update` on the
  whole host.

- **nftables.service ships with a `ConditionPathExists=` on its rules
  file, and the exact path depends on the Flatcar/nftables version.** The
  base unit gates its own startup on the rules file existing — a dropin
  that redirects `ExecStart=` to a custom path is not enough: the
  condition is evaluated *before* the dropin's `ExecStart` would run, so
  if the expected file doesn't exist, systemd skips the entire service
  (`Active: inactive (dead)`, `Condition: start condition unmet`) and the
  dropin never executes. The path itself varies by version: older
  nftables builds check `/etc/nftables.conf`, newer builds (Flatcar
  4593+, nftables 1.1.x) check `/etc/nftables/rules/main.nft` and
  `ExecStart` uses `nft 'flush ruleset; include
  "/etc/nftables/rules/main.nft"'` (an include, not `nft -f`). Fix:
  write the rules to the exact path the base unit's condition checks
  (`systemctl cat nftables.service` on the target to confirm) and drop
  the `ExecStart` dropin — the base unit already loads the rules at boot.
  If the unit uses `include` (not `nft -f`), omit `flush ruleset` from
  the rules file — the service flushes before including. Confirmed on
  `bow` (bare-metal, Flatcar 4593.2.4, issue #9): the first implementation
  used a dropin redirecting to `/etc/nftables.d/closed.conf`; the second
  wrote to `/etc/nftables.conf` (the path older Flatcar versions use) —
  both left the condition unmet and `nftables.service` was skipped on
  every boot with no error. The closed-posture firewall never applied.
- **A closed nftables posture must allow podman container traffic in
  BOTH the `forward` AND `input` chains.** Podman containers route
  outbound traffic through the `forward` chain (NAT'd by podman), not
  the `output` chain — so `forward policy drop` with no accept rules
  breaks all container networking (image pulls, tunnel connections,
  DNS). Additionally, container DNS queries to the podman bridge gateway
  arrive on the host's bridge interface → `input` chain, not `forward`
  — so `input policy drop` without a DNS exception causes `lookup: i/o
  timeout` on every hostname resolution from a container. **Match by
  subnet, not interface name** — the podman bridge interface name varies
  by version (`cni-podman0`, `podman0`, `podman1`, etc.); subnets are
  stable. Flutterina (Hetzner) has no nftables, so this only affects
  bare-metal.
- **"The" podman bridge subnet is not one subnet — the default bridge
  and every named network each get their own, from different pools.**
  The nftables fix above originally hardcoded a single subnet
  (`10.89.0.0/24`), discovered by inspecting `bow`'s routing table and
  assumed to be "the podman default bridge subnet." It wasn't: confirmed
  via `podman network inspect podman` that the actual **default** bridge
  (network name `podman`, interface `podman0`, used by any container with
  no explicit `Network=`) is hardcoded to **`10.88.0.0/16`**.
  `10.89.0.0/24` (interface `podman1`) belonged to `newt-net` — a *named*
  network, which draws from a separate default pool that starts at
  `10.89.0.0/24` and increments per network created
  (containers-common's `default_subnet_pools`). Because `newt` happened
  to be the network under test, the fix looked complete (newt's traffic
  passed) while silently leaving the default bridge uncovered. Confirmed
  broken on `bow` (issue #34, found while investigating #31):
  `restic-backup` runs on the default bridge with no `Network=` override,
  so every DNS query, SSH connection, and healthchecks.io ping from that
  container was dropped by the `input`/`forward` chains' default-drop
  policy on every single run, while `newt` worked fine the whole time.
  Fix: match a set covering both allocation ranges —
  `ip saddr { 10.88.0.0/16, 10.89.0.0/16 } udp dport 53 accept` (and the
  `forward` chain's `ip saddr { 10.88.0.0/16, 10.89.0.0/16 } accept`) —
  `10.88.0.0/16` for the default bridge, `10.89.0.0/16` (not just the one
  `/24` in use today) for every named network's auto-allocated block, so
  adding another named network later doesn't need another nftables edit.
  Any new component that creates its own named podman network on
  bare-metal should double check its subnet falls inside `10.89.0.0/16`
  (podman's default pool) before assuming this nftables rule already
  covers it — an explicit `subnet=` on a `.network` quadlet could still
  fall outside it.
  **Butane changes don't reach a running host** (see below) — this fix
  needs a hand-edit of `/etc/nftables/rules/main.nft` +
  `systemctl restart nftables` on any bare-metal box provisioned before
  this fix landed, not just a repo commit.
- **LVM setup-script idempotency must be per-stage, not one big guard.**
  The first `bare-metal.bu` LVM script guarded the entire body with `if
  vgdisplay vg_data; then echo "nothing to do"; exit 0; fi`. A previous
  partial run (VG created, then `lvcreate` failed or was interrupted)
  left `vg_data` present with **0 LVs** — and every subsequent re-run
  exited early at the guard, so `lv_data` was never created, no
  filesystem, no mount, no fstab entry. The `lvm-data.service` marker
  file (`/etc/lvm-data.applied`, touched by `ExecStartPost`) made it
  worse: once touched, the `ConditionPathExists=!/etc/lvm-data.applied`
  gate prevents the service from even *trying* to run again. Confirmed
  on `bow` (bare-metal, issue #9): `lvm-data.service` showed `active
  (exited)`, status=0/SUCCESS, log said "vg_data already present,
  nothing to do" — but `sudo lvs vg_data` returned nothing and
  `/var/lib/materia-data` didn't exist. Fix: the script now guards each
  stage independently (VG → LV → mkfs → fstab), so a partial run
  resumes from where it left off. To recover a box in this state without
  a re-provision: remove the marker (`sudo rm /etc/lvm-data.applied`),
  re-run the script (`sudo /opt/lvm/setup-data-vg.sh`), then `sudo
  systemctl restart lvm-data.service` (or just reboot). The script is
  safe to run repeatedly.

- **Adopting an already-running host (no Ignition).** materia's daemon is
  just a podman quadlet + systemd timer — nothing about it requires
  Flatcar/Ignition, only podman + systemd + the same four files Ignition
  would otherwise write (`/etc/materia/config.toml`, `/etc/materia/key.txt`,
  `materia-update.container`, `materia-update.timer`). `server:new --type
  adopted` + `server:adopt-render` render them locally for manual
  `scp`+SSH install instead of baking them into a first-boot Ignition
  config. Used for `krytis-build` (issue #99; Contabo, decommissioned
  2026-10) and its replacement `krytis-runner` (#144) — the krytis repo's
  self-hosted CI runner VPS (registered there under the `krytis-vps`
  GitHub Actions label), a pre-existing, already-in-service host that can
  never be wiped and reprovisioned the way `bow`/`flutterina` were. The
  server name is the box's real OS hostname (`krytis-runner`), not the
  GitHub Actions runner label — required, not just convention, since
  materia matches `MANIFEST.toml`'s `Hosts.<name>` against its
  `materia.hostname` fact. Sequencing still matters: land the host +
  `Components = []` first, populate `attributes/<name>.yml`, *then* wire
  the real `Components` list — same "map has no entry for key"
  fatal-abort risk as any other new component. The `baseDomain` failure
  is one example. [Materia behaviour](materia-behaviour.md)

  **Three prerequisites Ignition
  normally handles silently, confirmed missing on the krytis-build
  rollout — `server:adopt-render`'s output now prints all three:**
  (1) the box's OS hostname must be set to the server name by hand
  (`hostnamectl set-hostname <name>`) — a stock cloud image's default
  hostname (e.g. `vmi1234567`) makes materia silently find no matching
  `Hosts.<name>` and do nothing, no error, "Nothing to do" in the log
  looking exactly like a healthy no-op run; if the box runs cloud-init,
  also drop a `preserve_hostname: true` override
  (`/etc/cloud/cloud.cfg.d/`) or the next reboot resets it from instance
  metadata; (2) `podman.socket` must be enabled by hand
  (`systemctl enable --now podman.socket`) — Flatcar hosts get this from
  Ignition's `enable-podman-socket.service` oneshot, which doesn't exist
  on an adopted non-Flatcar host, and without it the materia-update
  quadlet fails with `statfs /run/podman/podman.sock: no such file or
  directory`; (3) `/var/lib/materia` must exist before the first run
  (`mkdir -p /var/lib/materia`) — it's a bind-mount source, and podman
  does not auto-create missing bind-mount source directories the way it
  does named volumes, failing with `statfs /var/lib/materia: no such
  file or directory` otherwise. A fourth gap, which `server:adopt-render`
  does not print: the healthchecks.io check for the new slug does not
  exist yet, so the unit's pings get `curl: (22) ... 404` in
  the journal and the unit still succeeds (they are `-` prefixed). Nothing
  watches the new host until the check is created. Create it once with
  `curl "$(fnox get HC_PING_URL)/materia-update-<name>?create=1"`, then set
  its grace to ~6 h in the UI. Found on `krytis-runner` (#144).

- **`systemd-sysupdate-reboot.timer` is masked on every Flatcar host —
  it can only ever fail, and it squats in `systemctl --failed`.**
  Flatcar enables the timer by default but ships one placeholder
  transfer definition, `/usr/lib/sysupdate.d/noop.transfer`, whose
  `MatchPattern=invalid@v.raw` can never match, so stock systemd's
  `systemd-sysupdate reboot` exits 1 (`Couldn't find any suitable
  installed versions.`) at ~04:10 every day — deterministically, on a
  box with no sysupdate transfers of its own. Flatcar's real updater is
  `update-engine.service`/`locksmithd.service`, and
  `systemd-sysupdate.service` itself is green (that half was fixed by
  the shipped noop transfer), so nothing is lost by masking. The cost
  of leaving it was real: a permanently non-empty `--failed` is a
  broken smoke detector — it trains you to ignore the one place a real
  failure shows. Both `.bu` templates now carry
  `- name: systemd-sysupdate-reboot.timer` / `mask: true` (masked, not
  disabled, so a systemd preset run can't re-enable it), and
  `flutterina` + `bow` were masked by hand on 2026-09-27 since Butane
  changes never reach a running host. Clearing the leftover state needs
  `systemctl reset-failed` *for the timer as well* — `mask --now` on a
  live timer leaves the timer unit itself failed. Unmask if this fleet
  ever adopts sysext-bakery images that want reboot coordination.
  Upstream: flatcar/Flatcar#1979 (open), fix pending in
  systemd/systemd#42750.

## Butane and Ignition

Every server except the adopted `krytis-runner` (see the adoption gotcha above) is
provisioned via Butane → Ignition on Flatcar, rendered from one of two
templates in `provisioning/templates/` based on
`provisioning/servers/<name>/server.toml`'s `type`. The `.bu` carries only
OS-level setup + materia installation — no reconciler scripts, no seed-secrets
service, no GitHub App credentials (materia replaces all of those).

### What every template installs

- **Explicit hostname** — `/etc/hostname` is set to `${SERVER_NAME}` at
  transpile time. Hetzner Cloud's Flatcar image also sets the guest hostname
  from the Hetzner server name via its metadata service, but that happens
  after Ignition and only on Hetzner — this write removes the dependency on
  that timing and gives bare-metal (no metadata service) the same guarantee.
  This is what makes the multi-server model's unified identity hold:
  materia matches `MANIFEST.toml`'s `Hosts.<name>` against its
  `materia.hostname` fact. That fact is the config's `hostname` override if
  set (no host sets one), else the OS hostname inside the materia container,
  which the quadlet pins with `HostName=${SERVER_NAME}`. Templates name the
  host with `m_facts "host.hostname"`, the same OS hostname. v0.8 still
  accepts the deprecated bare `m_facts "hostname"` but logs a warning for
  it; the templates switched once every host ran v0.8.
- **Pure-podman sysext** — `podman` enabled in `enabled-sysext.conf`; Docker and
  containerd disabled via `/dev/null` symlinks on their `.raw` sysext files (the
  `-docker` syntax in `enabled-sysext.conf` doesn't work — flatcar/Flatcar#1481).
  No service masking needed — the sysext units don't exist if the extension is
  removed. Podman's socket needs a oneshot workaround unit
  (`enable-podman-socket.service`) since Ignition's `enabled: true` on
  `podman.socket` is silently ignored — the sysext isn't loaded yet when
  Ignition processes systemd units.
- **`/etc/containers/policy.json`** — Flatcar doesn't ship one; every
  `podman pull` fails without it.
- **Age private key** → `/etc/materia/key.txt` — for SOPS vault decryption
  (`SOPS_AGE_KEY_FILE` points the materia quadlet at it).
- **Materia config** → `/etc/materia/config.toml` — source URL + SOPS engine.
- **Materia quadlet** — `materia-update.container` + `materia-update.timer`
  inlined in the .bu. Runs materia rootful containerized, pulls the repo,
  decrypts the vault, installs quadlets/configs, manages podman secrets,
  restarts services. Timer fires ~2min after boot (so a fresh server
  converges immediately) and daily thereafter; for faster syncs, trigger
  externally.
  The service pings a healthchecks.io-style check (slug
  `materia-update-<server>`, base URL substituted at transpile time via
  `${HC_PING_URL}` from Proton Pass) on start and on success/failure, so a
  silently-failing or stopped timer gets noticed. Ping failures never block
  the update (systemd `-` prefix). Size the check for the daily cadence
  (period 1 day, grace ~6 h) — boot-time runs add extra, harmless ping cycles.
- **SSH key** for `core` user — baked from Proton Pass (same key across every
  server today, in the shared trust domain described below).

`provisioning/templates/hetzner.bu` additionally sets a low-traffic reboot
window and loads the WireGuard kernel module (for Gerbil) — both specific to
the current single-Hetzner-VPS edge role, kept as-is rather than generalized
further. `provisioning/templates/bare-metal.bu` additionally sets up an LVM
data volume and a closed-inbound nftables posture (SSH allowed for remote
admin — no cloud console fallback on bare metal) — see
`provisioning/BARE-METAL.md`.

### Butane changes don't reach a running host

Ignition runs once, at first boot. Committing a change to a template (e.g.
the materia quadlet's env vars) does nothing to an already-provisioned
server — the host keeps running the config it was born with. Either rebuild
the server (`mise hz:rebuild --server-name <name>`) or hand-edit the target
file on the host (e.g. `/etc/containers/systemd/materia-update.container` +
`systemctl daemon-reload`) and mirror the change in the template for the
next provision.

### Transpile flow

1. `mise ign --server-name <name>` — reads `provisioning/servers/<name>/server.toml`
   to pick the template, fetches the age private key + SSH pubkey from Proton
   Pass via fnox, detects `REPO_URL` from git origin, substitutes placeholders,
   runs `butane --strict`, emits `provisioning/servers/<name>/materia.ign`.
   Treat the `.ign` as secret — never commit (already gitignored via `*.ign`).
2. `mise hz:upload-image` — one-time Flatcar snapshot upload to Hetzner
   (Hetzner servers only; server-agnostic, no `--server-name` needed).
3. `mise hz:create --server-name <name>` — creates the server; Hetzner passes
   the `.ign` as `user_data` to Flatcar at first boot. Reads the Hetzner
   server type/location from `server.toml` unless overridden with
   `--server-type`/`--server-location`.

Bare-metal servers use a different delivery path (iPXE, not `user_data`) —
see the [bare-metal runbook](../../provisioning/BARE-METAL.md).

### Hetzner tasks

All `hz:*` tasks use the `hcloud` CLI (not raw HTTP), fetch `HCLOUD_TOKEN`
with `fnox get` (exported, so nested `mise hz:*` calls reuse it), and
require `--server-name` explicitly — there is no global server-name env
var or default.

| Task | Description |
|---|---|
| `mise hz:upload-image` | Upload Flatcar image as a Hetzner snapshot |
| `mise hz:ensure-image` | Ensure a fresh snapshot exists (refreshes if stale) |
| `mise hz:create` | Create server from snapshot + Ignition |
| `mise hz:delete` | Delete server (`--confirm` required) |
| `mise hz:rebuild` | Rebuild server in-place with latest snapshot + Ignition |
| `mise hz:ssh` | SSH into server as `core@<ip>`: tailnet IP when it is an online peer, else public IP (flutterina has no public tcp/22) |
| `mise hz:pull-config` | Backup pangolin runtime volumes to a local tarball (before rebuild) |
| `mise hz:push-config` | Restore tarball into pangolin runtime volumes (after rebuild) |
| `mise hz:podman-gateway` | Print a server's podman bridge gateway IP (for Pangolin local-site resource targets pointing at standalone containers like beszel-hub) |

`hz:pull-config`/`hz:push-config` operate on the named podman volumes
(`systemd-pangolin-config`, `systemd-letsencrypt`), not the materia data dir —
templated configs are re-rendered by materia and don't need backup. The
tarball layout mirrors the container's `/app/config` (letsencrypt as a
subdirectory), so backups made by the old pangolin-edge repo's tasks against
`/var/lib/pangolin/config` push straight into a materia host. `push-config`
works before the first `materia-update` run: it pre-creates the volumes with
the quadlet names and the quadlet units reuse them (`--ignore`).

### iPXE tasks (bare-metal delivery)

Bare-metal servers don't get Ignition via cloud `user_data` — they boot
from a USB stick with iPXE, which chain-loads a `boot.ipxe` script from
a temporary HTTP server on the workstation. The `ipxe:*` tasks handle
the USB firmware + HTTP serving. See `provisioning/BARE-METAL.md` for
the full runbook.

| Task | Description |
|---|---|
| `mise ipxe:download` | Download `ipxe.iso` to cache + print manual `dd` instructions |
| `mise ipxe:firmware` | Download `ipxe.iso` + `dd` to a USB stick (interactive `gum choose` pick) |
| `mise ipxe:serve` | Serve `boot.ipxe` + `materia.ign` (or `materia-debug.ign` with `--debug`) via foreground `podman run nginx:alpine` — requires `--server-name` |

`ipxe:serve` discovers the workstation's LAN IP, renders `boot.ipxe`
with that IP baked into `ignition.config.url`, and maps host `IPXE_PORT`
(default 8080) → container 80 (nginx listens on 80, not 8080). It resolves
`provisioning/servers/<name>/materia.ign`, falling back to
`materia-debug.ign` if the real one doesn't exist yet. Override the
Flatcar channel/version via `FLATCAR_CHANNEL`/`FLATCAR_VERSION` env vars.

## Shared trust domain and provisioning design

- **Butane/provisioning:** lives in this repo, one template per
  provisioning type (`provisioning/templates/hetzner.bu`,
  `bare-metal.bu`), rendered per-server into
  `provisioning/servers/<name>/materia.ign`. The .bu carries OS setup +
  materia quadlet + age key. Materia replaces the old reconciler,
  seed-secrets, webhook, and GitHub App credentials entirely.
- **Server secret isolation:** not yet done. `.sops.yaml` has one shared
  age recipient for all `attributes/*.yml`, and `fnox.toml`'s
  `CORE_SSH_PUBKEY`/`AGE_SECRET_KEY` are shared across every server. Fine
  for a small, trusted fleet; revisit (multiple SOPS recipients, per-server
  SSH keys) if that stops being true.

## Resource map

```text
  usb-drive/                     # LUKS2 USB drive, TPM2 auto-unlock + mount at /mnt/usb on hotplug (bow-only, issue #86)
    MANIFEST.toml                # no [[Services]] on purpose: materia installs the units but never touches them (see gotchas)
    usb-drive-unlock.service     # WantedBy= the drive's by-label device unit; systemd-cryptsetup attach, tpm2-device=auto,headless
    usb-drive-boot.service       # WantedBy=multi-user.target; ConditionPathExists on the label, starts the unlock unit for a drive attached at boot
    mnt-usb.mount                # pulled in by the unlock service; Options=nofail (see gotchas)
provisioning/
  templates/
    hetzner.bu                  # Butane template for any Hetzner Cloud server
    bare-metal.bu                # Butane template for any bare-metal server
    bare-metal-debug.bu          # minimal RAM-boot discovery-only variant
  servers/
    flutterina/
      server.toml                # per-server config (type, hetzner/bare_metal settings)
      materia.ign                 # gitignored, rendered by `mise ign`
    krytis-runner/
      server.toml                # type = "adopted" — no hetzner/bare_metal settings
      bootstrap/                  # gitignored, rendered by `mise server:adopt-render`
  storageboxes/
    <box>/
      storagebox.toml             # Storage Box config (type, location, snapshot plan)
      known_hosts                  # keyscanned SSH host keys, source of truth for the restic-backup copy
  ghostty.terminfo.b64          # pre-compiled Ghostty terminfo (base64), shared by both templates
  BARE-METAL.md                 # bare-metal bring-up runbook
  bluefin/fixtures/             # Bluefin pilot (#179) Kubernetes test fixtures (dataplane, PVC checksum), digests pinned
```

See the [Materia state migration notes](materia-behaviour.md) for live image updates and the [Storage Box workflow](restic-backup.md) for backup storage.
