# Edge ingress under Bluefin: replace Pangolin?

Investigation date: 2026-11-21. Issue #179 context. Desk review only:
pilot specs plus upstream docs. Nothing was deployed, rendered or tested, and
no IaC changes are proposed here beyond a pilot test arm (see the end).

## Question

If the Bluefin Server cluster goes ahead, should Pangolin (app + Gerbil +
Traefik) be replaced by Pomerium or another Kubernetes-native ingress, reverse
proxy and TLS terminator? Tailscale-native integration is a preference.

## Recommendation

Do not adopt Pomerium. Replace Pangolin with **Envoy Gateway + cert-manager**
(both already in Bluefin's control-plane default set and running in the
pilot), with **Tailscale** as the transport and the access layer for private
apps, plus the **Tailscale Kubernetes operator** for a tailnet-only tier.
Decide only after the Phase 4 comparison arm below has measured both edges.

## What Pangolin still does after #163

Since the Tailscale backhaul, every bow app's Pangolin target is site
`flutterina`, host `<bow-ts-ip>:<port>`. Gerbil/Newt tunnels into closed sites
are no longer used for app traffic; flutterina's own Newt exists only so
Pangolin's health checks reach beszel-hub.

| Pangolin feature | State today |
| --- | --- |
| Public TLS edge (Traefik, ACME, HTTP/3) | Used |
| Routes defined in the dashboard | Used; outside git, caused the site/host retarget outages |
| Pangolin SSO | Only Media Manager (browser-only); off elsewhere, it breaks native clients |
| Health checks + alert rules | Checks work; alert email is never delivered (no SMTP) |
| Badger plugin | Liability: BUG-007 and BUG-014 were catalog-triggered total edge outages |
| Pod restart safety | Needed `ExitPolicy=continue` after BUG-009 |

So the real requirement is: about ten public HTTPS hostnames whose apps do
their own auth, HTTP/3, ACME, and a tailnet-only tier.

## Options compared

| Option | Pros | Cons |
| --- | --- | --- |
| Envoy Gateway + cert-manager | Already in the pilot (Phase 1 step 4b). Routes are `HTTPRoute` objects reconciled by Argo CD. HTTP/3 via `ClientTrafficPolicy` `http3: {}`. OIDC and ext_auth through `SecurityPolicy` if ever needed. Tailscale's official Gateway API guide uses this pattern (`EnvoyProxy` with `loadBalancerClass: tailscale`). Backends are cluster Services, no second tunnel | No UI. Health checks/alerting must be rebuilt. Public listener needs `hostNetwork`/`hostPort` on the tainted edge node. OIDC/JWT/basic auth do not apply to TCPRoute |
| Pomerium Ingress Controller | Identity-aware proxy, per-route policy, cert-manager, SSH and TCP/UDP routes, open-source controller | Deny-by-default: every public app with its own auth needs an unauthenticated-access policy, so Pomerium would mostly be switched off. TCP/UDP routes need the Pomerium CLI/desktop client. Gateway API is experimental, partial Core v1.2, HTTPS listeners only. HTTP/3 not documented. More than one replica needs Postgres or the experimental Raft databroker. A second Envoy beside Bluefin's. No Tailscale integration beyond a marketing post |
| Tailscale operator alone (Ingress + Funnel) | Most Tailscale-native. Tailnet Ingress with automatic `*.ts.net` certs; ProxyGroup HA; access via tailnet grants | Not a public edge: Funnel serves `ts.net` names only on ports 443/8443/10000 and relays bandwidth through Tailscale (not re-checked in this session). No native `tailscale` GatewayClass (tailscale/tailscale#10656 open; only community controllers) |
| Pangolin Helm chart | Keeps dashboard and SSO | Chart `0.1.0-alpha.0`, app 1.18.2 (older than the pinned `ee-1.22.x`). Gerbil needs `NET_ADMIN` and a privileged namespace. Routes stay outside git; badger risk stays; carries unused tunnel machinery |
| Traefik (Gateway API provider) | Familiar config; native Tailscale certificate resolver | Resolver issues `*.ts.net` certs only, and a forum report says it does not work with Gateway API yet. Would replace or duplicate Bluefin's Envoy Gateway |
| agentgateway | Documented Tailscale auth (standalone): an `extAuthz` policy calls the local `tailscaled` whois API over `unix:/run/tailscale/tailscaled.sock` with `"/localapi/v0/whois?addr=" + source.address` and extracts `Node.Name` and `UserProfile.LoginName` | The page shows the identity only in access logs, not forwarded to backends or used in policy. Standalone mode only; Kubernetes/Gateway API not covered. Works only for tailnet-sourced traffic. [INFERENCE] In a cluster the pod would need the node's `tailscaled.sock` and the real tailnet source IP. The same whois pattern is available to any ext_authz proxy, Envoy Gateway included |

## Proposed shape

1. **Public tier:** an Envoy Gateway `Gateway` on the tainted edge node,
   binding 443/tcp and 443/udp, cert-manager with Let's Encrypt, existing
   wildcard DNS unchanged, one `HTTPRoute` per app in git.
2. **Tailnet-only tier:** a second Gateway exposed with
   `loadBalancerClass: tailscale`. Tailnet grants decide who reaches it.
3. **No SSO layer:** Media Manager, the only SSO app, moves to the
   tailnet-only tier. If public SSO is ever needed, Envoy `SecurityPolicy`
   OIDC with tsidp is the Tailscale-identity route (unverified pairing).
4. **Removed:** Gerbil, Newt (including flutterina's health-check Newt) and
   the badger plugin.

## What we gain

- **Routes in git.** Every hostname is a reviewed `HTTPRoute` reconciled by
  Argo CD. No dashboard drift, no API calls to fix a retarget.
- **Fewer outage classes.** The badger catalog dependency (BUG-007/014), the
  pod-drain failure mode (BUG-009) and the Pangolin site/host retarget
  mistakes all disappear with their components.
- **One proxy stack.** The edge uses the same Envoy Gateway and cert-manager
  that Bluefin already runs for Argo, MCP and KubeStellar, instead of a
  separate Traefik with its own plugin system.
- **One transport.** Tailscale carries everything; no Gerbil WireGuard
  ports (udp/51820, udp/21820) on the public firewall, no Newt identities or
  provisioning keys to keep.
- **Clear access model.** Public apps authenticate themselves; private apps
  sit behind tailnet grants. No 302-to-login breaking native clients.
- **Mainstream ecosystem.** Gateway API, cert-manager and Envoy are
  widely used, documented and Renovate-trackable via Helm/Argo.

## What we lose

- **The Pangolin dashboard.** No UI for routes, sites, users or logs;
  changes become commits.
- **Pangolin health checks.** Rebuild with Envoy active health checks and
  metrics, plus an external probe (Beszel or healthchecks.io). Pangolin's
  alert delivery was already broken, so alerting is not a regression.
- **Edge independence from bow.** Today flutterina's edge runs on its own.
  In the cluster, the Envoy Gateway controller and the API server live on
  bow, the sole control plane. [INFERENCE] Envoy keeps its last xDS config
  when the controller is unreachable, so existing routes should keep
  serving, but no route changes or rescheduling happen while bow is down.
  Most backends are on bow anyway; beszel-hub is the exception.
- **Pangolin SSO and its client/private-resource features** (Pangolin
  clients, site resources, multi-site tunnels to hosts without Tailscale).
  None are in use now; a future site without Tailscale would need it.
- **Pangolin Enterprise clustering path** from #102 becomes moot rather than
  merely deferred.
- **Migration work.** About ten routes rewritten, health checks and
  monitoring rebuilt, an edge cutover with a short public outage.
  Pangolin's database and ACME state are not carried over: cert-manager
  reissues certificates.

## Open risks

- Edge-node capacity: Envoy + kubelet + Cilium against the Pangolin pod is
  unmeasured. Phase 4 step 5's 48-hour run sizes it.
- Control-plane-down behaviour of the public edge must be tested (Phase 5).
- Source-IP preservation and `hostNetwork` listener placement interact with
  Cilium host policies; Phase 2's denial tests must still pass.

## Alternatives: control-plane placement

The pilot puts the sole control plane on bow. Moving it to the cloud removes
the "edge depends on home" loss above. Two placements were considered.

### On flutterina itself

Pros:

- Public routing and cluster management both live in the datacenter; a home
  power, ISP or hardware outage stops only bow's own apps.
- Datacenter power and network, static IP, provider console, snapshots.
  bow's reboots and maintenance no longer pause cluster management.
- Workers dial out to the cloud. flutterina has a public UDP port and is a
  peer relay, so bow to control plane uses the relay path, not DERP (Phase 2
  measured `readyz` p95 540 ms over DERP).
- Argo CD and the controllers sit next to the edge they manage.

Cons:

- **Blast radius.** etcd holds every Secret, including the KSOPS age key
  Secret. An exploit in the public proxy on the same node as etcd and the API
  server is a full cluster compromise; a tailnet-only API port does not help
  once the attacker is on the node. The fleet age key is already shared by
  every host (server secret isolation is an open decision), so this worsens
  an existing risk rather than creating a new one.
- **Capacity.** flutterina has 3.7 GiB RAM (2.4 GiB available) and a growing
  disk. Bluefin's control-plane default set plus the enabled add-ons will not
  fit beside the edge. [INFERENCE] At least an 8 GB class instance;
  unmeasured. etcd also needs fast fsync (`mise bench:vps` disk section).
- **Still one control plane.** It changes which failure stops cluster
  management, it adds no HA. HA needs 3 etcd members, and spreading them
  over home and cloud brings WAN latency problems.
- **Harder rebuilds.** A dead flutterina then also needs an etcd restore,
  which Phase 5 has not proven yet.
- **Pilot rework.** Phases 1-3 proved the control plane on local VMs; the
  Hetzner caveats (cpx for UEFI, no Secure Boot, NVRAM persistence open)
  would apply to the most important node.
- bow's workloads still run at home; during a home WAN outage the control
  plane cannot reconcile them.

### On a dedicated cloud node (preferred if moving)

A third small Hetzner VPS, reachable only over the tailnet, no public
ingress. It keeps every pro above, keeps etcd away from the internet-facing
proxy, and leaves flutterina's size and rebuild story unchanged. Costs: one
more server to pay for and patch, and still a single control plane. A later
3-member etcd (two cloud plus bow, or three cloud) would give HA but needs
its own latency testing.

### Sizing a dedicated control-plane node

Only reading so far: a read-only `free`/`kubectl top` on the pilot control
plane (4 vCPU, 8 GiB) on 2026-11-21, one minute after a reboot and shortly
after Argo Workflows, MCP and KubeStellar had been removed for Phase 3
testing. Treat it as a floor, not a sizing number: node memory 2781 Mi (35%),
`free` 3.1 GB used, 4.7 GB available, no swap; kube-apiserver 830 Mi, Argo CD
application-controller 590 Mi, Cilium 291 Mi, etcd 130 Mi, every other pod
under 100 Mi; 14 GB used on `/`, mostly images. App workloads running on the
pilot control plane do not count: a dedicated node keeps the control-plane
taint.

| | Recommended | Why |
| --- | --- | --- |
| vCPU | 4 | kubeadm needs at least 2; API server and Argo spike on syncs and restarts |
| RAM | 8 GB | The 2.8 GiB floor excludes the add-ons, which would run here; the API server and Argo controller grow with object count; no swap. 4 GB is too small unless the add-ons stay off |
| Disk | ~80 GB local NVMe | Images already take 14 GB. etcd guidance: WAL fsync p99 under 10 ms; measure with the `mise bench:vps` disk section before picking a type |
| Firmware | UEFI | Pilot F1: CX types boot legacy BIOS, cpx gen2 boots UEFI; no Secure Boot |
| Network | tailnet only, plus udp/41641 | No public API, kubelet or join ports. Tailscale's UDP port gives a direct path to the edge node; bow goes through the edge node's relay |
| Location | the edge node's region | Lowest latency to the edge; bow's latency is set by the home link |

On Hetzner that is the 4 vCPU / 8 GB cpx type (confirm names and prices
with `hcloud server-type list`). Also: keep the default control-plane taint,
take off-host etcd snapshots (restic to the Storage Box) with the Phase 5
restore test, and give the node its own Hetzner firewall with no public TCP
ports, since it holds every Secret including the KSOPS age key. The Phase 4
variant's 48-hour run decides the final type.

## Proposed pilot test arm (Phase 4)

Alongside the Pangolin pod in Phase 4 step 3, run an Envoy Gateway edge on
the same disposable edge node, with the same test domains, staging ACME and
gates: external HTTPS and HTTP/3 (`curl --http3-only`), the step 4 restart
gates (controller and proxy pod deleted), the step 5 48-hour load profile,
and one tailnet-only route through the Tailscale operator with
`loadBalancerClass: tailscale`. Add a run with the control plane stopped to
confirm existing routes keep serving. Choose the production edge from the
measured results of both arms. The Pangolin pod stays in Phase 4 as
planned; this arm is added beside it, not instead of it.

### Optional variant: cloud control plane

After the main Phase 4 run, repeat it with the control plane on a separate
disposable cpx node in the same region, tailnet-only, with the pilot
firewall minus every public rule except icmp and udp/41641. bow-side
workers stay on the local VMs. Measure: worker `readyz` p50/p95 to the cloud
control plane (relay path, not DERP), control-plane RAM/CPU/disk and etcd
fsync latency over 48 hours at the step 5 load, and edge behaviour with the
home-side workers cut off (`tailscale down` on them for 10 minutes): the
edge node stays `Ready`, its routes keep serving, Argo keeps reconciling it.
Record the instance size actually needed. Do not test the control plane on
the edge node itself; the blast-radius con above rules it out for
production, so measuring it adds nothing.

## Sources

- [Pomerium Ingress Controller](https://www.pomerium.com/docs/deploy/k8s/ingress)
- [Pomerium Gateway API](https://www.pomerium.com/docs/deploy/k8s/gateway-api)
- [Pomerium databroker storage](https://www.pomerium.com/docs/reference/databroker)
- [Tailscale & Pomerium: Better Together](https://www.pomerium.com/blog/tailscale-pomerium-better-together)
- [Envoy Gateway HTTP/3](https://gateway.envoyproxy.io/docs/tasks/traffic/http3/)
- [Envoy Gateway SecurityPolicy](https://gateway.envoyproxy.io/latest/concepts/gateway_api_extensions/security-policy/)
- [Envoy Gateway OIDC](https://gateway.envoyproxy.io/latest/tasks/security/oidc/)
- [Tailscale: custom domains with Gateway API](https://tailscale.com/docs/solutions/kubernetes-operator-byod-gateway-api)
- [Tailscale operator Ingress](https://tailscale.com/docs/kubernetes-operator/ingress)
- [Tailscale ProxyGroup](https://tailscale.com/docs/kubernetes-operator/concepts/proxygroup)
- [Tailscale operator limitations](https://tailscale.com/docs/kubernetes-operator/reference/limitations.md)
- [Tailscale Funnel on Kubernetes](https://tailscale.com/docs/kubernetes-operator/ingress/expose-workload-to-internet.md)
- [tailscale/tailscale#10656](https://github.com/tailscale/tailscale/issues/10656)
- [tsidp](https://tailscale.com/docs/features/tsidp)
- [agentgateway Tailscale auth](https://agentgateway.dev/docs/standalone/latest/integrations/auth/tailscale/)
- [Pangolin Helm chart](https://docs.pangolin.net/self-host/manual/kubernetes/pangolin/helm)
- [Traefik Tailscale resolver](https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/tailscale/)
- [Traefik forum: Tailscale resolver with Gateway API](https://community.traefik.io/t/trouble-setting-up-tailscale-certificate-resolver-with-gateway-api/29668)
