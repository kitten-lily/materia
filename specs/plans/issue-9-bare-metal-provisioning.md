# Implementation Plan — Issue #9: Bare-metal Butane/Ignition/iPXE provisioning

**issue:** https://github.com/kitten-lily/materia/issues/9
**risk:** P2 (adds a second provisioning path; no changes to existing
Hetzner flow; no production server affected until a bare-metal server is
actually provisioned)
**epic:** standalone (follow-up to the multi-server foundation)

## Summary

Port the bare-metal provisioning flow from the sibling `server-provisioning`
repo, generalized away from its k8s-specific context. Four files to create
(`bare-metal.bu`, `bare-metal-debug.bu`, `BARE-METAL.md`, three iPXE mise
tasks) and one to update (`AGENTS.md`). The existing infrastructure
(`mise ign` task, `mise server:new` with `--type bare-metal`) is already
fully wired — it just needs the templates and iPXE tooling to exist.

## What's already done (no work needed)

Investigation confirmed these are **already in place** from the multi-server
foundation work:

- **`.mise/tasks/ign`** — already handles `--type bare-metal`, selects
  `bare-metal.bu` or `bare-metal-debug.bu` based on `--debug`, reads
  `data_disks` from `server.toml`, substitutes `${DATA_DISKS}`, errors
  if `data_disks` is empty without `--debug`. **Fully functional.**
- **`.mise/tasks/server/new`** — already scaffolds `server.toml` with
  `type = "bare-metal"` and `[bare_metal] data_disks = []`, prints
  bare-metal next-steps. **Fully functional.**
- **`mise.toml`** — already mentions `ipxe/*` tasks in the task listing
  comment, and `butane` is already in the toolchain.

## Files to create

### 1. `provisioning/templates/bare-metal.bu`

Built from `hetzner.bu`'s materia/pure-podman baseline (the entire
`storage`/`systemd`/`passwd` structure that sets up: explicit hostname,
pure-podman sysext symlinks, `policy.json`, `enabled-sysext.conf`,
Ghostty terminfo, materia config + age key + materia-update quadlet +
timer, enable-podman-socket oneshot, core user SSH key). Then **add**
two patterns ported from `hosting.bu`, generalized:

**a) LVM data-disk setup** — generalized from the 4-named-LV k8s-specific
script to a single data volume:

- `/opt/lvm/setup-data-vg.sh` — idempotent script that:
  - Guards with `vgdisplay vg_data` (skip if already present)
  - Reads `${DATA_DISKS}` (space-separated, substituted from `server.toml`
    by the `ign` task) as the device list
  - `sgdisk --zap-all` each device, `pvcreate`, `vgcreate vg_data`
  - One `lvcreate -n lv_data -l 100%FREE vg_data` (single LV, not 4)
  - `mkfs.ext4 -F`, `blkid` for UUID, add to `/etc/fstab`, mount at
    `/var/lib/materia-data`
  - Marker file `/etc/lvm-data.applied`
- `lvm-data.service` — oneshot, `ConditionPathExists=!/etc/lvm-data.applied`,
  `ExecStart=/opt/lvm/setup-data-vg.sh`, `ExecStartPost=/usr/bin/touch
  /etc/lvm-data.applied`, `RemainAfterExit=yes`, `WantedBy=multi-user.target`
- Directory `/opt/lvm` (mode 0755) for the script

**b) nftables closed-firewall posture** — ported near-verbatim from
`hosting.bu` (already generic, no k8s-specifics):

- `/etc/nftables.d/closed.conf` — `flush ruleset`, `table inet filter`
  with `input` chain (policy drop, established/lo/icmp accept), `forward`
  chain (policy drop), `output` chain (policy accept)
- `nftables.service` dropin `closed-posture.conf` — overrides `ExecStart=`
  to `ExecStart=/usr/sbin/nft -f /etc/nftables.d/closed.conf`
- Directory `/etc/nftables.d` (mode 0755)

**Removed from `hetzner.bu` baseline** (Hetzner-specific, not applicable
to bare metal):
- `/etc/flatcar/update.conf` reboot window (Hetzner-edge-specific)
- `/etc/modules-load.d/wireguard.conf` (Gerbil-specific to the edge role)

**Substitution placeholders** (same as `hetzner.bu` + one additional):
- `${SERVER_NAME}`, `${REPO_URL}`, `${CORE_SSH_PUBKEY}`,
  `${GHOSTTY_TERMINFO_B64}`, `${HC_PING_URL}` — same as hetzner
- `${DATA_DISKS}` — space-separated device list, substituted from
  `server.toml`'s `bare_metal.data_disks` by the `ign` task

### 2. `provisioning/templates/bare-metal-debug.bu`

Minimal Ignition for a RAM-boot discovery session. Ported near-verbatim
from `hosting-debug.bu`, adapted to use `${CORE_SSH_PUBKEY}` (same
placeholder as the real templates, not the source's `${SSH_PUBKEY}`):

```yaml
variant: flatcar
version: 1.1.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - "${CORE_SSH_PUBKEY}"
```

No `storage`/`systemd` blocks — just enough to boot Flatcar in RAM and
give SSH access for hardware discovery (`lsblk`, `ip link`, etc.). The
`ign` task fetches the age key + SSH pubkey from Proton Pass regardless
(debug template doesn't reference `local: key.txt`, but the fetch is
harmless and the task already does it unconditionally).

### 3. `.mise/tasks/ipxe/download`

Non-interactive: downloads `ipxe.iso` to `$XDG_CACHE_HOME/provisioning/`,
prints instructions for manual `dd` to USB. Ported near-verbatim from
source, generalized wording away from `hosting.ign`-specific references
→ `materia.ign`/`materia-debug.ign`.

### 4. `.mise/tasks/ipxe/firmware`

Interactive: downloads `ipxe.iso`, uses `gum choose` + `lsblk` to pick a
USB device, `dd`s it. Ported near-verbatim from source.

### 5. `.mise/tasks/ipxe/serve`

Adapted from source: replaces the `IGN_FILE_HOSTING`/`IGN_FILE_DEBUG`
env-var pair with a required `--server-name` flag. Resolves
`provisioning/servers/<name>/materia.ign` (falling back to
`materia-debug.ign` if the real one doesn't exist yet). Keeps:
- LAN-IP discovery (`ip -4 route get 1.1.1.1`)
- Rendered `boot.ipxe` with LAN IP baked into `ignition.config.url`
- Foreground `podman run nginx:alpine` serving both files
- Bind to `0.0.0.0` (rootless-podman host-routing workaround)
- Port mapping `PORT:80` (nginx listens on 80, not 8080)
- `--debug` flag to serve `materia-debug.ign` instead of `materia.ign`

The `boot.ipxe` template references `materia.ign` (not `hosting.ign`):
```
ignition.config.url=http://${lan_ip}:${PORT}/materia.ign
```

### 6. `provisioning/BARE-METAL.md`

Condensed runbook adapted from source's `BOOTSTRAP.md` +
`USB-TROUBLESHOOTING.md`, generalized to materia (no k8s steps):

1. **Pre-flight** — hardware checks (Secure Boot off, USB boot enabled),
   workstation setup (`mise install`)
2. **Scaffold** — `mise server:new --server-name <n> --type bare-metal`
3. **Write iPXE firmware** — `mise ipxe:firmware` (interactive USB pick)
   or `mise ipxe:download` (manual dd)
4. **Discovery boot** — `mise ign --server-name <n> --debug` →
   `mise ipxe:serve --server-name <n> --debug` → boot target from USB →
   iPXE prompt: `dhcp` + `chain http://<lan-ip>:8080/boot.ipxe` →
   SSH in → `lsblk -d -o NAME,SIZE,MODEL,TRAN` + `ip link` → note device
   names
5. **Fill server.toml** — write `data_disks = ["/dev/nvme0n1", ...]`
6. **Real ignition** — `mise ign --server-name <n>` →
   `mise ipxe:serve --server-name <n>`
7. **Boot target** — iPXE boots Flatcar in RAM, SSH in, manually run
   `sudo flatcar-install -d <boot-disk> -i <(curl -s http://<lan-ip>:8080/materia.ign)`
   → reboot → verify
8. **Verification** — `systemctl status materia-update.timer`,
   `systemctl status lvm-data.service`, `sudo vgdisplay vg_data`,
   `sudo nft list ruleset`, `ls /var/lib/materia-data`
9. **Troubleshooting** — table of symptoms (iPXE doesn't fetch, LVM
   failed, lost SSH after nftables, USB not bootable)
10. **Future: declarative on-disk provisioning** — flag the gap (manual
    `flatcar-install` is the current path; a fully declarative one-boot
    install via Ignition `storage.disks` + self-installing first-boot
    unit is a known future improvement, not implemented here)

### 7. `AGENTS.md`

Extend the Provisioning section's "Transpile flow" with the bare-metal
path alongside Hetzner Cloud:
- `mise ign --server-name <n>` picks the template from `server.toml`'s
  `type` (hetzner → `hetzner.bu`, bare-metal → `bare-metal.bu`)
- `--debug` flag for bare-metal discovery boot
- iPXE delivery path (not `user_data`): `mise ipxe:firmware` + `mise
  ipxe:serve --server-name <n>`
- Point at `provisioning/BARE-METAL.md` for the full runbook

## Out of scope

- Anything k8s-specific (sysexts, kubeadm, kubelet, sysupdate kubernetes
  configs) — explicitly excluded by the issue
- `gitops/`, `argocd`, `eso`, `newt`, `kubestellar`, `protonpass-webhook`
  — explicitly excluded
- Declarative on-disk provisioning (Ignition `storage.disks` +
  self-installing first-boot unit) — flagged as future improvement in
  both the source repo and this plan
- Renovate coverage for the materia image (`ghcr.io/stryan/materia:stable`
  in the .bu) — separate concern, already noted in AGENTS.md "Decisions
  still open"

## Verification

1. `mise server:new --server-name testbox --type bare-metal` → produces
   `provisioning/servers/testbox/server.toml` with `data_disks = []` and
   a `[Hosts.testbox]` entry in `MANIFEST.toml`.
2. `mise ign --server-name testbox --debug` → renders
   `bare-metal-debug.ign` cleanly through `butane --strict`.
3. `mise ign --server-name testbox` (without `data_disks` filled) →
   errors with a clear message pointing at the discovery-boot step.
4. Fill `data_disks = ["/dev/sda"]` in `server.toml` →
   `mise ign --server-name testbox` → renders `bare-metal.ign` cleanly
   through `butane --strict`.
5. `mise ipxe:serve --server-name testbox --debug` → starts nginx,
   serves `boot.ipxe` + `materia-debug.ign`, prints the iPXE chain URL.
6. No file under `gitops/`, `argocd`, `eso`, `newt`, `kubestellar`, or
   `protonpass-webhook` gets created — confirm via `git status`/diff.
7. Clean up the `testbox` scaffold after verifying (`rm -rf
   provisioning/servers/testbox`, revert the `MANIFEST.toml` entry).

## Risks

- **`butane --strict` validation** — the `bare-metal.bu` template must
  pass strict validation. The LVM script's inline content and the
  nftables config need correct YAML indentation and Butane schema
  compliance. Mitigation: test with `butane --strict` locally before
  committing.
- **`${DATA_DISKS}` substitution** — the `ign` task substitutes this as
  a raw string into the LVM script's `DEVS=(...)` line. If `data_disks`
  contains special characters, the substitution could break the script.
  Mitigation: device names are always `/dev/...` paths (alphanumeric +
  `/`), no special chars expected; the `sed` delimiter `|` is safe.
- **nftables locks out SSH** — the closed-posture rules drop all inbound
  by default. If SSH is needed after provisioning, a rule must be added
  (or the firewall disabled for initial setup). The source repo's
  troubleshooting table already notes this. Mitigation: document in
  `BARE-METAL.md` that SSH access requires either a temporary nftables
  exception or physical/serial console access.
- **Manual `flatcar-install` step** — the current flow requires SSHing
  into the RAM-booted Flatcar and manually running `flatcar-install`.
  This is inherently interactive and can't be fully automated without
  the declarative on-disk provisioning (flagged as future work).
