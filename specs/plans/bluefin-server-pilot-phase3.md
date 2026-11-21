# Bluefin pilot Phase 3: implementation design

Implements Phase 3 of [the pilot plan](bluefin-server-pilot.md) (persistent
services as Argo CD-reconciled Kubernetes workloads) on the Phase 2 cluster:
two local VMs joined over the tailnet, Cilium host firewall enforcing.
Evidence goes to [the results](bluefin-server-pilot-results.md). Release
v26.11.2506. Status: draft, 2026-11-21. Decided: D1 this repository on `main`, D2 SOPS
through KSOPS, D3/D5 as recommended (no objection), D4 the Tailscale
Kubernetes operator, D6 initrd activation plus our own lvm2 sysext (static
binary as the fallback). Revised the same day after a Codex review: mount
ordering and the fallback activation path, the full bootstrap after the
reinstall, the secret-leak criterion, Buildbarn's two listeners and auth
negatives, backup freshness and state inventory, readiness gating, CAS
sizing, and the memory budget. Nothing here is deployed.

## Starting point (inspected 2026-11-21)

- **Argo CD v3.5.3 is already running** (homelab component `50-argocd`,
  pinned by digest). The root Application `homelab-root` is created only when
  `HOMELAB_ARGOCD_ROOT_REPO` is set in `/etc/bluefin/homelab.conf`. It uses
  project `default`, destination namespace `argocd`, and
  `automated: {prune: false, selfHeal: true}`. `argocd-cm` sets no
  `timeout.reconciliation`, so Argo's default applies (180 s, plus jitter).
- **The applier re-runs on every boot.** `bluefin-homelab-apply.service` is a
  oneshot wanted by `kubelet.service`. It applies every component with
  `kubectl apply --server-side --force-conflicts` and never deletes. A patch
  to a template-owned object survives only in fields the template manifest
  does not set. That matters for decision D2.
- **Reloader is on by default** (component `61-reloader`). Its annotations
  are the template's own answer to stale secrets. Step 2 uses it.
- **Storage:** only `local-path` (dynamic, default). The control plane has
  two 8 GiB data disks (`virtio-bluefin-data1/2`); the worker has one.
- **No LVM tooling in `/usr` (new finding, F7).** Neither node has `lvm`,
  `pvcreate`, `vgs` or LVM udev rules in the running system. Upstream pruned
  them on purpose (projectbluefin/server#487, 2026-10-17). **The initrd keeps
  them:** #489 lists "lvm + `69-dm-lvm.rules`" as kept, and the booted UKI's
  initrd contains `lvm`, `pvscan`, `vgchange`, `11-`/`69-dm-lvm.rules`,
  `systemd-run` and the NVMe and virtio drivers. See D6. `dm_mod`, `dmsetup`, `cryptsetup` and the generic
  dm udev rules are present. `dm_thin_pool` is absent, which doesn't matter
  for bow: its `lv_data` is one linear LV (`lvcreate -l 100%FREE`), ext4.
  The plan says missing LVM tooling "becomes an explicit compatibility task
  and blocks bow readiness". See D6.
- **Memory:** the control plane has 7.6 GiB with ~3 GiB available; the
  worker has 3.8 GiB with ~2 GiB available. The add-ons Argo Workflows, MCP
  and the KubeStellar Console are running and unused by the pilot.
- Cilium runs with kube-proxy replacement (`kube-proxy-replacement: true`),
  so hostPort and NodePort are handled by Cilium on the listed devices
  (`tailscale0,en+`).

## Decisions needed before implementation

Each has a recommendation; the alternatives are real options, not padding.

**D1: Where the pilot manifests live.** Recommended: this repository, under
`provisioning/bluefin/gitops/`, with the root Application tracking `main`
(`HOMELAB_ARGOCD_ROOT_PATH=provisioning/bluefin/gitops/apps`). The repository
is public, so Argo CD needs no git credential, and the manifests get the same
review and CI as everything else. Secrets are only ever committed encrypted
(D2). Tailnet names stay out of plaintext manifests: they go into encrypted
values or a cluster-side ConfigMap. Cost: the step 1 test pushes (a one-line
fixture change, a deliberately broken manifest and its revert) land on `main`.
Alternatives: a `bluefin-pilot` branch, which keeps `main` clean but drifts;
or a new private repository, which needs a deploy key in Argo CD.

**D2: Secrets mechanism.** Recommended: **SOPS with age through KSOPS**, a
kustomize exec plugin installed into `argocd-repo-server` by an init
container. The pilot-only age key lives in a Secret mounted into the repo
server and in the `bluefin-pilot` Proton Pass vault. This keeps the fleet's
existing model (SOPS, age, Proton Pass, `fnox`). The risk is the template:
Argo CD is re-applied on every boot. The KSOPS patch adds containers,
volumes and `kustomize.buildOptions`, which the template does not set, so
server-side apply should leave them alone. Step 2 proves that across an
applier re-run and a reboot. If it doesn't hold, fall back to
sealed-secrets. Alternative: **sealed-secrets**, a controller Argo CD
installs itself, with no change to the template's Argo CD. But its key is
bound to the cluster, so a rebuild needs a backup and restore of that key,
and every secret has to be re-sealed per cluster. Either way, the key has to
be bootstrapped after a rebuild. Step 6's reinstall tests that: render puts
the key on the control plane as a credential, and a oneshot creates the
Secret.

**D3: Media app.** Recommended: **MediaManager plus its PostgreSQL 18
sidecar**, at the production pins. It covers three plan items at once: the
database with an app gated on its readiness, the read-write `video/` volume,
and the startup hardlink check the plan names. Add **Jellyfin** on read-only
`Movies`/`TVShows` volumes, without `/dev/dri`, to prove the read-only path.
It is cheap and is what bow serves most. Alternative: Jellyfin only, plus a
plain PostgreSQL fixture. That drops the hardlink check.

**D4: Buildbarn reachability from the tailnet. Decided: the Tailscale
Kubernetes operator** (operator decision 2026-11-21, over the recommended
hostPort). This is closer to today's `svc:bst-cache` and tests the
in-cluster Tailscale model a production migration would likely use. It
needs, all pilot-only:
- an operator tag and a proxy tag in the tailnet policy (`tagOwners`), and a
  grant from the workstation to the proxy tag on tcp 7981–7982 (your
  change);
- an OAuth client owning those tags, stored as a SOPS Secret (D2);
- the operator, installed by Argo CD from its Helm chart at a pinned
  version, with images pinned by digest.

Topology, matching production (one name, two ports): one pod with two
containers. bb-storage listens on 7982 and bb-asset on 7981; bb-asset
reaches storage over `localhost:7982`. One `LoadBalancer` Service of class
`tailscale` (an L4 proxy) carries both ports. TLS terminates in each
container, with one pilot-only cert whose SAN is the proxy's MagicDNS name
and whose key is in SOPS. Only that name is reachable: no hostPort and no
host-firewall change. Clients use the same name on both ports, as with
`svc:bst-cache` today. To verify during implementation:
- the version's support for exposing the Service as a Tailscale Service (a
  ProxyGroup) versus one device per Service. Prefer the Tailscale Service
  if it works, since that is the production shape.
- that the proxy pod's `tailscaled`, inside the pod network namespace, does
  not recreate F5. Peers must not reach it through Cilium's VXLAN, and
  `tailscale status` must show no `10.244.` endpoint.

**D5: Backup target.** Recommended: run the **existing `restic-backup`
image** as a CronJob, against a **restic REST server pod pinned to the
worker**. Its repository is a static local PV on the worker's own data disk
(`virtio-bluefin-data1`, ext4, label `pilot-backup`, mounted by a unit like
D6's). So it survives the worker's OS reinstall in step 6, and step 6 checks
that it did. The backup leaves the control plane, costs nothing, and touches
no production Storage Box.

**One CronJob, two stages,** so a backup can never ship a stale dump. An
init container runs `pg_dump` with the db-dump contract (`dump.bash`): it
writes counts before and after, the dump, and a `.done` file carrying the
run ID and sha256s, all by atomic rename. The restic container then refuses
to run unless `.done` carries this run's ID.

**What is backed up, and what consistency it gets:**
- **PostgreSQL:** the logical dump is the recovery source. The PGDATA volume
  is deliberately not backed up as files.
- **Video library:** files, crash-consistent, which is fine for media.
- **Jellyfin `/config`:** files, crash-consistent, the same as production
  restic of volumes today. Recorded as a known limit (SQLite inside).
- **MediaManager `/images`:** a poster cache, declared rebuildable,
  excluded.
- **Buildbarn CAS/AC/FSAC:** a cache, declared rebuildable, excluded. The wrapper is
repository-agnostic (`RESTIC_REPOSITORY`), and `HC_PING_URL` is left unset,
since pings are optional and non-fatal. Alternative: a test subaccount on
the production Storage Box, which tests the real sftp path but shares an
account with production backups. Or Velero, which is more
Kubernetes-native but a new tool. The repo here already has a working
restic image.

**D6: LVM on Bluefin. Decided: our own `lvm2` sysext, with a static binary
as the fallback** (operator decision 2026-11-21). The initrd finding above,
made after that decision, splits the problem in two:

- **Activation and import (boot-critical): the initrd.** Its `lvm.conf` is
  upstream's default: event activation on, no filter, no devices file. Its
  `69-dm-lvm.rules` runs `pvscan --cache --checkcomplete` on every PV that
  appears. Once a VG is complete, it runs `systemd-run … lvm vgchange -aay
  --autoactivation event <vg>`. So a VG whose disks appear during the initrd
  should be active before switch-root, and its dm devices persist into the
  real root. The real root has `10-dm`/`13-dm-disk.rules`, which give
  `/dev/mapper/<vg>-<lv>` and `/dev/disk/by-label/…`, but not
  `/dev/<vg>/<lv>`.

  A `.mount` unit for `/var/lib/pilot-data` then mounts it. `What=` is the
  filesystem UUID recorded at creation and passed to render, never a label,
  so a stray filesystem cannot stand in. kubelet gets
  `Wants=`/`After=pilot-data.mount`, so the mount is pulled in and attempted
  first. Nothing to maintain on the boot path.

  **Deliberately not `Requires=`.** On the control plane, kubelet runs the
  API server, etcd and the scheduler as static pods. Making it require the
  data mount would turn a missing disk into a whole-cluster outage, with no
  API to diagnose through. That is the wrong failure for bow. Data safety
  comes from the path rule below instead. If the mount fails, the cluster
  comes up, the pods using these volumes stay `ContainerCreating` with
  "path does not exist", and nothing lands on the root disk. Step 0's
  negative test proves exactly that. Step 0 proves it: the journal of the boot shows
  `lvm-activate-pilot_data` running in the initrd. Step 6 proves it again on
  a freshly installed OS disk, which is exactly bow's import case.

  Risk: this is not a documented contract. Upstream kept it in the initrd,
  but a later size prune could drop it. The results record it as a
  dependency, and production wants it stated upstream (an issue there needs
  your permission).
- **Management (create, extend, resize; not boot-critical): our sysext.** A
  `pilot-lvm2` sysext holds the static `lvm` from a digest-pinned Alpine
  `lvm2-static` package, with symlinks and an `lvm.conf` setting
  `udev_rules = 0`/`udev_sync = 0`. It has an `extension-release` matching
  `ID=bluefin-server` and is installed by render into `/var/lib/extensions`.
  It ships no udev rules, so it cannot race the initrd's activation.

  First test: whether Bluefin merges an **unsigned** sysext at all. Its
  `systemd-sysext.service` sets no explicit image policy, and the release's
  own sysexts are signed. If it refuses, fall back to the same binary under
  `/var/opt/pilot-lvm/` (option 1), and record signing as the production
  question.
- **Bounded fallback if the initrd does not activate:**
  `pilot-lvm-activate.service`, a oneshot ordered `Before=pilot-data.mount`.
  It is skipped when `/dev/mapper/pilot_data-data` already exists. Otherwise
  it runs `lvm vgchange -ay pilot_data` from the sysext, or from the static
  path if the sysext was rejected, with `TimeoutStartSec=2min`. It does not
  rely on udev rescanning disks it has already seen. Its journal line shows
  which path activated the VG on each boot.

Either way, every static PV path is a subdirectory that exists only inside
the LV (`/var/lib/pilot-data/video/...`). If the LV isn't mounted, kubelet
fails with "path does not exist" and retries. Pods never write to the root
disk. Nothing ever creates these directories with `mkdir -p` on a live path.
The one-off fixture setup in step 0 first checks that `findmnt -no UUID
/var/lib/pilot-data` equals the recorded UUID, and refuses otherwise.

**Upstream survey (2026-11-21, projectbluefin/server issues and PRs):**
- **lvm2:** no issue mentions lvm2 or LVM support. #487 removed it from
  `/usr` because nothing in the image used it. #489 kept it in the initrd.
- **btrfs:** no issue. The kernel has `btrfs.ko`, but neither `/usr` nor the
  initrd ships btrfs-progs. The initrd has only `mkfs.ext4`/`e2fsck`.
- **ZFS:** shipped. The release has `zfs_26.11.2506.raw.zst`, a signed
  sysupdate feature `zfs` ("OpenZFS systemd-sysext, locked to the image
  version"), off by default. #320/#319 made it coexist with NVIDIA.
- **ZFS coupling:** #678 (open) says OpenZFS is built against the image's
  single FSDK kernel. When the kernel outpaces OpenZFS the whole build
  breaks, as on the FSDK 26.08.4 bump (#543, open). The proposed fix (an LTS
  kernel stream) conflicts with upstream's one-kernel rule, so it is
  undecided.
- **Moving bow to ZFS or btrfs** means copying its whole data set, which
  spans both NVMe drives, onto a new pool. That needs spare capacity and an
  outage. On ZFS it also ties bow's storage to upstream's kernel/OpenZFS
  coupling, so it is not a pilot step. Recorded as the alternative if LVM
  import fails.

## Layout

```
provisioning/bluefin/gitops/
  apps/                       # root path: one Application per workload, prune + selfHeal
  platform/                   # KSOPS patch, Tailscale operator, static PVs
  workloads/
    sync-fixture/             # step 1: a ConfigMap + Deployment that echoes it
    secret-fixture/           # step 2: SOPS Secret, Reloader-annotated consumer
    mediamanager/             # app + postgres StatefulSet (PGDATA set), config Secret
    jellyfin/                 # read-only library volumes
    buildbarn/                # one pod: bb-storage :7982 + bb-asset :7981, one tailscale Service
    backup/                   # one CronJob (pg_dump init + restic), REST server (worker)
```

Sync order inside Argo CD (sync waves): CRDs (Tailscale operator) first,
synced with `ServerSideApply=true`. Then the operator, waiting for it to be
healthy. Then the static PVs and StorageClass. Then the workloads, then the
tailscale Service. Waves order the first sync only. Readiness between pods
is the init containers' job (step 4).

Every image pinned by digest, the same digests as the production components
where one exists. Host-firewall changes, if any turn out to be needed, stay
in `fixtures/host-firewall.yaml` and are applied by hand as in Phase 2, not
by Argo CD. A firewall that GitOps can break would also need a GitOps-proof
way back in. Render gains the D6 units and the D2 key credential.

**Bootstrap, outside workload GitOps** (`mise bluefin:pilot:bootstrap`, run
once per new cluster and again after step 6). In order, each step gated on
the previous one being ready:
1. Apply the Phase 2 Cilium objects: the `CiliumNodeConfig` and the host
   policy, in audit mode first. Check the effective config on every agent
   and that nothing legitimate is dropped, then enforce. These live in etcd,
   so a reinstall loses them.
2. Create the age key Secret in `argocd`. The key comes from the credential
   render put on the control plane, or from Proton Pass.
3. Apply the KSOPS repo-server patch from a plaintext kustomization in git
   (`platform/argocd-ksops/`, no encrypted content, so it needs no KSOPS to
   render). Wait for the repo-server rollout.
4. Set `HOMELAB_ARGOCD_ROOT_*` and re-run the applier, which creates
   `homelab-root`.

Before reinstalling a node, delete its old Tailscale device. The Phase 2
procedure does this, so the hostname and MagicDNS name are reused.

## Data layout (control plane, VG `pilot_data` on both data disks)

```
/var/lib/pilot-data/            # LV mount (ext4, label pilot-data), never a PV path itself
  video/{Movies,TVShows,Downloads}  # one rw PV over video/ for MediaManager (hardlinks)
                                    # ro PVs over Movies/ and TVShows/ for Jellyfin
  postgres/                     # PV for the StatefulSet
  buildbarn/                    # PV: CAS 4 GiB blocks + 16 MiB map, AC 64 MiB, FSAC 16 MiB, asset index
  dumps/                        # PV: pg_dump output + .done, read by the restic stage
  jellyfin-config/              # PV: Jellyfin /config (backed up)
  mediamanager-images/          # PV: poster cache (not backed up)
```

**CAS sizing:** the production block layout `8/24/3/3` (38 blocks) over a
4 GiB blocks file gives a per-blob ceiling of about **108 MiB**. AC and FSAC
use production's `8/24/1/3` over 64 MiB and 16 MiB. The asset index is a
few MiB. Buildbarn's budget is about 4.2 GiB of the ~16 GiB VG, alongside
~1 GiB of video fixtures, the postgres data, dumps and Jellyfin config.

Static `local` PVs with node affinity to `bluefin-pilot-cp`, a
`StorageClass` `pilot-static` (`no-provisioner`, `WaitForFirstConsumer`),
`persistentVolumeReclaimPolicy: Retain`. UIDs: video and the MediaManager
volumes owned 1000:1000, as the production gotcha requires.

**Memory budget** (requests = limits for the pilot workloads; numbers are
starting values, adjusted in the results):

| Workload | Memory |
| --- | --- |
| postgres | 256 MiB |
| MediaManager | 512 MiB |
| Jellyfin | 768 MiB |
| bb-storage + bb-asset | 768 MiB |
| backup job | 256 MiB |
| operator + proxy | 192 MiB |
| total on the control plane | ~2.75 GiB |

That is about all of the ~3 GiB now free, so the unused add-ons go first.
The applier never deletes, so `HOMELAB_ARGO_WORKFLOWS=no`, `HOMELAB_MCP=no`
and `HOMELAB_KUBESTELLAR_CONSOLE=no` only stop them coming back. Their
objects are deleted explicitly: `kubectl delete -f` of each add-on's
manifests from the merged sysext, plus their namespaces. A reboot then
checks they stay gone. That happens before step 4, and the freed memory is
recorded.

## Steps and verification (plan Phase 3, with thresholds)

Thresholds are fixed here, before the phase starts.

0. **Data volume** (the create half of plan step 6, moved first because
   steps 3–5 need it). On the control plane:
   - check that the unsigned `pilot-lvm2` sysext merges (else the static
     fallback), then build the VG and LV on both data disks with it;
   - write the checksum fixtures (synthetic media files, a 256 MiB random
     file, a hardlink pair);
   - reboot.

   Pass: after reboot, the LV was activated by the initrd
   (`lvm-activate-pilot_data` in the initrd part of `journalctl -b`) and
   mounted before `kubelet.service` started (journal order), with the
   fixture checksums intact. If the initrd did not activate it, record that
   and use the fallback in D6.

   **Negative test:** boot the control plane with the second data disk
   detached (the VG is incomplete). Pass:
   - the cluster comes up;
   - `pilot-data.mount` fails within its timeout, and no `pilot-lvm-activate`
     partial activation is left;
   - after step 3 exists, a PV consumer stays `ContainerCreating` with "path
     does not exist";
   - nothing was written under `/var/lib/pilot-data` on the root disk.

   Reattach the disk and reboot: everything returns with checksums intact.
1. **GitOps.** Set `HOMELAB_ARGOCD_ROOT_*`, re-run the applier, then check
   that every Application is `Synced`/`Healthy`. Then:
   - **Pushed change:** push the sync fixture's ConfigMap change. Pass: it
     rolls out within **5 min** of the push with no manual step.
   - **Hand edit:** `kubectl edit` a managed field. Pass: reverted within
     **5 min**.
   - **Broken manifest:** push one. Record how the failure surfaces
     (`kubectl -n argocd get applications`, conditions, events). Then revert
     it and confirm recovery.

   Record the effective sync interval.
2. **Secrets (D2).** A consumer reads a SOPS Secret.
   - **Rotation:** rotate the secret in git. Pass: within **5 min** the
     consumer reports the new value's **sha256 prefix** and a revision
     label, never the value, through Reloader and with no manual step.
   - **Authorised access vs disclosure:** KSOPS hands decrypted Secret
     manifests to Argo CD by design, so the repo-server, its manifest cache
     in redis and the API server hold plaintext. Record that as the model's
     cost; it is not something to deny. Accidental disclosure fails the
     step. Pass: zero matches of either value, in plain **and base64** form,
     in:
     - git history;
     - `kubectl get events -A`;
     - the logs of every pod in `argocd` and the fixture namespace;
     - Argo CD's API views (`argocd app manifests`, `argocd app diff`, the UI
       resource view), which must show the Secret's `data` redacted.
   - **Template re-apply:** re-run the applier and reboot the control plane.
     Pass: the repo-server still decrypts (KSOPS patch intact).
3. **Static volumes.** Pass:
   - fixture checksums match from inside a pod on every static PV;
   - MediaManager's startup filesystem check reports hardlinks working (no
     `Invalid cross-device link`, no copy fallback);
   - a write to a Jellyfin read-only mount fails with `Read-only file
     system`.
4. **Workloads.**
   - **Readiness:** every pod `Ready` within **10 min** of sync.
   - **Gating:** MediaManager has an init container that loops on an
     authenticated `psql -c 'select 1'` against the database Service, so the
     gate runs on every pod creation, not just the first sync. Test it:
     scale postgres to 0, delete the MediaManager pod, and check it waits in
     `Init:0/1` for at least 2 min. Then scale postgres back. Pass: the
     migration and the app start, with zero container restarts.
   - **No eviction:** no OOMKill or eviction in any pilot namespace across
     the whole phase, including while the scheduled backup runs (checked
     from events and `kubectl get pods -A`).
   - **Database survival:** write marker rows. Pass: the rows are identical
     after deleting the postgres pod, and after rebooting the control plane.
   - **Buildbarn:** BuildStream 2, in a container on the workstation, builds
     a tiny import element and pushes it to the cache through the operator's
     tailnet name. TLS is verified by that name against the pilot CA, with
     JWT auth. The element holds a 64 MiB file, under the ~108 MiB ceiling.
     Then delete the local cache and pull it back. Pass:
     - the sha256 of the checked-out artifact equals the source;
     - a wrong hostname fails TLS verification;
     - a request with no token is refused;
     - a pull-role token can read but a push with it is refused;
     - a single 150 MiB blob is refused with `INVALID_ARGUMENT`, the
       documented ceiling failure, not a hang or a silent truncation.
5. **Backup.**
   - **Scheduled run:** pass if the CronJob, not a manual trigger, creates a
     new snapshot covering the dump volume, video and Jellyfin config, and
     the snapshot's `.done` run ID equals that job's run.
   - **Freshness guard:** make the dump fail (wrong password in a test
     run). Pass: the restic stage does not run and no snapshot is created.
   - **Check:** `restic check --read-data` passes.
   - **Restore:** restore into an empty volume. Pass:
     - the checksums match the fixtures and the `.done` sha256s;
     - the dump loads into a fresh postgres, with row counts equal to the
       dump's `counts.post`.
6. **OS-disk reinstall and import.** Record `pvs; vgs; lvs; findmnt`, the
   VG/LV UUIDs and the checksums. Then:
   - reinstall the control plane's OS disk only (`vm --reinstall`; the data
     disks are untouched);
   - reinstall the worker too, because its join credentials die with the old
     control plane; its backup data disk is also untouched;
   - delete both old Tailscale devices first;
   - let the cluster come up, run the bootstrap, and let Argo CD resync
     everything from git.

   The production data-disk initialisation script is never run. The import
   path only activates (initrd) and mounts. Pass:
   - identical VG/LV UUIDs and checksums;
   - the static PVs bind again and the pods read the same checksums;
   - the marker rows are present;
   - all Applications return to `Synced`/`Healthy` within **30 min** of the
     control plane's first boot, with no manual step except the bootstrap
     task;
   - the host firewall is effective again: enforcing on both nodes, and
     Phase 2's denial probes all fail;
   - both nodes are back under their old tailnet names;
   - the worker's restic repository still holds the pre-reinstall
     snapshots, and `restic check` passes.

   This is also a first look at the bow-reinstall story. The cluster state is
   lost (etcd restore is Phase 5), and git plus the imported data are enough
   to restore service.

Exit: as the plan says. Also record every place a workload needed something
Kubernetes on Bluefin doesn't give by default: the Tailscale operator for
Buildbarn, the LVM workaround, UID handling, and anything found during
implementation. Give the cost of each workaround.

## Risks and open points

- **Memory.** It fits only once the add-ons are torn down (see the budget).
  Don't resize the VM: that changes the stand-in for bow. If the budget
  still doesn't hold, record which workload moves to the worker.
- **Mount failure.** The path rule is the guarantee, and ordering only makes
  the mount happen first. Step 0's negative test is the evidence.
- **Unproven until implementation:** KSOPS on Argo CD v3.5.3, operator
  support for a Tailscale Service versus a device per Service, unsigned
  sysext acceptance, and initrd activation completing before switch-root.
  Each is gated by the first step that uses it.
- **The template's Argo CD isn't ours.** A Bluefin update can change it
  (Phase 5). Whatever D2 patches has to be re-checked on every release bump.
- **Image registry pulls** go over QEMU NAT. They are slow but not a gate.
- **Public repository:** no tailnet name, IP or secret in plaintext. Same
  redaction check as Phase 2 before every commit.
- Step 6 wipes the Phase 2 cluster. The Phase 2 evidence is already
  committed.
