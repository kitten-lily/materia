# Implementation Plan — Issue #102: Migrate flutterina/bow to Fedora Hummingbird

**issue:** https://github.com/kitten-lily/materia/issues/102
**risk:** P0 for the live-cutover phases (flutterina is the fleet's only
public ingress; bow hosts the home media/services stack) — P2 for the
tooling/pilot phases (net-new, no production host touched).
**epic:** standalone, phased (not split into sub-issues per repo convention
— see issue-9/issue-38/issue-99 for precedent on single-issue multi-phase
plans of this size)

## Summary

Fedora Hummingbird (announced Red Hat Summit 2026,
https://fedoramagazine.org/fedora-hummingbird-linux-taking-the-hummingbird-model-to-the-full-os/,
SIG at https://fedoraproject.org/wiki/Hummingbird) is a bootc
(bootable-container) rolling OS that tracks Fedora Rawhide, uses the ARK
mainline kernel, and ships the entire OS as a pulled OCI image with
atomic, read-only-rootfs updates. It has **no Ignition equivalent** — the
Butane/Ignition provisioning model this repo is built on (`provisioning/templates/hetzner.bu`,
`bare-metal.bu`, `mise ign`) does not carry over.

This plan replaces Butane/Ignition with a **bootc image + `bootc-image-builder`**
pipeline for building a generic, per-provider-agnostic disk image, and
reuses the repo's already-proven **`adopted` server flow**
(`mise server:new --type adopted`, `mise server:adopt-render`, live on
`krytis-build` since issue #99) to deliver materia's install files over
SSH after boot — instead of inventing a new first-boot config mechanism.
Contabo is added as a third provisioning target using the same pipeline.

## Investigation findings

### What Fedora Hummingbird is (confirmed against Fedora's own sources)

- Ships as an OCI image (`quay.io/hummingbird-community/bootc-os`), built
  via [Fedora's bootable-containers initiative](https://docs.fedoraproject.org/en-US/bootc/getting-started/)
  (`bootc`). Root filesystem read-only; writable state confined to
  `/var` and `/etc`. Atomic updates with rollback, no partial-update
  states — this is a genuine improvement over Flatcar's `locksmithd`
  reboot-window approach.
- 95%+ of packages come straight from Fedora Rawhide; the rest built by
  the Hummingbird factory pipeline (Konflux-based, hermetic RPM-locking).
  Multi-arch (x86_64, aarch64).
- Uses the ARK (Always Ready Kernel) from Red Hat's CKI project —
  tracks Linus' mainline directly, already includes WireGuard (mainline
  since 5.6) — relevant to Gerbil on flutterina.
- Explicitly described by Fedora/Red Hat's own coverage as **"currently
  experimental and not suitable for production use."** The Fedora
  Hummingbird SIG wiki page itself notes Hummingbird's Fedora-project
  status is still in early SIG formation, not a released Fedora edition.
- "Distroless" branding applies to the *application* container image
  catalog (Project Hummingbird's Python/Go/Node/etc. runtime images) —
  the **bootc-os** host image is a full OS (systemd, podman, bootc
  tooling), not distroless in the no-shell sense; confirmed by the
  Fedora Magazine getting-started steps (`podman run`, `virt-install`,
  standard qcow2 boot).

### bootc provisioning model (confirmed against bootc.dev + osbuild docs)

Three first-boot mechanisms exist for a bootc image, and which ones work
depends entirely on what's baked into the image:

1. **cloud-init** — only runs if the image includes the `cloud-init`
   package. Not confirmed present in Hummingbird's base image (needs a
   research spike, see below).
2. **Ignition** — runs in the initramfs *before* the real root is
   mounted; requires the image's dracut stack to bundle
   `ignition-dracut`, the same component Fedora CoreOS ships. Not
   confirmed present in Hummingbird (which is a distinct build lineage
   from FCOS, despite sharing contributors/tooling).
3. **systemd-firstboot** — locale/timezone/hostname/root-password only.
   Insufficient for our needs (SSH keys, quadlets, systemd units).

Because (1) and (2) are unconfirmed and this repo cannot spend a
production host finding out the hard way, **the plan does not depend on
either**. See "Architecture decision" below.

`bootc-image-builder` (`quay.io/osbuild/bootc-image-builder`, or the
`centos-bootc` mirror) converts a bootc OCI image into a bootable disk
image (`qcow2`, `raw`, `ami`, `vhd`, `iso`, etc.) and accepts a
`config.toml` customizations file supporting `[[customizations.user]]`
(name, password, SSH key, groups), `[[customizations.filesystem]]`
(partition sizing), and `[customizations.kernel]` (kernel args) — this
**does** work reliably today and is the supported way to inject an SSH
key into a bootc disk image at build time.

### Provider-specific findings

- **Hetzner:** `hcloud-upload-image` (already a pinned tool in
  `mise.toml`) uploads *any* raw disk image as a snapshot — it's not
  Flatcar-specific (confirmed: it's already used for Fedora CoreOS raw
  images by the community, same upload flow). `bootc-image-builder
  --type raw` output is a drop-in replacement for the Flatcar
  `raw.xz` this repo already uploads. Hetzner's Ignition/metadata-service
  incompatibility (a known Flatcar/FCOS gotcha) is moot once Ignition is
  out of the picture.
- **Bare-metal:** no equivalent of `flatcar-install -d <disk> -i
  <ignition-url>` exists for bootc from a generic rescue environment.
  bootc's own install path is `bootc install to-disk` (or `to-existing-root`),
  run *from a booted instance of the target bootc image itself*
  (typically an ISO/live environment built from the same image) — it
  pulls the target OCI image directly onto the disk and reboots into it.
  This changes the bare-metal runbook: instead of iPXE → RAM-booted
  Flatcar → manual `flatcar-install -i <ignition>`, it becomes iPXE →
  RAM-booted Hummingbird install ISO (built via `bootc-image-builder
  --type anaconda-iso` or `--type iso`) → `bootc install to-disk
  --target-imgref <our-image> /dev/<disk>` → reboot. Confirmed as the
  documented bootc bare-metal pattern; exact anaconda-iso vs. iso
  behavior for Hummingbird specifically is a research-spike item.
- **Contabo (new):** supports Custom Images via `cntb create image
  --url <http-url> --osType Linux` (Custom Images add-on must be
  activated once in the Customer Panel — manual, one-time, not
  IaC-able) and API-driven instance creation
  (`cntb create instance --imageId ... --productId ... --region ...`).
  Cloud-init `userData` is supported at instance-create time, but **this
  plan doesn't use it** — see "Architecture decision" for why (keeps all
  three providers on one uniform post-boot flow). The `--url` flag is
  fetch-based: Contabo's backend must be able to reach that URL over the
  public internet — there's no direct multipart upload in the documented
  CLI/API. This needs a public-reachable hosting step for the qcow2
  (flagged as an open question, not solved by local tooling alone).

## Architecture decision

**Every Hummingbird host is provisioned as an `adopted` host.** No new
Ignition-equivalent is built. Concretely:

1. **One shared, provider-agnostic bootc image**, built from a new
   `provisioning/hummingbird/Containerfile`:
   ```
   FROM quay.io/hummingbird-community/bootc-os@sha256:<pinned>
   # Podman needs a policy.json to allow image pulls (same gotcha as Flatcar)
   COPY policy.json /etc/containers/policy.json
   # WireGuard kernel module config (Gerbil, flutterina only — harmless elsewhere)
   COPY wireguard.conf /etc/modules-load.d/wireguard.conf
   # Ghostty terminfo (same blob as provisioning/ghostty.terminfo.b64, decoded)
   COPY xterm-ghostty /etc/terminfo/x/xterm-ghostty
   # Bare-metal only: LVM data-disk + nftables closed-posture units,
   # idempotent/no-op on hosts that don't invoke them (Hetzner/Contabo
   # hosts never enable lvm-data.service or the nftables dropin)
   COPY lvm/ /opt/lvm/
   COPY nftables.d/ /etc/nftables.d/
   COPY *.service *.timer /etc/systemd/system/
   # Enabled at BUILD time via plain systemctl — no Ignition-timing hack
   # needed, unlike Flatcar's sysext-merge-order problem for podman.socket.
   RUN systemctl enable podman.socket
   ```
   No `materia-update.container`/`.timer`/`config.toml`/`key.txt` in the
   image — those stay per-server, delivered post-boot (see step 3). No
   secrets of any kind in this image, which is good because it may end
   up in a registry with a wider blast radius than Hetzner's
   snapshot-per-project or a `user_data` blob that never leaves the
   provider's metadata service.
2. **`bootc-image-builder`** converts the built image to `raw` (Hetzner,
   Contabo) and `anaconda-iso`/`iso` (bare-metal installer media), with
   a `config.toml` baking in **only** the `core` user + `CORE_SSH_PUBKEY`
   (same shared key already used fleet-wide, no change to trust model —
   see AGENTS.md "Server secret isolation: not yet done").
3. **`mise server:adopt-render`, extended**, delivers the 4 (5 for
   bare-metal) files over SSH after boot: `config.toml`, `key.txt`,
   `materia-update.container`, `materia-update.timer`, and (bare-metal
   only) a plain-text `data-disks` file the baked-in `lvm-data.service`
   reads instead of a build-time `${DATA_DISKS}` substitution (device
   paths can't be known when the image is shared across servers).
   Extend `adopt-render` with an `--ssh <user@host>` flag that runs the
   3 documented prereq steps (hostname, `podman.socket` enable — already
   done at build time for Hummingbird so this becomes a no-op check, not
   a manual step — and `mkdir -p /var/lib/materia`) plus the scp
   delivery automatically, since this flow now runs 3x (flutterina, bow,
   any future host) instead of the one-off krytis-build case it was
   built for.

This deliberately **does not** pursue cloud-init or Ignition-in-Hummingbird
even if a research spike finds one works — uniformity across all three
providers (identical post-boot flow, one code path, no
per-provider first-boot config format) is worth more than a marginally
"more native" per-provider mechanism, and avoids gambling on
unconfirmed-and-experimental-OS behavior.

## Repo layout changes

```
provisioning/
  hummingbird/                       # NEW — replaces templates/*.bu for these hosts
    Containerfile                    # shared image definition (see above)
    policy.json
    wireguard.conf
    lvm/setup-data-vg.sh             # ported from bare-metal.bu, DATA_DISKS
                                      # read from /etc/materia-bootstrap/data-disks
                                      # (delivered by adopt-render) not a build-time subst
    lvm-data.service
    nftables.d/closed.conf
    nftables-closed-posture.service  # dropin equivalent, now a real unit (build-time enable)
    config.toml.tmpl                 # bootc-image-builder customizations (SSH key only)
  templates/
    hetzner.bu                       # KEPT until flutterina cutover verified — Flatcar still boots
    bare-metal.bu                    # KEPT until bow cutover verified
    bare-metal-debug.bu              # KEPT (Flatcar discovery boot still used pre-cutover)
.mise/tasks/
  hummingbird/
    build                            # podman build + push the Containerfile image
    image                            # bootc-image-builder → raw/iso per --type
  hz/
    upload-image                     # EDIT: accept Hummingbird raw image path
    create                           # EDIT: drop --user-data-from-file; SSH-based adopt flow after
  contabo/                           # NEW — mirrors hz/
    upload-image
    create
    delete
    list
    ssh
    _server-id                       # mirrors hz/_server-id
  server/
    new                              # EDIT: --type gains "contabo"; hetzner/bare-metal --type
                                      # gains an --os flatcar|hummingbird flag during transition
    adopt-render                     # EDIT: --ssh flag automates the prereq + delivery steps
fnox.toml                            # NEW secrets: CONTABO_CLIENT_ID, CONTABO_CLIENT_SECRET,
                                      # CONTABO_API_USER, CONTABO_API_PASSWORD
mise.toml                            # NEW tool: cntb (Contabo CLI), bootc-image-builder is a
                                      # container (quay.io/osbuild/bootc-image-builder), not a
                                      # mise-managed binary — invoked via podman run like restic-backup's image tooling
```

## Phased plan

### Phase 0 — Research spike (no production risk, blocks everything else)

Answer these before writing any tooling; each is a go/no-go input to
Phase 1:

1. Does `quay.io/hummingbird-community/bootc-os` include `cloud-init` or
   `ignition-dracut`? (`podman run --rm --entrypoint rpm
   quay.io/hummingbird-community/bootc-os -qa | grep -Ei
   'cloud-init|ignition'`). Informational only — plan already commits to
   the adopted-flow design regardless of the answer, but confirms no
   simpler path was missed.
2. Is SELinux enforcing by default in the image? (`podman run --rm
   quay.io/hummingbird-community/bootc-os getenforce`, or boot a VM and
   check). Determines whether `SecurityLabelDisable=true` and existing
   `:z`/`:Z` volume labels on materia's own quadlets are sufficient
   as-is or need adjustment — test against a live VM boot, not just the
   container image, since enforcement can differ between the container
   build-time view and the booted-OS runtime view.
3. Does `bootc install to-disk` work unattended from an iPXE-served
   ISO/live image without an interactive TTY, and can it target a
   specific disk non-interactively? Build a throwaway `anaconda-iso` or
   `iso` locally with `bootc-image-builder` and test in a local KVM VM
   (`virt-install`) before touching real hardware.
4. Does WireGuard (`modprobe wireguard`) work under the ARK kernel with
   the NET_ADMIN/SYS_MODULE capabilities Gerbil currently needs? Test in
   a local VM boot of the built image.
5. Confirm a public-reachable hosting mechanism for Contabo's
   `--url`-based custom image fetch (candidates: Contabo's own
   S3-compatible Object Storage, a GitHub Release asset URL, a
   short-lived Cloudflare Tunnel/similar from the workstation). Pick one
   and document it in this plan before Phase 4.
6. Confirm `hcloud-upload-image` accepts a non-Flatcar raw image
   unmodified (it should — the tool is image-format-agnostic — but
   verify against the actual Hummingbird raw output, not assumed).

**Verify:** a written finding (comment on issue #102) for each of the 6
items above, each either "confirmed working" or "blocked — see
mitigation," before Phase 1 work starts.

### Phase 1 — Shared bootc image + build tooling

- Create `provisioning/hummingbird/Containerfile` + the supporting files
  listed in "Repo layout changes." Port `policy.json`, wireguard config,
  ghostty terminfo, LVM script (DATA_DISKS source changed to a runtime
  file read, not a build-time substitution), and nftables closed-posture
  config from the existing `.bu` templates — same content, different
  delivery mechanism (`COPY` + build-time `systemctl enable` instead of
  Ignition `storage.files` + `systemd.units[].enabled`).
- `.mise/tasks/hummingbird/build` — `podman build` the Containerfile,
  push to a registry (reuse the existing GHCR org pattern from
  `images/restic-backup/`, e.g. `ghcr.io/kitten-lily/materia-hummingbird`).
- `.mise/tasks/hummingbird/image` — wraps the documented
  `bootc-image-builder` podman-run invocation, `--type raw` (Hetzner,
  Contabo) or `--type iso`/`anaconda-iso` (bare-metal), consuming
  `provisioning/hummingbird/config.toml.tmpl` with `${CORE_SSH_PUBKEY}`
  substituted the same way `mise ign` already does it (fnox → tmpdir →
  never committed).
- Renovate coverage for the pinned base-image digest, same
  `custom.regex` pattern already used for `ghcr.io/stryan/materia:stable`
  (currently uncovered per AGENTS.md "Decisions still open" — pick this
  up for the new image rather than repeating the gap).

**Verify:** `mise hummingbird:build` produces a pushed image;
`mise hummingbird:image --type raw` produces a `disk.raw` that boots
in a local `virt-install` VM with SSH reachable via the baked-in
`CORE_SSH_PUBKEY`.

### Phase 2 — Hetzner tooling + pilot host

- Edit `.mise/tasks/hz/upload-image`/`ensure-image` to accept the
  Hummingbird raw image (parameterize the image source rather than
  hardcoding Flatcar's coreos-installer download step).
- Edit `.mise/tasks/hz/create` to drop `--user-data-from-file` (no
  Ignition) — server boots with just the baked SSH key.
- Extend `mise server:adopt-render` with `--ssh <user@host>` to automate
  the prereq checks + scp delivery (see Architecture decision, step 3).
- **Pilot:** `mise server:new --server-name hb-pilot --type hetzner`
  (or a new throwaway type — naming decided in Phase 0 based on how much
  the hetzner flow actually changes) → create a **disposable** Hetzner
  VM, never wired into `MANIFEST.toml`'s real host list, run the full
  adopt-render flow, confirm `materia-update.timer` fires and a
  trivial component installs cleanly. Delete the pilot VM after.

**Verify:** pilot host reaches `systemctl status materia-update.timer`
= active, a smoke-test component (e.g. a throwaway echo container) gets
installed by a real `materia update` run, then the pilot is deleted.

### Phase 3 — Bare-metal tooling + pilot

- Build the `anaconda-iso`/`iso` output type, adapt
  `.mise/tasks/ipxe/serve` to serve the ISO (or a kernel+initrd pair,
  depending on Phase 0 finding #3) instead of `boot.ipxe` chaining to an
  Ignition URL.
- Update `provisioning/BARE-METAL.md` with the new
  discovery-boot-still-Flatcar → `bootc install to-disk` runbook (the
  discovery-boot step for identifying `/dev/nvme0n1`-style disk names
  can stay on the existing Flatcar RAM-boot path unchanged — only the
  *real* install step changes).
- **Pilot:** on spare/loaner hardware if available, otherwise a local
  KVM VM standing in for bare metal (bootc's `to-disk` install path is
  hardware-agnostic — a VM is a legitimate substitute for validating the
  install mechanics before touching bow specifically).

**Verify:** pilot bare-metal/VM target boots the installed Hummingbird
image from local disk (not the install media), `lvm-data.service`
creates `vg_data`/`lv_data` from a delivered `data-disks` file, nftables
closed-posture is active, `materia-update.timer` runs.

### Phase 4 — Contabo tooling (new provider)

- Resolve Phase 0 finding #5 (public-reachable hosting for the image
  URL) and document the chosen mechanism in this plan.
- `mise.toml`: add `cntb` tool (check for an existing aqua/homebrew
  registry entry, else `tool_alias` a GitHub release binary like
  `hcloud-upload-image`).
- `fnox.toml`: add `CONTABO_CLIENT_ID`, `CONTABO_CLIENT_SECRET`,
  `CONTABO_API_USER`, `CONTABO_API_PASSWORD` (Contabo's OAuth2
  client-credentials flow needs all four), with setup instructions
  mirroring the existing `hetzner`/`materia`/`materia-age` Proton Pass
  item conventions.
- `.mise/tasks/contabo/upload-image` — hosts the raw/qcow2 image at the
  Phase-0-chosen URL, `cntb create image --url ... --osType Linux`.
- `.mise/tasks/contabo/create` — `cntb create instance --imageId
  ... --productId ... --region ...`, no `userData` (per Architecture
  decision — SSH key is baked into the image, not injected via
  cloud-init).
- `.mise/tasks/contabo/{delete,list,ssh,_server-id}` — mirror the
  `hz/*` equivalents' shape and flag conventions.
- `server/new --type contabo` scaffolds `server.toml` with a
  `[contabo] productId = "..." region = "..."` block.
- **Pilot:** disposable Contabo instance, same verification bar as
  Phase 2's Hetzner pilot.

**Verify:** `mise contabo:create --server-name cb-pilot` produces a
reachable instance; adopt-render flow completes; pilot deleted
(`mise contabo:delete --confirm`) and the Custom Image removed.

### Phase 5 — Migrate bow (production, bare-metal)

Gated on Phase 3 passing and an explicit **go/no-go decision** given
Hummingbird's experimental status (see Risks). Sequence:

1. `mise hz:pull-config`-equivalent backup of bow's runtime volumes
   (media libraries live on the separate LVM data disk, untouched by an
   OS reinstall — only named volumes under podman storage need backup:
   `beszel-data`, `navidrome-data`, `grimmory-*`, `audiobookshelf-*`,
   `jellyfin-*`, `mediamanager-*`).
2. Provision a **new** Hummingbird install on bow's disk (or a spare
   disk if bow supports dual-boot-style staging) rather than in-place
   upgrading Flatcar — bootc has no in-place Flatcar→bootc conversion
   path.
3. Restore volumes, run `materia update`, verify every bow component
   (8 components per AGENTS.md's repo layout) comes up healthy.
4. Keep the old Flatcar disk/boot entry available for a defined rollback
   window before considering it done.

**Verify:** every bow-hosted service (music, grimmory, audiobookshelf,
jellyfin, mediamanager, buildbarn, beszel-agent, restic-backup) reports
healthy; a real `restic-backup` run completes against the Storage Box;
`newt` tunnel reconnects and Pangolin resource health checks go green.

### Phase 6 — Migrate flutterina (production, edge/public ingress)

Highest-risk phase — flutterina is the fleet's only public entry point.
Gated on Phase 2 passing, Phase 5 having run cleanly for a defined
soak period (proves the pipeline twice before touching the edge), and
explicit go/no-go approval.

1. Provision a **new** Hetzner server from the Hummingbird snapshot
   (not in-place — Hetzner servers are cheap to stand up in parallel).
2. `hz:pull-config`/`push-config` the pangolin runtime volumes
   (`pangolin-config`, `letsencrypt`) onto the new server.
3. Run `materia update`, verify the `pangolin.pod` (app, Gerbil,
   Traefik) comes up, WireGuard tunnels re-establish, Traefik serves
   every routed hostname.
4. Cut DNS/Hetzner floating IP (if used) or swap the server's public
   IP association to the new host; keep the old Flatcar flutterina
   running, unreachable, for a defined rollback window.
5. Decommission the old server only after a full soak period with no
   incidents.

**Verify:** every previously-working public hostname resolves and
serves through the new host; Gerbil WireGuard tunnels from all
`[Roles.tunneled]` hosts (bow, flutterina itself for beszel-hub health
checks) reconnect; `materia-update.timer` dead-man's-switch pings stay
green on healthchecks.io through the cutover.

## New mise tasks (summary table)

| Task | Purpose |
|---|---|
| `hummingbird:build` | Build + push the shared Hummingbird bootc Containerfile image |
| `hummingbird:image` | Run `bootc-image-builder` → raw/iso, bake in `CORE_SSH_PUBKEY` |
| `contabo:upload-image` | Host the built image + `cntb create image --url` |
| `contabo:create` | Create a Contabo instance from the custom image |
| `contabo:delete` | Delete a Contabo instance |
| `contabo:list` | List Contabo instances |
| `contabo:ssh` | SSH into a Contabo instance |
| `server:adopt-render --ssh` | Automate the prereq checks + file delivery over SSH (new flag) |

Existing `hz:upload-image`/`hz:create`/`ign` tasks are edited in place,
not replaced — until the Flatcar path is fully retired (after Phase 6),
both OS types must keep working for hosts not yet migrated.

## Out of scope

- `krytis-build` — already non-Flatcar, `adopted`, unaffected by this
  work (it's a Debian VPS owned by a different repo's provisioning
  tasks).
- Any component/service-level logic changes — this is purely the OS +
  provisioning layer. `MANIFEST.toml` host→component assignments are
  unchanged.
- Retiring the Flatcar `.bu` templates and `ipxe:*`/`hz:*` Ignition code
  paths — kept until both production hosts are confirmed stable on
  Hummingbird, tracked as a follow-up cleanup issue after Phase 6.
- A fully declarative/idempotent Contabo Terraform-style resource model
  — `cntb` CLI + mise tasks only, matching the existing `hcloud` CLI
  convention (no Terraform in this repo today).
- Multi-arch (aarch64) images — Hetzner/Contabo/bow are all x86_64
  today; not needed unless a future host requires it.

## Risks

- **Hummingbird is pre-GA and explicitly not production-recommended.**
  This is the dominant risk of the whole issue. Mitigation: Phase 0
  research spike + disposable pilots (Phases 2–4) before either
  production host is touched (Phases 5–6), each gated by an explicit
  go/no-go decision, not an automatic "tooling works, ship it."
- **SELinux enforcing-by-default** could break existing volume-label
  and `SecurityLabelDisable` assumptions carried over from Flatcar's
  permissive default. Mitigation: Phase 0 finding #2, validated live in
  a VM before any Containerfile work depends on the answer.
- **No in-place Flatcar→bootc migration path** — every host migration is
  a parallel-provision-then-cutover, not an upgrade. Mitigation: this is
  already how Phases 5–6 are planned (new server/disk, not in-place),
  and matches the existing `hz:pull-config`/`push-config` volume-backup
  tooling this repo already has for exactly this kind of cutover.
- **Contabo's fetch-based custom-image API** needs a public URL this
  repo doesn't currently have infrastructure for. Mitigation: Phase 0
  finding #5 picks a concrete mechanism before Phase 4 starts; not
  blocking for Phases 1–3 (Hetzner/bare-metal don't need it).
- **Shared bootc image in a registry is a wider secret-adjacent surface
  than Ignition's per-request `user_data`** even though no secrets are
  baked in — the image does encode the SSH-key-authorized `core` user
  and infrastructure layout. Mitigation: keep the registry private (same
  posture as `ghcr.io/kitten-lily/materia-hummingbird` alongside the
  existing private `restic-backup` image), no behavior change to the
  existing single-shared-age-key trust model (already an accepted "not
  yet done" tradeoff per AGENTS.md).
- **Rollback window discipline** — Phases 5–6 must not decommission the
  old Flatcar host/disk until a defined soak period passes with no
  incidents; a rushed cleanup here turns a reversible migration into an
  irreversible one.
