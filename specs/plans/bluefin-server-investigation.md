# Bluefin Server feasibility: bow, flutterina, krytis-runner

Investigation date: 2026-11-06. Investigation only; no host changes, rendered
credentials, installs, runner registration changes, or deployment performed.

## Recommendation

Proceed with a disposable installed VM pilot, then bow as a persistent
`homelab-control-plane`, then flutterina as a persistent `homelab-node`.
Keep krytis-runner on Debian until an isolated runner pilot passes actual build
workflows. These are conditional feasibility findings, not deployment readiness.
Correction: Bluefin Server 26.11 was announced as **Beta** on November 3,
2026. The repository README's Alpha status was stale when consulted.
See the [official announcement](https://docs.projectbluefin.io/blog/bluefin-server-beta/).
The executable pilot scope is planned in [bluefin-server-pilot.md](bluefin-server-pilot.md).

The templates create one kubeadm cluster: bow is its sole control plane and the
other machines are workers. They do not automatically convert Materia workloads
into Kubernetes workloads or establish Pangolin HA. Keep those architecture
changes separate. A home control-plane outage would stop cluster management;
existing worker pods may continue, but scheduling and reconciliation need bow.

## Evidence and limits

Read local Materia manifests, server definitions, bare-metal provisioning,
adoption renderer, Tailscale components, USB unlocking, Pangolin pod, and the
earlier issue-102 Hummingbird plan. Read Krytis's runner provisioning and CI
runner documentation. Upstream main resolved to
`b928b45bd7a0633de04febf3d654fa084c182e00` during investigation; main can move,
so select and verify a matching immutable release for the pilot.

Live inspection was unavailable: `rex hosts --json` was denied access to the
local Rex socket. No live firmware, CPU/RAM, disks, mounts, firewall, provider
console, or build execution was verified. Repository statements about hosts
remain configuration evidence, not confirmation of current runtime state.

## What Bluefin actually provides

Bluefin Server is FSDK-based, DDI-first, with a verity-protected `/usr`, signed
UKIs, systemd-sysinstall, and A/B systemd-sysupdate. It is not the Fedora bootc
target in issue #102. Its OCI artifact distributes the release set; it must not
be assumed to be a bootc-installable OS image. The old Hummingbird image-builder
and provider-upload plan cannot simply substitute a Bluefin image reference.

Both requested templates use Butane fcos 1.7.0 and enable kubeadm/homelab sysext
fetching and key-only root SSH. The control-plane template explicitly links
kubeadm-init and enables Argo Workflows, MCP, and KubeStellar add-on sysexts.
The node template joins an existing cluster. Supply real SSH keys and the join
credential privately. Ignition runs on every boot carrying its config, so
filesystem operations, enabled units, and overwrite flags require review.

The control-plane default set includes Cilium, local-path provisioning,
MetalLB, Envoy Gateway, cert-manager, Argo CD, metrics-server, Reloader, and
kured. Monitoring and full KubeStellar are opt-in; the Console alone does not
mean the full multi-cluster control plane is enabled. MetalLB needs an actual
address pool for LoadBalancer addresses. Local-path storage is node-local,
not replicated storage or automatic failover.

Install all three proposed hosts to disk. Diskless defaults put state in RAM;
bow needs durable etcd, and the edge and build runner also need persistent
application state, identities, and caches.

## Host assessments

| Host | Assessment | Main work before conversion |
| --- | --- | --- |
| bow | Plausible control plane, conditional | Host VPN, durable etcd/state, Podman/Materia integration, preserve/import LVM, USB TPM recovery, firmware/hardware boot proof |
| flutterina | Plausible worker, conditional | Prove Hetzner UEFI/install/recovery, size CX23 for existing edge plus Kubernetes, preserve edge state, isolate public ingress and Kubernetes networking |
| krytis-runner | Technically plausible, larger redesign | Prove one.com boot/install support, replace Debian-native provisioning, validate real builds, coordinate CI with reboots |

### bow

Local config uses Flatcar, an OS disk reported as sda in monitoring, and two
NVMe data disks. The provisioning script builds vg_data/lv_data and mounts
`/var/lib/materia-data`; do not copy its disk-initialization operations into a
new installer. Inventory actual UUIDs and back up before selecting an OS disk.
Import the existing VG and mount the existing filesystem without formatting.
Confirm LVM/device-mapper tooling and activation on Bluefin; not proven here.

Preserve the media tree, databases, Materia configuration and secrets, rootful
Podman volumes, Buildbarn configuration/TLS material, and gateway identity.
Backup coverage must be checked: role-level restic defaults alone do not prove
that the separate data LV or consistent database snapshots are protected.

The LUKS USB backup uses systemd-cryptsetup and TPM2 auto-unlock. A new signed
boot chain may change measured-boot policy. Verify the enrolled token policy,
test the recovery key, and plan re-enrollment if needed. Also test `/dev/dri`
and Jellyfin transcoding on the actual Bluefin kernel.

### flutterina

The configured Hetzner CX23 is the sole public Pangolin edge. Its shared
Pangolin/Gerbil/Traefik network namespace and published 80/443 TCP, 443 UDP,
51820/21820 UDP must survive migration. Preserve application/database state,
ACME certificates, Newt identity, and Tailscale identity/peer-relay settings.

Test a separate Hetzner VM before rebuilding this host. Verify firmware mode,
Secure Boot or explicit insecure-install handling, console/rescue access,
network configuration, disk installation, and boot after an update. The OS
DDI is not itself a ready provider root-disk image. Do not assume existing
Flatcar snapshot tooling accepts it unchanged.

Keep the Kubernetes gateway private/on a distinct address. Do not allow
cluster ingress, hostNetwork pods, or hostPort allocations to seize Pangolin's
public ports. Restrict scheduling with labels/taints and node placement; an
L2 MetalLB pool on bow's LAN must not be announced from cloud workers. Measure
capacity before admitting generic workloads to the edge.

### krytis-runner

This is an adopted one.com Debian 13 host; Krytis owns provisioning and runner
lifecycle. Materia owns Beszel and host Tailscale only. Its installer directly
uses apt, runner dependency installation, `/opt/actions-runner`, host tools,
and an 8 GiB swapfile. Builds exercise bubblewrap/user namespaces, FUSE,
privileged Podman, filesystem/image construction, and persistent CAS storage.
The current install script cannot run unchanged on Bluefin.

Prefer a separately tested Debian build environment (VM if virtualization is
available, or a deliberately privileged container) over reproducing every
Debian package as host sysexts. The existing container runner is a starting
point, not proof of parity with the VPS's newer host build workflows. Validate
cache-warm, build-changed, build-iso, uploads, cancellation, cleanup, warm-cache
reuse, and restart behavior. Keep a pilot runner on unique labels so normal
jobs do not land on it accidentally. Confirm provider recovery and nested
virtualization before choosing a VM-based runner.

Swap and kubelet policy need explicit coordination. kured drains Kubernetes
pods; it does not observe a bare-host GitHub Actions job or a Podman runner.
Add a tested CI-aware reboot interlock, or make the runner Kubernetes-managed
with tested termination behavior, before automatic reboots. The same drain
limitation applies to bow/flutterina's Materia services.

## Cross-host blockers

1. **Routed private networking.** Stock discovery assumes an mDNS LAN. These
   hosts span home and cloud; configure `HOMELAB_CONTROL_PLANE=host:6447` on
   workers, but also configure a reachable API endpoint and certificate SANs
   before init. The join address alone does not rewrite the API endpoint
   returned by the control plane. Default preparation uses bow.local.
   Bow currently has only a userspace container gateway on newt-net, with
   specific TCP forwards. That is not a host VPN interface for kubelet/Cilium.
   Provision host-level Tailscale first, independently of Kubernetes and its
   own cluster dependencies. Select node InternalIPs, advertise address,
   Cilium devices/tunnel mode/MTU, DNS, and routes deliberately. Review private
   access to API TCP 6443, join TCP 6447, kubelet TCP 10250 and the selected
   Cilium transport; do not publish these on public interfaces. Check pod,
   service, Podman, home LAN, Tailscale, and Gerbil CIDRs for overlap. Test
   pod-to-pod, pod-to-service, DNS, restart, and WAN interruption across sites.
2. **Materia runtime contract.** Homelab enables containerd, not Podman.
   Bluefin's Podman feature defaults to opt-in nonroot user units, private
   binaries under `/usr/lib/bluefin/podman`, and a private user API socket.
   Materia currently expects rootful Quadlet, `/run/podman/podman.sock`, host
   system units, rootful secrets/volumes, and writable `/usr/local/bin`.
   Enabling the sysext is insufficient. A rootful integration must prove CLI,
   Quadlet generator, socket, helper paths, dependencies, storage, and update
   compatibility. A rootless port changes privileges, devices and ownership
   for existing services. Do not assume Flatcar bakery extensions are drop-in:
   Bluefin has a different OS identity and userspace closure.
3. **Firewall coexistence.** Bow's default-drop rules explicitly accommodate
   Podman ranges/interfaces, not Kubernetes. Do not import them unchanged or
   flush Cilium/netavark rules. Validate forwarding, DNS, established traffic,
   overlay transport, and external exposure with both runtimes active.
4. **Recovery and update ownership.** OS rollback does not roll back etcd,
   application data, or database schema changes. Back up and restore-test
   those separately. Set reboot windows and test updates with the sole
   control plane present, including recovery when the API or CNI is down.

## Suggested execution sequence and acceptance gates

1. Capture live hardware/firmware/storage, state and backup inventories; retain
   recovery access. Decide whether workloads initially stay in Materia (the
   smallest migration) or move separately into Kubernetes.
2. Pin one Bluefin release and its templates; verify signed release checksums.
   Test installed control-plane + worker VMs, first on one LAN and then across
   a routed VPN. Prove custom API endpoint/SANs, private addressing, Cilium,
   reboot persistence, and a failed-update recovery.
3. Prove Materia/rootful Podman compatibility and restore representative
   service state in those VMs; test both runtimes together. No production
   replacement until this gate passes.
4. Boot bow non-destructively for hardware checks; then schedule disk install,
   restore/import persistent state, validate media, cache, USB, backups and
   private Kubernetes access. Keep recovery media and old state available.
5. Prove a disposable Hetzner worker including recovery and capacity, then
   replace flutterina during a planned ingress outage, or use a separately
   planned HA migration if uninterrupted ingress is required. Joining bow's
   Kubernetes cluster does not give Pangolin HA by itself.
6. Pilot krytis-runner last with unique labels and the CI reboot protection;
   retain Debian until the workload suite and provider recovery are proven.

This investigation creates no replacement implementation for issue #102 and
does not cancel its prior user-directed Pangolin HA work. That plan needs an
explicit scope revision if Bluefin becomes the chosen OS.

## Primary upstream sources

- [Server README, architecture and Alpha status](https://github.com/projectbluefin/server/blob/main/README.md)
- [Control-plane template](https://github.com/projectbluefin/server/blob/main/files/homelab/templates/homelab-control-plane.bu)
- [Worker template](https://github.com/projectbluefin/server/blob/main/files/homelab/templates/homelab-node.bu)
- [Cluster discovery and join protocol](https://github.com/projectbluefin/server/blob/main/files/homelab/cluster/README.md)
- [Kubeadm runtime and endpoint configuration](https://github.com/projectbluefin/server/blob/main/docs/skills/kubeadm-sysext.md)
- [Runtime extensions and private Podman contract](https://github.com/projectbluefin/server/blob/main/docs/skills/systemd-sysext-extensions.md)
- [Disk installation and update lifecycle](https://github.com/projectbluefin/server/blob/main/docs/skills/ddi-installer.md)
- [USB installer and firmware requirements](https://github.com/projectbluefin/server/blob/main/docs/skills/usb-installer.md)
- [Netboot and signed Ignition delivery](https://github.com/projectbluefin/server/blob/main/docs/skills/booty-integration.md)

Validation performed: source/configuration review only. No boot, render,
deployment, network, restore, or application tests were run. The repository's
bigpowers planning skills are unavailable in the installed skill catalogs;
this document records findings only and generates no IaC changes.
