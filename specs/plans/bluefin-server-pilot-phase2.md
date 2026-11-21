# Bluefin pilot Phase 2: implementation design

Implements Phase 2 of [the pilot plan](bluefin-server-pilot.md) (host VPN and
cross-site networking) on the local VMs. Builds on
[Phase 1](bluefin-server-pilot-phase1.md) and its tooling. Evidence goes to
[the results](bluefin-server-pilot-results.md). Release v26.11.2506.
Decisions already made (Phase 0 step 5): Tailscale netfilter mode off,
Cilium host policies as the host firewall, `tag:bluefin-pilot`, no use of the
production peer relay. Revised 2026-11-20 after a Codex review (credential
path, init.yaml writer ordering, firewall scope and outer transport, UDP and
IPv6 coverage of the denial tests, checks after enforcement, VPN-only
outage).

## What changes from Phase 1

Phase 1 proved the cluster on a shared LAN segment. Phase 2 rebuilds it so
the nodes only ever reach each other over the tailnet, the way bow and a
cloud worker would:

- **No shared segment.** The QEMU multicast NIC is removed. Each VM keeps one
  NIC: QEMU user networking (internet behind NAT). The two VMs share no L2,
  so there is no mDNS path between them and every node-to-node packet must
  cross Tailscale. This is the plan's "routed worker with multicast
  unavailable".
- **Host Tailscale on every node,** from the release's signed `tailscale`
  sysext, started before any Kubernetes unit.
- **The cluster is addressed by tailnet name and address.** API endpoint
  `bluefin-pilot-cp.<tailnet>.ts.net:6443` (MagicDNS), advertise address and
  kubelet node IPs are the nodes' tailnet IPv4 addresses.
- **Cilium host firewall** on, through a `CiliumNodeConfig`, with a
  `CiliumClusterwideNetworkPolicy` that admits only what the cluster needs.

The Phase 1 cluster is destroyed (`vm destroy`), as decided in the Phase 1
design (D2). Nothing carries over except the pilot vault items.

## Upstream facts this relies on

- The `tailscale` sysext ships `tailscaled.service` (state in
  `/var/lib/tailscale`, `--port=${PORT}` default 41641) **disabled by preset**
  (`80-tailscale.preset`). Like `kubeadm-init.service`, a sysext unit is
  merged after presets are applied, so it is enabled by an
  `/etc/systemd/system/multi-user.target.wants/` link, and fetched by the
  sysupdate feature `tailscale` (`/etc/sysupdate.d/tailscale.feature.d/`).
- Bluefin ships systemd-resolved (`os-resolved.bst`), which Tailscale's
  MagicDNS (`--accept-dns`, default on) configures over D-Bus.
- `kubeadm-init-config` leaves an existing `/etc/kubernetes/bluefin/init.yaml`
  alone, and `bluefin-cluster-prepare` adds no mDNS endpoint when it already
  sets `controlPlaneEndpoint` (Phase 1 design).
- `bluefin-homelab-apply` renders Cilium from a fixed manifest
  (`enable-host-firewall: 'false'`, `devices: ''`, VXLAN tunnel) and runs on
  every boot. Only `${HOMELAB_K8S_SERVICE_HOST}`/`PORT` are templated
  (`HOMELAB_K8S_SERVICE_HOST` defaults to the admin kubeconfig's server host
  and can be set in `homelab.conf`). Hand edits to `cilium-config` would be
  reverted on the next boot.
- Cilium 1.20 `CiliumNodeConfig` (`cilium.io/v2`, `spec.defaults`,
  `spec.nodeSelector`, `{}` = all nodes) overrides `cilium-config` keys per
  node; agents pick it up only when recreated (upstream
  `per-node-config.rst`, v1.20.2). The applier never touches it.

## Node bootstrap: `pilot-tailnet-prep.service`

A pilot oneshot unit in the Ignition config, ordered before every Kubernetes
unit by drop-ins on those units (drop-ins in `/etc/systemd/system/<unit>.d/`
apply to sysext units too):

- `kubeadm-init-config.service.d/50-pilot.conf`,
  `bluefin-cluster-prepare.service.d/50-pilot.conf`,
  `kubeadm-init.service.d/50-pilot.conf`,
  `bluefin-cluster-join.service.d/50-pilot.conf`,
  `kubelet.service.d/50-pilot.conf`,
  `bluefin-homelab-apply.service.d/50-pilot.conf`: `Requires=` + `After=`
  `pilot-tailnet-prep.service`.

  The first two matter most: `kubeadm-init-config` seeds `init.yaml` only if
  absent, and `bluefin-cluster-prepare` then edits it (renames a `localhost`
  node, adds an mDNS endpoint unless one is set). Ordering both after the
  prep unit makes the prep unit the only first writer, so the seed is a no-op
  and prepare finds `controlPlaneEndpoint` already set. Verify on the first
  boot that the final `init.yaml` is the prep unit's, unchanged.

  Deadlock check: the prep unit orders itself only after
  `network-online.target` and `bluefin-sysext-fetch.service`. The fetch and
  activation implementations were not available to read, so whether they wait
  on anything ordered after the prep unit is unproven. The prep unit's wait
  for `/usr/bin/tailscale` has a 10-minute limit and fails the unit visibly,
  so a deadlock would show as a failed unit on the first boot rather than a
  hang.

The unit (`After=network-online.target bluefin-sysext-fetch.service`,
`RemainAfterExit=yes`, retries on failure) runs a script that:

1. waits up to 10 minutes for `/usr/bin/tailscale` (the sysext merge), then
   starts `tailscaled.service`;
2. if the node is not logged in, runs `tailscale up` with
   `--auth-key=file:$CREDENTIALS_DIRECTORY/pilot.tailscale-authkey`
   (`ImportCredential=pilot.tailscale-authkey`, an SMBIOS credential, so the
   key is never in the Ignition config; `ImportCredential=` keeps the name,
   per `systemd.exec(5)`), failing immediately if that file is absent, `--advertise-tags=tag:bluefin-pilot`,
   `--netfilter-mode=off`, `--hostname=<vm>`, `--accept-dns=true`;
3. waits for a tailnet IPv4 and for MagicDNS to resolve the control plane's
   name;
4. writes `/etc/default/kubelet` with `--node-ip=<tailnet IPv4>` (every
   boot, so a changed tailnet IP is picked up and visible);
5. control plane, before the first init only (no `admin.conf` yet): writes
   `init.yaml` with `advertiseAddress: <tailnet IPv4>`,
   `controlPlaneEndpoint: bluefin-pilot-cp.<tailnet>:6443`, `certSANs`
   `[<fqdn>, bluefin-pilot-cp, <tailnet IPv4>]`, and sets
   `HOMELAB_K8S_SERVICE_HOST=<tailnet IPv4>` in `homelab.conf` (Cilium's API
   address; the agent must not depend on DNS before CoreDNS runs).

The worker's `homelab.conf.template` sets
`HOMELAB_CONTROL_PLANE=bluefin-pilot-cp.<tailnet>` (join over the tailnet, no
mDNS). The tailnet's MagicDNS suffix is read at render time from the
workstation's `tailscale status --json` and never committed.

## Keeping Tailscale off the pod network (added during implementation)

Found on the first tailnet build (results, F5): Tailscale advertised Cilium's
`cilium_host` address as a direct endpoint and tunnelled through Cilium's own
VXLAN. `tailscaled.service.d/50-pilot.conf`
(`provisioning/bluefin/tailscaled-no-pod-paths.conf`) adds, before
`tailscaled` starts, policy-routing rules that make `10.244.0.0/16` and
`10.96.0.0/12` unreachable for packets carrying Tailscale's socket mark
(`0x80000/0xff0000`). Bluefin ships no `nft` or `iptables`, so routing is the
available tool. Verify after every boot: `ip rule show` lists both pref-90
rules, and `tailscale status` never shows a `10.244.` or `10.96.` address.

The same drop-in installs `unreachable 100.64.0.0/10` in the main table
(added 2026-11-21 after step 4): table 52 wins while Tailscale is up, and
while it is down tailnet-bound traffic fails instead of leaking to the
underlay. `ip route show 100.64.0.0/10` must list it.

## Cilium configuration

Applied from the workstation after the cluster is up, as pilot manifests in
`provisioning/bluefin/fixtures/` (images pinned, no tailnet values in them):

- `CiliumNodeConfig` `pilot-host-firewall`, `nodeSelector: {}`:
  `enable-host-firewall: "true"`, `devices: "tailscale0,enp0s5"` (the host
  firewall attaches only to listed devices; comma-separated, as Cilium parses
  string lists), and first `policy-audit-mode: "true"`. Agents are restarted
  to load it. Creating the object proves nothing on its own: verify the keys
  took effect with `cilium-dbg status --verbose` (host firewall enabled, on
  which devices) and `cilium-dbg config` on every agent.
- `CiliumClusterwideNetworkPolicy` `pilot-host`, `nodeSelector` on
  `kubernetes.io/hostname in (bluefin-pilot-cp, bluefin-pilot-node)`,
  ingress allowed, each rule with explicit ports so no identity gets
  blanket access:
  - from `entities: [host]` (the node itself): all ports;
  - from `entities: [remote-node]`: tcp 6443, 10250, 4240 and udp 8472;
  - from `entities: [health]`: tcp 4240;
  - from `entities: [cluster]` (pods): tcp 6443 and 10250 (the API Service's
    endpoint is the control plane's host address; metrics-server scrapes
    kubelets);
  - from CIDR `100.64.0.0/10` (the tailnet): tcp 22, 6443, 6447, 10250 and
    ICMP (a joining node is not yet a `remote-node`);
  - from `entities: [world]`: udp 41641, Tailscale's outer transport
    (`tailscaled.defaults`; Phase 0 opens it on the edge for direct peer
    connections). Without it a node only works through DERP or flows it
    started, which would hide the omission;
  - harness exception: from `10.0.2.2/32` (the QEMU user-net host, i.e. the
    workstation's SSH port forward) on tcp 22 only. On the Hetzner node SSH
    is tailnet-only.
  Everything else to the host is dropped. The allow list is deliberately
  narrower than "all in-cluster traffic"; widening it later is a recorded
  decision. Run in audit mode, read the
  would-be drops (`cilium-dbg monitor --type policy-verdict` on each agent),
  fix the policy, then set `policy-audit-mode: "false"` and restart agents.
- **As built** (`provisioning/bluefin/fixtures/host-firewall.yaml`; why each
  change was needed is in the results, Phase 2 step 3): `devices:
  "tailscale0,en+"` (NIC names differ per VM); `nodeSelector: {}` (the host
  endpoint carried no Node labels); `remote-node` rules also list
  `kube-apiserver` (the control plane's host identity); added MetalLB
  memberlist 7946 tcp/udp, node health ICMP, pod → host ICMP echo, pod → host
  4244 (Hubble), pod → host tcp 32768–60999 (replies to the host's Envoy
  proxy), and ICMP types 3/11 from anywhere (PMTU).
- MTU is not set by hand first: with node IPs on `tailscale0` (MTU 1280),
  check what Cilium picks (`cilium-dbg status`, pod interface MTU). Expect
  1280 minus VXLAN overhead. If Cilium picks 1500, set `mtu` in the same
  `CiliumNodeConfig`.

## Denial tests (no public address locally)

The local VMs have no public IP. QEMU user networking only reaches the guest
through explicit host forwards, so the tooling adds forwards from the
workstation's loopback to guest tcp 6443, 6447, 10250 and udp 8472 on the
non-tailnet NIC (`enp0s5`). That traffic arrives from `10.0.2.2` on a
non-tailnet device, which is exactly what the host firewall must refuse.

- **Probe method (revised during implementation):** QEMU's user-net forward
  accepts the TCP connection on the workstation side before it tries the
  guest, so a bare connect "succeeds" even with nothing listening (the
  worker's 6443 did). A probe counts only if the guest answers: an HTTP
  status from 6443 (`/readyz`) and 10250 (`/healthz`), and for 6447 (the join
  service's own protocol, which answers nothing to junk) an established
  socket from `10.0.2.2` seen on the guest with `ss`. The workstation has no
  `nc`; the probes use curl and bash `/dev/tcp`.
- **Control first:** before the host firewall is enforced, the control plane's
  6443 (200), 10250 (401) and 6447 (connection arrives) and the worker's 10250
  (401) are reached; the worker's 6443/6447 have no listener (negatives).
- **Then:** with enforcement on, every one of those must be blocked.
- **UDP 8472** cannot be judged by `nc` (UDP silence proves nothing). Send
  real datagrams to the forwarded port and judge on the receiver: in audit
  mode `cilium-dbg monitor --type policy-verdict` on that node must show the
  packet arriving with an audit (would-drop) verdict, the positive control;
  with enforcement on, the same probe must show a deny verdict.
- **Coverage is partial,** and is recorded that way, not as the plan's
  denial criterion passing: the probes come from `10.0.2.2` on a private NAT,
  not from a public address, and there is no IPv6. The homelab Cilium runs
  with `enable-ipv6: 'false'`, so the host firewall does not cover IPv6 at
  all. On the Hetzner node (public IPv6) that gap is real: Phase 4 must test
  IPv6 explicitly and decide how IPv6 is protected (the provider firewall
  alone, or another host layer).

## Tooling changes

- `render --topology tailnet` (Phase 2) vs `lan` (Phase 1): `tailnet` drops
  the static NIC 2 network file and `init.yaml`, adds the prep unit, its
  script, the drop-ins, the `tailscale` feature file and the
  `tailscaled.service` link, and fills the MagicDNS suffix.
- `vm start --topology tailnet`: one NIC, the denial-test forwards, and the
  `pilot.tailscale-authkey` SMBIOS credential read from the pilot vault at
  start (never written to the render directory).
- Re-registering a VM (reinstall) creates a new tailnet device; delete the
  old one first so the name, and with it the MagicDNS name, is reused.

## Steps and verification (plan Phase 2, with thresholds)

1. Rebuild both VMs with `--topology tailnet`. Verify per node:
   `ip -4 -br addr show tailscale0`; `tailscale status`; `tailscale debug
   prefs` shows `NetfilterMode: 0` (off); `nft list ruleset` has no
   Tailscale tables (`ts-*` chains); `systemctl --failed` empty; Tailscale
   came up before kubelet (`journalctl -b -o short-monotonic -u
   pilot-tailnet-prep -u kubelet | head`).
2. Endpoint and identity. Verify: `kubectl get nodes -o wide` InternalIPs are
   the tailnet IPs; `openssl s_client -connect <fqdn>:6443 -servername <fqdn>
   -CAfile /etc/kubernetes/pki/ca.crt -verify_hostname <fqdn>` from the
   worker returns `Verify return code: 0`; the worker's join log shows the
   FQDN; the API answers by FQDN from the workstation over the tailnet.
3. Dataplane over the tailnet and the host firewall, in this order:
   a. Before the host firewall: `cilium-dbg status` OK and its MTU; Phase 1's
      dataplane fixture checks (pod↔pod both ways, Service by name, DNS);
      pod-to-tailnet (a pod fetches from a listener on the workstation's
      tailnet address); `cilium connectivity test` with a CLI matching Cilium
      1.20.2, pinned by sha256; denial-test controls (tcp connects; UDP
      reaches the receiver).
   b. Audit mode: verify the keys took effect (status/config on every agent);
      no would-be drops of legitimate traffic during a run of (a).
   c. Enforce. Repeat all of (a): dataplane, DNS, pod-to-tailnet,
      `tailscale status` showing a direct peer path where one existed before
      (proves udp 41641 is admitted), the connectivity test; then the denial
      tests must fail every probe (UDP judged by deny verdicts).
   d. Reboot both nodes one at a time and repeat (c)'s checks.
4. Resilience. Large payloads and sustained connections: a 64 MiB
   checksum-verified HTTP transfer across nodes through the fixture Service,
   repeated every 15 s during the whole step; a long-lived TCP connection
   held open across nodes. Then drop only the worker's tailnet path for 10
   minutes (`tailscale down` on the worker, run over the harness SSH, which
   does not use the tailnet; DNS, registries and the rest of its internet stay
   up) and restore it with `tailscale up` and the same flags. Separately, as
   an additional test labelled as such, cut the worker's whole NIC for 10
   minutes (QMP `set_link`) and record recovery. Pass (plan): every node `Ready` and transfers succeeding
   within 5 minutes of the link returning, no manual repair, zero checksum
   mismatches across the whole step; API `readyz` p95 under 500 ms from the
   worker over the tailnet while the path is up (100 samples).

Record API latency, recovery time and the measured MTU. If the tailnet path
can't be made reliable, the plan says to recommend separate clusters rather
than stretching one; do not change the topology mid-test.

## Risks and open points

- MagicDNS must resolve on the nodes before kubelet bootstraps; if resolved
  does not take Tailscale's DNS, the prep script fails visibly (step 3) and
  the fallback is the control plane's tailnet IP as the endpoint.
- Both VMs sit behind QEMU user-net NAT on the same workstation, so Tailscale
  may use a direct path or DERP; record which (`tailscale status`), since it
  changes latency. The Hetzner phase measures a real WAN.
- Host firewall misconfiguration can cut the harness's SSH; the console
  (recovery procedure L1) is the way back, and audit mode comes first.
