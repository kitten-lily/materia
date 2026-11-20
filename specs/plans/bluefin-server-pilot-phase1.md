# Bluefin pilot Phase 1: implementation design

Implements Phase 1 of [the pilot plan](bluefin-server-pilot.md) (installed
local control plane and worker). Evidence goes to
[the results](bluefin-server-pilot-results.md); recovery procedures are in
[the recovery doc](bluefin-server-pilot-recovery.md). Pinned release
v26.11.2506 (commit `d7f2890`). Approved by the operator 2026-11-20,
including the two decisions marked **(D1)** and **(D2)**. Revised the same day
after a Codex review: explicit boot stages, add-on access tests, dataplane
checks on NIC 2, and a pinned butane.

## Scope

Phase 1 proves install, join, persistent state and reboots on the LAN. It
also runs the two Phase 0 step 4 recovery checks that need an installed node.
Tailscale, the cross-site API endpoint and Cilium host policies are Phase 2.

**(D2) Phase 1 is a LAN baseline; Phase 2 rebuilds.** The plan requires the
cross-site API endpoint to be chosen before the WAN cluster is initialized.
The tailnet address exists only once Tailscale runs, so Phase 1 initializes on
a fixed LAN endpoint (`10.77.0.10:6443`) and Phase 2 rebuilds the disposable
cluster with a tailnet endpoint. Nothing from Phase 1's cluster is carried
into Phase 2.

## Upstream facts this relies on (pinned docs at `d7f2890`)

- A node takes its Ignition config as the `ignition.config` system
  credential (SMBIOS type 11 or QEMU fw_cfg); on an installed disk Ignition
  applies it on every boot that carries it (`homelab-profile.md`, "Using a
  template").
- The installer runs unattended when given a
  `systemd.unit-dropin.systemd-sysinstall.service` system credential that
  re-runs the image drop-in's `ExecStart=` with `--confirm=no` and the target
  disk, plus `StandardInput=null`. That credential also makes the Secure Boot
  check non-interactive: it cancels unless Secure Boot is on with the Bluefin
  keys (`usb-installer.md`, "Unattended installs";
  `scripts/dogfood-installer.sh` is the reference).
- `systemd-firstboot` prompts on the installer console unless
  `firstboot.locale`, `firstboot.keymap`, `firstboot.timezone` and
  `passwd.hashed-password.root` credentials answer it.
- `kubeadm-init-config.service` copies the default `init.yaml` to
  `/etc/kubernetes/bluefin/init.yaml` only if absent, so a file written there
  by Ignition before the first init wins. If it already sets
  `controlPlaneEndpoint`, `bluefin-cluster-prepare.service` does not add the
  mDNS `<host>.local:6443` endpoint (`kubeadm-sysext.md`).
- `kubelet.service.d/10-kubeadm.conf` reads `EnvironmentFile=-/etc/default/kubelet`
  and passes `$KUBELET_EXTRA_ARGS`.
- `bluefin-homelab-apply` takes Cilium's API server address from the admin
  kubeconfig's server URL (overridable with `HOMELAB_K8S_SERVICE_HOST`).
- The node template joins via `bluefin-cluster-join.service`;
  `HOMELAB_CONTROL_PLANE=host[:port]` skips mDNS discovery; the passphrase
  can be given as the `bluefin-cluster.passphrase` credential.
- melog has no software TPM (`swtpm` absent), so sysinstall would store
  credentials with the null key. This design does not rely on sysinstall
  storing `ignition.config`.

## Machines and network

| VM | Hostname | vCPU / RAM | Disks | Shared-segment IP |
| --- | --- | --- | --- | --- |
| control plane | `bluefin-pilot-cp` | 4 / 8 GiB | OS 64 GiB, two data disks 8 GiB each (Phase 3 LVM test), all sparse qcow2 | `10.77.0.10/24` |
| worker | `bluefin-pilot-node` | 2 / 4 GiB | OS 40 GiB sparse qcow2 | `10.77.0.11/24` |

- Firmware: `OVMF_CODE_4M.secboot.fd` with a per-VM copy of
  `OVMF_VARS_4M.secboot.fd`, `q35,smm=on`,
  `-global driver=cfi.pflash01,property=secure,value=on`. The installer
  enrolls the Bluefin keys on first boot (results, F4).
- NIC 1: QEMU user networking (internet: image pulls, sysext fetch), with a
  host forward `127.0.0.1:<port>` → guest 22 for SSH (cp 2210, node 2211).
- NIC 2: a QEMU multicast socket segment shared by both VMs
  (`-netdev socket,mcast=230.77.0.1:7700`), static addresses from a networkd
  file matched by MAC. `10.77.0.0/24` avoids pods `10.244.0.0/16`, services
  `10.96.0.0/12`, Podman `10.88/16` and `10.89/16`, the tailnet pool
  `100.64.0.0/12` and Gerbil `100.89.128.0/20`. MetalLB pool
  `10.77.0.240-10.77.0.250`.
- Because both VMs get the same NIC 1 address (10.0.2.15), the cluster is
  pinned to NIC 2 explicitly: `init.yaml` sets
  `localAPIEndpoint.advertiseAddress: 10.77.0.10` and
  `controlPlaneEndpoint: 10.77.0.10:6443` with `apiServer.certSANs`
  `[10.77.0.10, bluefin-pilot-cp]`; `/etc/default/kubelet` sets
  `KUBELET_EXTRA_ARGS=--node-ip=<NIC 2 address>` on both nodes. That should
  make Cilium tunnel VXLAN between the NIC 2 addresses, but it is not assumed:
  step 3 checks Cilium's node addresses and cross-node pod traffic. The join
  (`bluefin-cluster`) is a compiled binary whose address selection was not
  read from source; step 3 also confirms the worker joined over NIC 2.

## Configuration deltas from the upstream templates

Generated from `homelab-control-plane.bu` / `homelab-node.bu` of the pinned
release (byte-identical to v26.11.1701's), keeping every upstream line except
the SSH key placeholder:

- `/etc/hostname` = the VM hostname.
- root `ssh_authorized_keys` = the pilot public key.
- `homelab.conf.template`: `HOMELAB_KURED=no`; control plane
  `HOMELAB_METALLB_ADDRESSES=10.77.0.240-10.77.0.250`; node
  `HOMELAB_CONTROL_PLANE=10.77.0.10`.
- Mask `systemd-sysupdate.timer` and `systemd-sysupdate-reboot.timer`
  (results, F3; masking also stops `bluefin-fleet-reboot.timer`).
- `/etc/systemd/network/10-pilot-lan.network` for NIC 2.
- Control plane: `/etc/kubernetes/bluefin/init.yaml` = the upstream default
  plus the endpoint, SANs and advertise address above, and
  `nodeRegistration.name: bluefin-pilot-cp`.
- Both: `/etc/default/kubelet` with `--node-ip`.
- Rendered with **butane 0.29.0**, pinned in the tooling
  (`mise exec butane@0.29.0 -- butane --strict`), to
  `~/.cache/bluefin-pilot/render/<vm>/config.ign`, mode 0600, never committed.
  The repo's `mise.toml` tracks `butane = "latest"`, which would make the
  render unreproducible; the pin is local to the pilot so the Flatcar `mise ign`
  workflow is unchanged. Checked 2026-11-20: 0.29.0 transpiles both pinned
  templates (`variant: fcos`, `version: 1.7.0`) with `--strict`.

## Secrets

**(D1)** Generated by the tooling and stored in the `bluefin-pilot` Proton
Pass vault via `pass-cli`:

- `ssh-root`: an ed25519 key pair without a passphrase (not a security key,
  so the tooling can log in unattended); only the public key goes into
  Ignition.
- `root-console-password`: random; only its SHA-512 crypt hash is passed to
  the VMs, as the `passwd.hashed-password.root` credential.
- `tailscale-auth-key`: already stored; not used until Phase 2.

The join passphrase is read from the control plane after its first boot
(`bluefin-cluster passphrase` over SSH), stored as `join-passphrase`, and given
to the worker's boots as the `bluefin-cluster.passphrase` credential.

## Tooling (in the repo, `.mise/tasks/bluefin/pilot/`)

- `render --vm <name>`: builds the Butane from the pinned template plus the
  deltas, transpiles it, and writes the hashed-password and passphrase
  credential files.
- `vm <create|install|start|stop|destroy|status> --vm <name>`: disks and VARS
  under `~/.cache/bluefin-pilot/vm/<name>/`. Every QEMU run uses
  `-no-reboot` (as upstream's `dogfood-installer.sh` does), so each guest
  reset ends the run and the next stage is an explicit step:
  1. **Enroll** (`install`, part 1): boot the installer overlay with fresh
     secboot VARS; systemd-boot enrolls the Bluefin keys and resets. QEMU
     exits.
  2. **Install** (`install`, part 2): boot the installer again with the same
     VARS and the unattended sysinstall drop-in credential, targeting the OS
     disk by its virtio serial (`/dev/disk/by-id/virtio-<serial>`, never
     `/dev/vdX`). The installer resets when done; QEMU exits. Check the
     serial log for sysinstall's exit status and the installed partitions.
  3. **Configured first boot** (`start`): boot the OS disk **without** the
     installer attached, with `ignition.config`,
     `passwd.hashed-password.root`, `firstboot.locale`/`keymap`/`timezone`
     and (node) `bluefin-cluster.passphrase` as SMBIOS credentials, from the
     very first boot of the installed disk. This matters because
     `systemd-firstboot` runs only on that first boot: a password credential
     supplied later is ignored (`tpm2-credential-sealing.md`), and an
     installed disk booted early without Ignition would also have missed its
     template. Later `start`s pass the same credentials and run without
     `-no-reboot` only when a test needs a guest-initiated reboot.
- Guards: refuse any name not matching `^bluefin-pilot-[a-z0-9-]+$`, refuse
  block devices, refuse paths outside `~/.cache/bluefin-pilot/`, and verify
  the installer's sha256 against the results table before every install.

## Steps and verification (plan Phase 1, with thresholds)

1. Render both configs. Verify: `butane --strict` exit 0; no secret value in
   the `.bu` other than the public key and password hash.
2. Install both VMs unattended, then first boot. Verify: `bootctl status`
   shows Secure Boot enabled with user keys; `findmnt /usr` (verity);
   `systemd-sysext list` shows `kubeadm` and `homelab` merged;
   `systemctl --failed` empty; `systemctl is-enabled systemd-sysupdate.timer
   systemd-sysupdate-reboot.timer` both `masked`; no kured DaemonSet.
3. Control plane initializes; worker joins over NIC 2 with
   `HOMELAB_CONTROL_PLANE`. Verify: `kubectl get nodes -o wide` shows both
   `Ready` with InternalIPs `10.77.0.10/.11`; `kubectl get --raw
   '/readyz?verbose'`; `cilium status` healthy. Pass: both nodes `Ready`
   within 20 minutes of the worker's first boot. Then prove the dataplane
   uses NIC 2 rather than assuming it:
   - `kubectl get ciliumnodes -o wide` (and `cilium-dbg node list` in an
     agent pod) list `10.77.0.10` and `.11` as node IPs, not `10.0.2.15`;
   - two test pods pinned to opposite nodes (`nodeName`) reach each other's
     pod IP in both directions;
   - from each node's pod, a ClusterIP Service backed only by a pod on the
     other node answers, and DNS resolves `kubernetes.default` and that
     Service's name;
   - the worker's join logs (`journalctl -u bluefin-cluster-join`) show
     `10.77.0.10` as the control plane it used.
   Pass: every check succeeds; any traffic on `10.0.2.15` between nodes fails
   the step.
4. Components and storage. Verify: `kubectl get pods -A` with no pod failing
   for more than 10 minutes; `kubectl get storageclass`; a PVC fixture writes
   a known checksum that matches after a reboot of the node it lives on.
4b. Authenticated private add-on access (the plan's Phase 1 exit requires
   it). The workstation is not on the multicast segment, so it reaches the
   Gateway's MetalLB address through the control plane:
   `ssh -L 8443:<gateway-ip>:443 -L 8080:<gateway-ip>:80 -p 2210 root@127.0.0.1`,
   with `curl --resolve <name>:8443:127.0.0.1` for `argo.`, `mcp.` and
   `kubestellar.home.arpa`. The homelab CA comes from
   `kubectl -n cert-manager get secret homelab-ca`. Checks, following
   upstream's own (`homelab-profile.md`, "Verify"):
   - the Gateway got an address from `10.77.0.240-250`;
   - HTTPS verifies against the homelab CA (`curl --cacert`), and port 80
     answers 301 to `https://` without asking for a login;
   - Argo Workflows: 401 without a token, success with
     `kubectl -n argo create token argo-server`;
   - MCP: 401 without a token, a read succeeds with the `mcp-client` token,
     a write tool is refused (read-only default);
   - KubeStellar Console: `/auth/github` answers 401 without the generated
     login and redirects with it; the login appears on the console, not in
     the journal.
   Pass: every check as stated.
5. Reboot each node twice, one at a time. Verify node UIDs unchanged
   (`kubectl get nodes -o custom-columns=NAME:.metadata.name,UID:.metadata.uid`),
   the worker rejoins without a new identity, no manual unit enabling, and
   both `Ready` within 10 minutes of each reboot.
6. Phase 0 step 4 checks: (a) console root login on the control plane with
   NIC 1 and NIC 2 link down (QMP `set_link`); (b) reinstall the worker's OS
   disk from the installer (recovery procedure L3) with an attached data disk
   holding a checksum fixture, confirm the fixture survives, and rejoin the
   worker (procedure K1).

Exit: as in the plan (persistent two-node cluster, no failed units,
unresolved pod failures or repeated credential prompts), plus the two recovery
checks recorded.

## Risks and open points

- Ignition on an installed disk runs on every boot that carries the config;
  passing it on every boot rewrites template files each time (intended:
  `homelab.conf` is created once and then left alone).
- Whether the installed system accepts SMBIOS `passwd.hashed-password.root`
  on its first boot when no installer credential stored one. The staged boots
  make sure it is present on that first boot; if it is still not applied, the
  disk is reinstalled (stage 2) with the credential also passed to the
  installer boot, never patched up on a later boot.
- The QEMU multicast segment needs host multicast loopback; if it fails,
  fall back to a QEMU `-netdev stream` pair (UDP or Unix socket).
- 12 GiB of the workstation's ~20 GiB free RAM; stop other heavy work while
  the VMs run.
