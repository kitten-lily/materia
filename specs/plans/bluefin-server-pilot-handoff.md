# Bluefin pilot (#179): session handoff

Written 2026-11-22 at the end of Phase 3, for a fresh session picking up the
pilot. State as of commit `9d7a873` on `main` (pushed). Nothing deployed
outside the two local VMs; no paid resource exists.

## Read first

1. [The plan](bluefin-server-pilot.md): phases, thresholds, the rule that a
   threshold changed after its results are in voids the gate.
2. [The results](bluefin-server-pilot-results.md): phase table at the top,
   per-phase evidence, findings F1–F11 near the end (newest first).
3. [Phase 3 design](bluefin-server-pilot-phase3.md) for how the cluster is
   built now (D1–D6, layout, bootstrap order).
4. [Edge ingress investigation](bluefin-edge-ingress-investigation.md),
   written by a parallel session: it adds a Phase 4 comparison arm (Envoy
   Gateway beside the Pangolin pod) and an optional cloud control-plane
   variant. Read its "Proposed pilot test arm (Phase 4)" and "Alternatives:
   control-plane placement" before planning Phase 4.
5. [Recovery procedures](bluefin-server-pilot-recovery.md) (console access,
   reinstall) and the Phase 1/2 designs for the VM tooling's history.

## Where things stand

| Phase | State |
| --- | --- |
| 0–3 | pass (Phase 3 on 2026-11-22, all steps 0–6) |
| 4 Hetzner edge worker | **next**: not designed yet |
| 5 updates/failures | not started |
| 6 runner | optional, not started |

Carried into Phase 4: Phase 2's `readyz` p95 (540 ms over DERP, threshold
500 ms) re-measured on a direct path; IPv6 denial tests (F6: the homelab
Cilium is IPv4-only, so the host firewall does not cover IPv6).

Open for production (not a pilot gate): a missing data disk still fails
`pilot-lvm-activate` and with it `systemd-boot-check-no-failures`, i.e.
Bluefin's boot counting would blame the OS image for a disk problem.

## The running pilot

Two QEMU VMs on the workstation (melog), both on **Bluefin Server
26.11.2506, pinned** (F11), Kubernetes v1.35.10, Cilium 1.20.2, joined only
over the tailnet (`tag:bluefin-pilot`):

- `bluefin-pilot-cp` (4 vCPU, 8 GiB): control plane; data VG `pilot_data`
  on its two data disks, LV mounted at `/var/lib/pilot-data` (ext4 UUID
  `ae24577e-15a4-4c29-a6b9-754f9005ce95`).
- `bluefin-pilot-node` (2 vCPU, 4 GiB): worker; backup disk at
  `/var/lib/pilot-backup` (ext4 UUID `42c71251-4350-4037-82d5-97da55d19fb1`)
  holding the restic repository.

Argo CD (template's v3.5.3) reconciles `provisioning/bluefin/gitops/apps` on
`main`: static volumes, MediaManager + PostgreSQL + Jellyfin + the backup
CronJob (`pilot-media`), the restic REST server (`pilot-backup`), the
Tailscale operator (`tailscale`) and Buildbarn (`pilot-buildbarn`, tailnet
device `bluefin-pilot-bst`), plus the sync and secret fixtures. All 8
Applications `Synced`/`Healthy` at handoff.

The workstation reboots or runs out of memory now and then (it OOM-killed the
control plane once; see the results). If the VMs are down:

```sh
mise bluefin:pilot:vm start --vm bluefin-pilot-cp --topology tailnet
mise bluefin:pilot:vm start --vm bluefin-pilot-node --topology tailnet
ssh -F ~/.cache/bluefin-pilot/secrets/ssh_config bluefin-pilot-cp   # or -node
mise bluefin:pilot:bootstrap   # idempotent; also delivers the lvm2 sysext
```

## Tooling (all in this repo)

| Task | Does |
| --- | --- |
| `mise bluefin:pilot:render --vm <vm> --topology tailnet [--data-fs-uuid U \| --backup-fs-uuid U]` | Ignition for a node; embeds the release pin (`provisioning/bluefin/sysupdate-pin/`), tailnet prep, data/backup mount units |
| `mise bluefin:pilot:vm create\|install [--reinstall]\|start [--without-data N]\|stop\|status --vm <vm>` | QEMU VMs; Ignition goes in as a fw_cfg file |
| `mise bluefin:pilot:lvm2-sysext` | builds the `pilot-lvm2` sysext (static lvm, pinned Alpine package) |
| `mise bluefin:pilot:bootstrap [--reapply-firewall] [--skip-firewall]` | per new cluster: lvm2 sysext + VG mount, Cilium host firewall (audit → observe → enforce, restores enforcing on failure), age key, operator OAuth Secret, KSOPS + Argo CD polling, root Application |
| `mise bluefin:pilot:bst-roundtrip --host … --cert … --push-token-file … --pull-token-file …` | BuildStream round trip + auth/size/TLS negatives (set `KRYTIS_REPO` for the bst2 image) |
| `mise check:bluefin-dump-copy` | the pilot's copy of `db-dump/dump.bash` matches the original |

Hand-applied fixtures (not GitOps): `provisioning/bluefin/fixtures/`
(`host-firewall.yaml` is applied by the bootstrap; `static-volume-check.yaml`,
`backup-restore-check.yaml` by hand with kubectl).

## Secrets and identities

- Proton Pass vault **`bluefin-pilot`**: `tailscale-auth-key`, `ssh-root`,
  `root-console-password`, `join-passphrase` (current control plane's),
  `sops-age-key` (pilot-only SOPS key; public key in `.sops.yaml`),
  `buildbarn-jwt-private-key`, `tailscale-operator-oauth`.
- Local, mode 600, never in git: `~/.cache/bluefin-pilot/secrets/`
  (`ssh_config`, root key, Buildbarn cert and push/pull tokens).
- Tailnet policy (admin console, not in git): tags `tag:bluefin-pilot`,
  `-operator`, `-svc` admin-owned (svc also owned by the operator tag),
  pilot tags in the `ipPool` node attribute, grants pilot↔pilot only, tests
  that fail a save if pilot and production tags can reach each other. No
  `tag:bluefin-pilot → tag:bluefin-pilot-svc` grant (it pulls the API route
  into the proxy's tailnet; F9) and no extra node attribute (F10 made it
  unnecessary).
- Reinstalling a node needs its tailnet device deleted first (admin console)
  so the name is reused; after a control-plane reinstall the four devices
  (both nodes, `bluefin-pilot-operator`, `bluefin-pilot-bst`) all go, and the
  new join passphrase must be stored in the vault before rendering the
  worker.

## Working agreements learned this session

- **Commits are SSH-signed with a security key; every signature needs a
  touch (and sometimes the PIN).** Make one commit per command and continue
  only if it succeeded (`&&` chains kept running after a failed commit twice).
  The agent log (`journalctl --user -u gcr-ssh-agent`) distinguishes
  `device not found` (hub dropped the key: ask for a replug) from
  `incorrect passphrase` / `invalid format` (prompt missed: ask the user and
  retry). A rebase re-signs every commit. Never `--no-gpg-sign`.
- **Commit explicit paths, never `-a`/`-am`:** other sessions share this
  working tree.
- **Public repo:** no tailnet name (the MagicDNS suffix), tailnet IPs or
  secrets in tracked files or issue comments. Scan before every commit/post;
  the Buildbarn cert lives only inside `buildbarn.sops.yaml` because its SAN
  names the tailnet.
- **Until 2026-11-23, delegate file work to Codex** (user request; memory
  `spread-work-to-codex`) via the `codex:codex-rescue` agent: give it every
  input it cannot fetch (no network in its sandbox: download sources/charts
  first), then review and test its output on the cluster before committing.
  This session found real bugs in four of its deliverables at test time
  (wrong whitespace assumption, no settle retry, wrong audit state name,
  BuildStream output misread).
- **Bluefin hosts have no `awk`, `find`, `xargs`, `diff`, `nft`,
  `iptables`, `nc`:** remote snippets use POSIX sh, sed, grep, cut, sort;
  do JSON work on the workstation with jq/yq.
- Shell-heavy heredocs with `$$` sometimes trip the harness's removal safety
  check even when nothing is deleted; use the Write/Edit tools for such
  files.
- Workstation journal timestamps are local time (CET); the VMs log UTC.

## Next step: Phase 4 design

Write `specs/plans/bluefin-server-pilot-phase4.md` before touching Hetzner,
the same way as Phases 1–3: design, Codex review, the user's decisions,
then implementation. Inputs:
- plan Phase 4 (cpx22 in hel1, pilot Hetzner firewall from Phase 0 step 5,
  UEFI per F1, Pangolin as one `hostNetwork` pod, restart gates, 2×
  flutterina peak, console recovery with Tailscale down);
- the edge-ingress investigation's comparison arm and optional control-plane
  variant;
- carried items: `readyz` p95 on the direct path, IPv6 denial tests (F6);
- the F11 pin must be in its Ignition from the first boot; the Hetzner node
  has no data disk to import.

Creating the server is the first paid action: confirm cost, deletion date
and the 7-day limit with the user before `hcloud server create`.
