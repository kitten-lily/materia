# Plan: Bluefin Server homelab pilot

Date: 2026-11-06. Status: planned; execution has not started.
Companion: [feasibility investigation](bluefin-server-investigation.md).

## Outcome

Demonstrate that an installed Bluefin Server control plane and cloud worker
can run the requested homelab templates alongside Materia's existing service
model. Produce evidence sufficient to decide whether to migrate bow and
flutterina, plus a separate decision for krytis-runner.

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
| bluefin-pilot-cp | Installed homelab-control-plane VM on available home-side virtualization | 4 vCPU, 8 GiB RAM, 64 GiB OS disk, two disposable data disks | Stand-in for bow, persistent etcd, Materia/storage testing |
| bluefin-pilot-node | Installed homelab-node VM on the same virtualization host | 2 vCPU, 4 GiB RAM, 40 GiB disk | Establish basic joining before testing WAN routing |
| bluefin-pilot-edge | Disposable installed Hetzner homelab-node | CX23 first, matching flutterina | Provider install/recovery, WAN routing and edge coexistence |
| bluefin-pilot-runner | Optional separate worker/build environment | Size from actual runner inventory | Krytis build feasibility, after core gates pass |

These are starting test allocations, not upstream minimums or capacity claims.
If home virtualization is unavailable, identify another home-side host before
starting; do not install the pilot over bow. Keep the local worker available
for comparison through WAN tests. Run only one paid pilot VM at a time by
default; record its hourly cost, storage, public IP charges, and deletion date
before creation. Use a maximum 7-day cloud pilot unless deliberately extended.

Each pilot gets a unique hostname, VPN identity, join credential, and secrets.
Use a pilot-only Materia source/ref with explicit pilot host assignments and
restricted test attributes. Do not copy the fleet-wide age private key or live
Newt/Tailscale identities. Use a test backup repository and synthetic database
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

There are no such task implementations yet. Commands below use existing OS
tools as verification probes; exact fixture names and runtime paths must be
recorded by the implementation before a phase is marked passed. Unimplemented
checks remain pending rather than being counted as evidence.

## Phase 0 — Baseline, release verification, and recovery access

1. Inventory read-only host facts: firmware mode, CPU/RAM, disks/UUIDs, mounts,
   active runtime paths, VPN/firewall configuration and current service health.
   Record the current production baseline without load-testing the edge.
   Verify: `hostnamectl; test -d /sys/firmware/efi; free -h; lsblk -f; findmnt`.
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

Exit: exact artifacts identified, signature verified, resource budget recorded,
and no production disks or credentials attached to pilot installation.

## Phase 1 — Installed local control plane and worker

1. Customize `homelab-control-plane.bu` for bluefin-pilot-cp and
   `homelab-node.bu` for bluefin-pilot-node. Preserve the upstream sysext fetch
   ordering and the explicit kubeadm-init symlink. Inject SSH access and join
   credentials privately. Render with the repo-pinned Butane if compatible;
   otherwise pin the required Butane before rendering.
   Verify: `butane --strict --pretty < homelab-control-plane.bu > cp.ign`
   and the corresponding worker render, stored in ignored private output.
2. Install to the disposable OS disks in UEFI mode. Match Secure Boot trust
   to the upstream installer; record any explicit insecure exception and
   treat that exception as a provider constraint. Verify: `bootctl status;
   findmnt /usr; systemd-sysext list; systemctl --failed`.
3. Establish baseline joining on the LAN, then select an explicit private API
   endpoint before the WAN cluster is initialized. If this requires changing
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
   CNI. Keep pilot tags separate from production gateway tags. Verify:
   `ip address show tailscale0; tailscale status; systemctl status tailscaled`.
2. Configure workers' explicit control-plane join address on TCP 6447 and
   kubeadm's private API endpoint on TCP 6443 with matching SANs. Select
   kubelet InternalIPs and Cilium devices, routing/tunnel mode and MTU
   deliberately. Check LAN, Podman, pod, service, Tailscale and Gerbil CIDRs
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
4. Exercise cross-node DNS, ClusterIP, Podman-to-VPN traffic, large payloads,
   and sustained connections. Drop only the pilot VPN path for 10 minutes,
   then restore it. Verify node recovery, workload behavior and DNS without
   manual repair using `kubectl get nodes; kubectl get pods -A` and repeated
   checksum-verified HTTP transfers through the fixture Service.

Exit: hostname/SAN, routing, MTU and firewall settings reproducible; no mDNS
dependency across sites. Record API latency and recovery time. If WAN routing
cannot be made reliable, recommend separate clusters rather than stretching
this one; do not silently change the requested topology during the test.

## Phase 3 — Materia and persistent service compatibility

1. Enable/fetch Bluefin's Podman extension, then inspect its actual binaries,
   units and generators. Current documentation describes private binaries and
   rootless sockets; prove a rootful compatibility layer before adopting
   Materia. Verify: `systemd-sysext list; systemctl cat podman.socket;
   systemctl cat materia-update.service` after integration, recording the
   resolved executable, socket and generator paths. Missing units fail the
   gate. Do not point Materia at a rootless socket and assume equivalence.
2. Make rootful Quadlet, API socket, secrets, network creation and writable
   helper placement work without changing immutable `/usr`. Preserve
   Kubernetes' containerd/CNI. Verify: `podman info; podman network ls;
   podman secret ls; systemctl status podman.socket` plus a secret-consuming
   test Quadlet that survives restart and reboot without exposing its value.
3. Run pinned Materia v0.8.0 against explicit pilot host assignments and
   pilot-only attributes. Apply twice, then test a deliberate fixture change.
   Verify: `systemctl start materia-update.service;
   journalctl -u materia-update.service -b --no-pager`; confirm the second
   run changes nothing and the fixture update restarts only intended units.
4. Exercise one representative database service, a media bind mount,
   Buildbarn push/pull using test credentials, and restic to a test repository.
   Verify: application readiness queries, a checksum-matched BuildStream
   artifact round-trip, and `restic check` plus a restore to an empty directory.
5. Build a VG/LV on the two disposable data disks, write checksum fixtures,
   then reinstall only the VM OS disk and import the existing VG. Do not
   execute the current production data-disk initialization script on import.
   Verify: `pvs; vgs; lvs; findmnt /var/lib/materia-data` and fixture checksums
   before and after reinstall. Missing LVM tooling becomes an explicit
   compatibility task and blocks bow readiness.

Exit: Materia rootful operations and Kubernetes coexist across reboot;
restored database/media/cache fixtures work, data-disk import is non-destructive.
If rootful integration needs a maintained custom runtime image, record that
cost and reconsider the migration before adding more service tests.

## Phase 4 — Disposable Hetzner edge worker

1. Create a separately named CX23 in flutterina's configured region using a
   tested rescue/install path. Confirm firmware mode first. The release OS
   DDI is not a ready-to-upload provider root-disk image. If UEFI cannot be
   supplied, stop this provider phase; legacy BIOS diskless boot does not
   establish installed-node update/recovery feasibility.
   Verify: `test -d /sys/firmware/efi; bootctl status; findmnt` after disk boot,
   and boot again without rescue media.
2. Join the pilot cluster over the VPN and repeat Phase 2's connectivity and
   interruption tests. Restrict workload placement to fixture pods; cloud
   nodes must not announce bow's LAN MetalLB pool.
   Verify: `kubectl get nodes -o wide; cilium connectivity test` and inspect
   MetalLB speaker placement/announcement policy.
3. Run an isolated Pangolin/Gerbil/Traefik pod preserving the repository's
   shared network namespace. Use test domains, staging ACME and synthetic
   application data, never production identities. Exercise the same public
   port set without opening Kubernetes API/join/kubelet to the internet.
   Verify: `podman pod inspect pangolin; ss -lntup` and external HTTP/TLS,
   tunnel and health-check requests against pilot endpoints.
4. Restore the isolated edge state to a fresh pilot instance or clean disk,
   then test a service restart while Kubernetes traffic is active. Verify
   HTTPS/tunnel continuity, database contents and expected recovery time.
   Verify: repeat the endpoint probes and database readiness query after
   restoring; record elapsed outage from the external probe log.
5. Measure 48 hours at CX23 size with representative workload and traffic.
   Verify: `free -h; df -h; journalctl -k --since '48 hours ago'` plus sampled
   CPU/RAM/disk and HTTP error rates. Require zero OOMs, zero kubelet
   pressure/eviction events and at least 25% measured RAM/disk headroom.
   If it fails, report the larger required size and cost; do not declare
   flutterina's current sizing sufficient.

Exit: provider install/recovery works, cross-site worker is stable, and
Pangolin ingress coexists with cluster networking at a measured capacity.

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
4. Test shutdown/drain and control-plane unavailability while Materia jobs
   and services run. Implement an interlock for host jobs before enabling
   unattended reboots. Verify: a scheduled reboot stays deferred while a
   long-running fixture job is active, then completes within the configured
   window after that job finishes; journal and timestamps are evidence.
5. Run a 72-hour final soak including two unattended Materia timer fires,
   worker restart, control-plane restart and the WAN outage test. This may
   overlap the 48-hour capacity test after earlier gates pass.
   Verify: `systemctl list-timers --all; journalctl -u materia-update.service
   --since '72 hours ago'; kubectl get events -A --sort-by=.lastTimestamp`
   alongside externally collected uptime logs. Collect events continuously
   because Kubernetes event retention may be shorter than the soak.

Exit: reproducible upgrade and fallback, tested state restore, bounded recovery,
and zero unexplained failed units, data corruption, OOMs or repeated evictions.

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
  maintenance burden, monthly cost, and remaining production work.

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
