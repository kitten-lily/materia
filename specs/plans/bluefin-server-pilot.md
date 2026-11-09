# Plan: Bluefin Server homelab pilot

Date: 2026-11-06, revised 2026-11-09 after a cross-model review (reboot
control, Materia pin and state, restic soak evidence, network denial tests,
edge restart scope, pass thresholds), and again on 2026-11-09 after Phase 0
findings: services move to Kubernetes instead of running under Materia, and
the Hetzner edge worker uses cpx22. Status: Phase 0 in progress, see
[results](bluefin-server-pilot-results.md).
Companion: [feasibility investigation](bluefin-server-investigation.md).

## Outcome

Demonstrate that an installed Bluefin Server control plane and cloud worker
can run the requested homelab templates, and that bow's and flutterina's
services can run as Kubernetes workloads on that cluster. Produce evidence
sufficient to decide whether to migrate bow and flutterina, plus a separate
decision for krytis-runner.

**Direction (operator decision, 2026-11-09):** if Bluefin Server is adopted,
services move to Kubernetes-native deployment, reconciled from git by Argo CD
(shipped in the homelab templates). Materia is replaced, not kept beside
Kubernetes. Phase 0 found that Bluefin's Podman sysext is rootless-only with
no Quadlet generator (results, F2), which would have made running Materia on
Bluefin a self-maintained sysext anyway. Materia keeps running the Flatcar
fleet until a production migration replaces it host by host.

Bluefin Server 26.11 is **Beta**, announced November 3, 2026. This supersedes
the stale Alpha label encountered in the repository README. Beta changes the
release-status assessment; runtime, provider, and cross-site compatibility
still need measurement.

This plan covers disposable pilot infrastructure and copied/synthetic data.
Production migration, public DNS cutover, Pangolin database/HA changes, and
production runner replacement require follow-on plans informed by the results.
The earlier user-directed Pangolin HA work in issue #102 remains a separate
requirement; this pilot does not silently replace it with a standalone test.
Writing this plan does not provision paid resources or deploy anything.

## Pilot topology and resources

| Machine | Role | Starting allocation | Purpose |
| --- | --- | --- | --- |
| bluefin-pilot-cp | Installed homelab-control-plane VM on available home-side virtualization | 4 vCPU, 8 GiB RAM, 64 GiB OS disk, two disposable data disks | Stand-in for bow, persistent etcd, workload/storage testing |
| bluefin-pilot-node | Installed homelab-node VM on the same virtualization host | 2 vCPU, 4 GiB RAM, 40 GiB disk | Establish basic joining before testing WAN routing |
| bluefin-pilot-edge | Disposable installed Hetzner homelab-node | cpx22 (2 vCPU, 4 GB): CX is unorderable and boots legacy BIOS; cpx boots UEFI (results, F1) | Provider install/recovery, WAN routing and edge workloads |
| bluefin-pilot-runner | Optional separate worker/build environment | Size from actual runner inventory | Krytis build feasibility, after core gates pass |

These are starting test allocations, not upstream minimums or capacity claims.
If home virtualization is unavailable, identify another home-side host before
starting; do not install the pilot over bow. Keep the local worker available
for comparison through WAN tests. Run only one paid pilot VM at a time by
default; record its hourly cost, storage, public IP charges, and deletion date
before creation. Use a maximum 7-day cloud pilot unless deliberately extended.

Each pilot gets a unique hostname, VPN identity, join credential, and secrets.
Argo CD reconciles from a pilot-only git source/ref holding the pilot
manifests and pilot-only secrets (encrypted with a pilot-only key). Do not
copy the fleet-wide age private key or live Newt/Tailscale identities. Use a test backup repository and synthetic database
contents. Any restore using real data must remain private and retain separate
identities, domains and outbound integrations to avoid duplicate side effects.

## Release and deliverables

Initial candidate: [v26.11.1701](https://github.com/projectbluefin/server/releases/tag/v26.11.1701),
published 2026-11-06 from commit
`b928b45bd7a0633de04febf3d654fa084c182e00`.
Pin downloaded asset hashes and the trusted signing-key fingerprint, not just
the tag: the GitHub API reports this release as `immutable: false`.
Use templates and sysexts from the same release. Record Kubernetes/Cilium
versions from those artifacts. Select a second verified release for update
testing and check Kubernetes minor compatibility before proceeding.

Proposed implementation artifacts, to be written during execution:

- `specs/plans/bluefin-server-pilot-results.md`: phase evidence, timings,
  resource usage, defects, and per-host go/no-go decisions.
- `provisioning/bluefin/`: release lock/checksum metadata and shared Butane
  fragments for installed control plane/worker, VPN bootstrap, and runtime
  compatibility, with all environment-specific values supplied externally.
- `.mise/tasks/bluefin/pilot/`: create/render/inspect/verify/cleanup tasks.
  Default inspection is read-only; install and deletion target only explicitly
  named pilot resources. Reject production hostnames and ambiguous disks.
- Pilot Kubernetes fixtures: persistent-volume writer, HTTP service, scheduled
  workload, and cross-node connectivity tests with pinned image digests.
- Pilot workload manifests for the Phase 3 and 4 services (database, media
  app, Buildbarn, backup job, Pangolin edge pod), pinned by digest and
  reconciled by Argo CD from the pilot source. Where they live (this repo or a
  new one) is decided when Phase 3 starts and recorded in the results.

There are no such task implementations yet. Commands below use existing OS
tools as verification probes; exact fixture names and runtime paths must be
recorded by the implementation before a phase is marked passed. Unimplemented
checks remain pending rather than being counted as evidence.

Pass thresholds below are starting values. Record the final value for each in
the results file **before** the phase starts; changing a threshold after its
results are in voids that gate. A measurement with no threshold is
informational and never passes a gate on its own.

## Phase 0 — Baseline, release verification, and recovery access

1. Inventory read-only host facts: firmware mode, CPU/RAM, disks/UUIDs, mounts,
   active runtime paths, VPN/firewall configuration and current service health.
   Record the current production baseline without load-testing the edge.
   Include the Materia image digest actually running on each host (not the
   template pin; see the upgrade gotcha in `AGENTS.md`), and flutterina's
   peak request rate, concurrent connections and throughput over the last 30
   days from existing monitoring. Phase 4's load profile is derived from that
   baseline. Verify: `hostnamectl; test -d /sys/firmware/efi; free -h;
   lsblk -f; findmnt; systemctl cat materia-update.service | grep Image=;
   podman image inspect --format '{{.Digest}}' <that image>`.
2. Identify home-side virtualization and UEFI support, space for the proposed
   VMs, and out-of-band console access. Record available memory and disk;
   reduce parallel pilot allocations if needed. Verify: `virt-host-validate`
   on a libvirt host, plus a successful UEFI disposable VM console boot.
3. Download the pinned installer, template sources, manifest/signature and
   signing key from the pinned source. Verify trust independently of the
   downloaded checksum file. Verify: `gpgv --keyring ./import-pubring.gpg
   SHA256SUMS.gpg SHA256SUMS` then
   `sha256sum --check --ignore-missing SHA256SUMS`; require every selected
   asset to be listed and checked, not merely an overall successful exit.
4. Record restore inputs and provider rescue/console procedures; configure a
   pilot-only VPN enrollment policy and separate secrets. Verify: successful
   console access with guest networking disconnected, and recovery boot from
   the installer on the disposable VM.
5. Write down the network posture before any pilot node is created: the
   Tailscale netfilter mode per node (decided against the firewall backend the
   Bluefin image actually uses, not copied from flutterina's Flatcar-specific
   `--netfilter-mode=off`), the host firewall, and the pilot Hetzner firewall
   rules. The cloud firewall has no public tcp/22, 6443, 6447 or 10250 rule;
   SSH goes over the tailnet, with the provider console as fallback.
   Verify: the posture is recorded in the results file and the pilot firewall
   exists (`hcloud firewall describe <pilot-firewall>`) before Phase 4 creates
   a server. Decided 2026-11-09 (results, Phase 0 step 5): netfilter mode
   off, Cilium host policies as the host firewall, firewall `bluefin-pilot`
   created.

Exit: exact artifacts identified, signature verified, resource budget and
network posture recorded, and no production disks or credentials attached to
pilot installation.

## Phase 1 — Installed local control plane and worker

1. Customize `homelab-control-plane.bu` for bluefin-pilot-cp and
   `homelab-node.bu` for bluefin-pilot-node. Preserve the upstream sysext fetch
   ordering and the explicit kubeadm-init symlink. Inject SSH access and join
   credentials privately. Render with the repo-pinned Butane if compatible;
   otherwise pin the required Butane before rendering. Disable every
   automatic update and reboot mechanism before first boot (results, F3):
   `HOMELAB_KURED=no` in `homelab.conf`, and disable `systemd-sysupdate.timer`
   and `systemd-sysupdate-reboot.timer` (which also stops
   `bluefin-fleet-reboot.timer`, `PartOf=` it). That keeps the pilot on the
   pinned release and stops unscheduled reboots from invalidating the
   database, restore and capacity tests in Phases 1–4. Both stay off until
   Phase 5 enables them deliberately. Verify: `butane --strict --pretty <
   homelab-control-plane.bu > cp.ign` and the corresponding worker render,
   stored in ignored private output; after boot,
   `kubectl get daemonset -A | grep -i kured` shows none, and
   `systemctl is-enabled systemd-sysupdate.timer
   systemd-sysupdate-reboot.timer` reports both disabled or masked.
2. Install to the disposable OS disks in UEFI mode. Match Secure Boot trust
   to the upstream installer; record any explicit insecure exception and
   treat that exception as a provider constraint. Verify: `bootctl status;
   findmnt /usr; systemd-sysext list; systemctl --failed`.
3. Establish baseline joining on the LAN, then select an explicit private API
   endpoint before the WAN cluster is initialized. Set
   `HOMELAB_CONTROL_PLANE=host[:port]` on every node so joining never depends
   on mDNS. If this requires changing
   an initialized endpoint, rebuild the disposable cluster deliberately.
   Verify: `kubectl get nodes -o wide; kubectl get pods -A -o wide;
   kubectl get --raw='/readyz?verbose'` and successful worker join.
4. Verify actual default components and add-ons, access controls, and PVC
   provisioning. Set no public ingress. If testing MetalLB, use a reserved
   test LAN pool restricted to home-side nodes. Verify:
   `kubectl get storageclass; kubectl get pvc -A; kubectl get gateway -A`;
   persist a known checksum to a PVC and verify it after a guest reboot.
5. Reboot both nodes twice, one at a time. Verify node UIDs remain stable,
   etcd/cluster state persists, the worker rejoins without a fresh identity,
   and no manual unit enabling is needed. Verify:
   `kubectl get nodes -o custom-columns=NAME:.metadata.name,UID:.metadata.uid`.

Exit: persistent two-node cluster and authenticated private add-on access;
no failed units, unresolved pod failures, or repeated credential prompts.

## Phase 2 — Host VPN and cross-site networking

1. Bootstrap host Tailscale independently of Kubernetes, preferably using the
   first-party extension. It must start before kubeadm and survive a broken
   CNI. Keep pilot tags separate from production gateway tags. Use the
   netfilter mode recorded in Phase 0 step 5 and confirm it does not mix
   iptables backends with Cilium. `tailscaled.service` is disabled by preset
   in the Tailscale sysext, so the Butane enables it. Verify:
   `ip address show tailscale0; tailscale status; systemctl status tailscaled;
   tailscale debug prefs | grep -i netfilter; nft list ruleset` (no rules in
   tables owned by another backend).
2. Configure workers' explicit control-plane join address on TCP 6447 and
   kubeadm's private API endpoint on TCP 6443 with matching SANs. Select
   kubelet InternalIPs and Cilium devices, routing/tunnel mode and MTU
   deliberately. Check LAN, pod, service, Tailscale and Gerbil CIDRs
   for overlap before init. Verify: `kubectl get nodes -o wide` and
   `openssl s_client -connect "$PILOT_API_HOST:6443" -servername
   "$PILOT_API_HOST" </dev/null` with the pilot CA and hostname validation
   configured for the actual endpoint.
3. First emulate a routed worker with multicast unavailable; then repeat on
   the Hetzner worker in Phase 4. Permit only required traffic on VPN links,
   including API, join, kubelet and the selected Cilium transport. Do not
   import bow's Flatcar firewall or flush runtime-managed rules.
   Verify: `cilium status --wait; cilium connectivity test` from a pinned CLI
   matching the installed Cilium, with test endpoints placed on both sites.
   Apply the Cilium host firewall policies chosen in Phase 0 step 5
   (`CiliumClusterwideNetworkPolicy` with a node selector; enable Cilium's
   host firewall first) and record them in the pilot source. Also prove what
   must fail: from a host outside the tailnet, over both
   public IPv4 and IPv6, connections to 6443, 6447, 10250 and the Cilium
   transport port are refused or time out (`nc -vz -w 5 <addr> <port>` per
   port and address family, every one failing).
4. Exercise cross-node DNS, ClusterIP, pod-to-tailnet traffic, large
   payloads, and sustained connections. Drop only the pilot VPN path for 10 minutes,
   then restore it. Verify node recovery, workload behavior and DNS without
   manual repair using `kubectl get nodes; kubectl get pods -A` and repeated
   checksum-verified HTTP transfers through the fixture Service.

Pass thresholds: within 5 minutes of the VPN path returning, every node is
`Ready` and fixture transfers succeed again with no manual repair; zero
checksum mismatches across the whole test; API `readyz` p95 over the VPN under
500 ms while the path is up.

Exit: hostname/SAN, routing, MTU and firewall settings reproducible; denial
tests pass; no mDNS dependency across sites; thresholds above met, with API
latency and recovery time recorded. If WAN routing
cannot be made reliable, recommend separate clusters rather than stretching
this one; do not silently change the requested topology during the test.

## Phase 3 — Persistent services as Kubernetes workloads

Replaces the earlier Materia-coexistence phase (see Outcome). The goal is to
show that each kind of service bow runs today works as an Argo CD-reconciled
Kubernetes workload, with the failure modes recorded in `AGENTS.md` checked
again in their Kubernetes form.

1. Point the template's Argo CD root Application (`HOMELAB_ARGOCD_ROOT_REPO`,
   `_REVISION`, `_PATH`) at the pilot source. Sync, then push a deliberate
   fixture change, then hand-edit a managed object. Verify: `kubectl -n
   argocd get applications` shows every app `Synced`/`Healthy`; the pushed
   change rolls out with no manual step; the hand edit is reverted
   (self-heal on). Record the sync interval and how a sync failure surfaces.
2. Choose and test one secrets mechanism (SOPS through an Argo CD plugin,
   sealed-secrets or external-secrets), with a pilot-only key. Verify: a
   fixture consumes a secret; after rotating it in git the consumer sees the
   new value after its rollout (the stale-secret failure in `AGENTS.md` is
   exactly this check); no secret value appears in git, events or logs.
3. Expose existing data to pods. bow's libraries are pre-existing
   directories on the data LV, so use static local PersistentVolumes with
   node affinity rather than the dynamic local-path provisioner: read-only
   where the app only reads, and one read-write volume over the whole
   `video/` subtree where the app hardlinks (the cross-mount hardlink
   gotcha). Verify: fixture checksums from inside the pod; the media
   manager's startup hardlink check passes; a read-only mount refuses a
   write.
4. Run representative workloads, each pinned by digest:
   - a database (PostgreSQL StatefulSet, setting `PGDATA` explicitly per the
     postgres 18 gotcha) with an app gated on its readiness;
   - one media app on the static volumes (no `/dev/dri` in a VM; that check
     stays a bow hardware gate);
   - Buildbarn `bb-storage` + `bb-asset` with test JWT credentials and the
     CAS blocks file on a local volume, reachable from the tailnet by the
     method chosen in Phase 2 (Tailscale operator or host Tailscale), with
     the TLS SAN matching that name.
   Verify: readiness probes pass; database rows survive pod deletion and a
   node reboot; a checksum-matched BuildStream artifact round-trip from a
   tailnet client.
5. Back up with a scheduled job (the existing restic image as a CronJob, or
   Velero) to a test repository, covering the database dump and the
   persistent volumes. Verify: a scheduled run creates a new snapshot;
   `restic check`; a restore to an empty volume matches fixture checksums.
6. Build a VG/LV on the two disposable data disks, write checksum fixtures,
   then reinstall only the VM OS disk and import the existing VG. Do not
   execute the current production data-disk initialization script on import.
   Verify: `pvs; vgs; lvs; findmnt` and fixture checksums before and after
   reinstall, then the step 3 volumes bind again unchanged. Missing LVM
   tooling becomes an explicit compatibility task and blocks bow readiness.

Exit: Argo CD reconciles every pilot workload from git; data survives pod
rescheduling, node reboot and OS-disk reinstall; secret rotation and backup
restore are proven. Record any service that needs something Kubernetes on
Bluefin cannot give it (host networking, devices, privileged mode), with the
cost of the workaround.

## Phase 4 — Disposable Hetzner edge worker

1. Create a separately named cpx22 in flutterina's region (hel1), with the
   pilot firewall from Phase 0 step 5 attached at creation, using a tested
   rescue/install path. Phase 0 confirmed that cpx types boot UEFI and that
   Secure Boot is unavailable; record that as a provider constraint. The
   release OS DDI is not a ready-to-upload provider root-disk image.
   Verify: `test -d /sys/firmware/efi; bootctl status; findmnt` after disk
   boot, and boot again without rescue media.
2. Join the pilot cluster over the VPN and repeat Phase 2's connectivity,
   denial and interruption tests. Taint the edge node so only edge workloads
   and fixtures schedule there; cloud nodes must not announce bow's LAN
   MetalLB pool. Verify: `kubectl get nodes -o wide; cilium connectivity
   test`, and inspect MetalLB speaker placement/announcement policy.
3. Run Pangolin as **one Kubernetes pod** with the app, Gerbil and Traefik
   containers. Containers in a pod share one network namespace, which keeps
   the locked shared-namespace architecture (Traefik must reach Gerbil's
   tunnel IPs). Use `hostNetwork: true` so the public ports (443/tcp,
   443/udp, 51820/udp, 21820/udp) bind on the node, `NET_ADMIN` for Gerbil,
   a node selector plus toleration for the edge node, and state on a local
   volume. Host Podman is not a fallback here: Bluefin's Podman is
   rootless-only (results, F2). Use test domains, staging ACME and synthetic
   application data, never production identities. Verify: all three
   containers ready; `ss -lntup` on the node shows exactly the intended
   public ports; external HTTP/TLS, HTTP/3, tunnel and health-check requests
   against pilot endpoints; the Phase 2 denial tests still pass with
   `hostNetwork` in use. Confirm SSH works over the tailnet and that the
   provider console still reaches a login with `tailscaled` stopped.
4. Restore the isolated edge state into a fresh pod on a clean volume, then
   test two restarts while Kubernetes traffic is active: (a) kill the app
   container's process, so the kubelet restarts that container only while the
   pod and its network namespace stay; (b) delete the whole pod. Gerbil and
   Traefik need the app, so a short ingress outage is expected; the gate is
   that it stays short and recovers without manual action or a crash loop.
   Verify: for (a) the pod UID is unchanged and only the app's
   `restartCount` increments; all three containers return to ready; endpoint
   probes and the database readiness query pass afterwards. Pass: external
   probe outage at most 2 minutes for (a) and at most 5 minutes for (b),
   measured from the probe log.
5. Measure 48 hours at cpx22 size with a load profile fixed before the run:
   synthetic HTTPS traffic at 2× the peak request rate and concurrency from
   the Phase 0 baseline, plus a sustained tunnel transfer at flutterina's
   recorded peak throughput for at least 1 hour per day. cpx22 runs a newer
   CPU generation than flutterina's cx23, so this sizes the cpx22, not the
   current box. Verify: `free -h; df -h; journalctl -k --since '48 hours
   ago'` plus sampled CPU/RAM/disk and HTTP error rates. Require zero OOMs,
   zero kubelet pressure/eviction events, at least 25% measured RAM/disk
   headroom, and an HTTP 5xx/connection-error rate below 0.1% outside
   deliberate restarts.
   If it fails, report the larger required size and cost; do not declare
   flutterina's current sizing sufficient.

Exit: provider install/recovery works, cross-site worker is stable, and the
Pangolin pod serves ingress beside cluster networking at a measured capacity.

## Phase 5 — Updates, failures and recovery

1. Back up etcd using a matching etcd client and restore into an isolated
   replacement control-plane VM. Record exact version-specific snapshot and
   restore commands in the results. Verify: `kubectl get --raw='/readyz';
   kubectl get pvc -A` and previously written data checksums after recovery.
2. Upgrade one worker to the second pinned release, then the control plane
   only after checking version-skew rules. If crossing Kubernetes minors,
   follow the documented kubeadm upgrade sequence; an OS update alone is
   insufficient. Verify: `updatectl list; systemd-sysext list;
   kubectl get nodes -o wide; systemctl --failed` and repeat fixture probes.
3. Exercise A/B fallback with a disposable VM and the upstream failed-boot
   test procedure. Record the exact injection/recovery commands and observed
   version; avoid editing production slots. Verify: `bootctl status;
   cat /usr/lib/os-release; systemctl --failed` after fallback. Confirm data
   survives; do not infer application schema rollback from OS fallback.
   Also test the boot health gate (results, F3): on a boot-counted boot, a
   failed host unit must trigger the deadline reboot and fallback, while a
   crash-looping pod (not a systemd unit) must not. Record both outcomes.
4. Test shutdown/drain and control-plane unavailability while workloads and
   backup jobs run. Enable the automatic update and reboot mechanisms
   disabled in Phase 1 for the first time, with an interlock on both reboot
   paths: kured (Kubernetes nodes; for example its blocking-pod selector
   matching a long-running Job) and `systemd-sysupdate-reboot`, which honours
   `/etc/reboot-lock` and `/run/reboot-lock` and which kured ignores.
   Verify: a scheduled reboot stays deferred on each path while a
   long-running fixture job is active, then completes within the configured
   window after that job finishes; journal and timestamps are evidence.
5. Run a 72-hour final soak including two git changes reconciled by Argo CD
   with no manual action, two unattended scheduled backup runs, worker
   restart, control-plane restart and the WAN outage test. This may overlap
   the 48-hour capacity test after earlier gates pass. A schedule firing is
   not evidence that its job ran (BUG-004: the restic timer fired on
   schedule and did nothing): each backup run must create a new snapshot.
   Change the fixture data between the two runs, then restore from the second
   snapshot and match checksums of the changed data. Verify: Argo CD sync
   history shows both commits applied and the apps `Synced`/`Healthy`;
   `kubectl get jobs -A` and the backup job logs; `restic snapshots` (two new
   snapshot IDs with timestamps matching the schedule); the restore checksum
   comparison; and `kubectl get events -A --sort-by=.lastTimestamp` alongside
   externally collected uptime logs. Collect events continuously because
   Kubernetes event retention may be shorter than the soak.

Pass thresholds: a restarted worker or control plane is `Ready` with fixture
probes passing within 10 minutes; the etcd restore in step 1 completes within
60 minutes of starting from a snapshot; both Argo CD changes and both backup
runs succeed unattended.

Exit: reproducible upgrade and fallback, tested state restore, thresholds
above met, and zero unexplained failed units, data corruption, OOMs or
repeated evictions.

## Optional Phase 6 — Krytis runner

Start only after Phases 1–5 pass. Keep this on distinct infrastructure with a
unique runner label and no default labels, so production jobs cannot select it.
First test a Debian container build environment on Bluefin; consider a Debian
VM only if the provider offers the required nested virtualization. Do not run
the current apt-based host installer on Bluefin.

1. Inventory every host dependency and test bubblewrap, user namespaces,
   FUSE, privileged Podman and image tooling. Keep swap disabled on the
   Kubernetes host initially; if required, separately validate kubelet swap
   policy. Verify: successful pinned representative BuildStream build and
   `podman run --rm --privileged <pinned-test-image> true`.
2. Dispatch pilot-label-only equivalents of cache-warm, build-changed and
   build-iso, including cancellation and a second warm-cache run. Publish
   only to a test artifact destination. Verify: all workflow run URLs show
   success, ISO verification passes, canceled jobs leave no live build/FUSE
   processes, and warm-cache reuse is measured.
3. Demonstrate reboot deferral during a build, then a clean restart and next
   job pickup without registration/identity loss. Verify: build completion
   precedes reboot in timestamped logs, then a second test job succeeds.

Exit: a separate runner go/no-go report. Failure here does not invalidate a
successful bow/flutterina pilot. Keep the existing Debian runner unchanged.

## Decision and cleanup

Record a pass/fail/pending result and evidence link for every phase. Core
pilot success requires Phases 0–5; no pending gate counts as passed. Hardware
readiness for bow still requires a later non-destructive Bluefin boot proving
its NIC, LVM activation, `/dev/dri` transcoding and USB unlock/mount behavior.
The recorded current USB token has no PCR binding; do not assume the new boot
chain requires re-enrollment without inspecting/testing the actual token.

The final report must distinguish:

- bow: runtime, persistent state and network proven in VMs; hardware checks
  either passed separately or explicitly pending;
- flutterina: provider boot/recovery, edge functionality and required size;
- krytis-runner: tested build environment or deferred with concrete blockers;
- operations: measured restore time, expected migration outage, ongoing
  maintenance burden, monthly cost, and remaining production work,
  including the per-service effort to move each Materia component to Argo CD
  manifests.

On a failed gate, retain redacted evidence and either repair the pilot or stop
that phase. Recovery is deletion/recreation of disposable pilot resources;
production service is not a rollback dependency. Export evidence and needed
snapshots before teardown. Remove pilot VMs, volumes, snapshots, IPs, firewall
objects, VPN identities, enrollment keys and optional runner registration.
Verify provider inventory and billing resources are empty for the pilot labels,
`tailscale status` no longer lists pilot nodes, and no pilot runner remains
registered. Retain only explicitly requested reusable artifacts.

## Validation and handoff

This is a documentation change. Check whitespace and local Markdown links;
no Ignition renders, secret fetching, provisioning or live tests are necessary
to validate the plan itself. During implementation, run the repository's
required preflight and applicable CI gates before infrastructure changes.
The referenced bigpowers planning skills are absent from installed catalogs;
the plan is recorded directly here, with no IaC generated.

Next action: Phase 0 inventory and artifact verification, followed by writing
the local VM render/launch/verification tooling. Production conversion remains
a separate rollout after the evidence has been reviewed.

## Sources

- [Official Beta announcement, November 3](https://docs.projectbluefin.io/blog/bluefin-server-beta/)
- [Pinned release and installation assets](https://github.com/projectbluefin/server/releases/tag/v26.11.1701)
- [Pinned homelab templates and behavior](https://github.com/projectbluefin/server/blob/b928b45bd7a0633de04febf3d654fa084c182e00/docs/skills/homelab-profile.md)
- [Pinned runtime extension contract](https://github.com/projectbluefin/server/blob/b928b45bd7a0633de04febf3d654fa084c182e00/docs/skills/systemd-sysext-extensions.md)
- [Pinned install/update architecture](https://github.com/projectbluefin/server/blob/b928b45bd7a0633de04febf3d654fa084c182e00/docs/skills/ddi-installer.md)
