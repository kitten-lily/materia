# Bluefin pilot Phase 4: implementation design

Implements Phase 4 of [the pilot plan](bluefin-server-pilot.md) (disposable
Hetzner edge worker) on the Phase 3 cluster, plus the comparison arm from
the [edge ingress investigation](bluefin-edge-ingress-investigation.md).
Evidence goes to [the results](bluefin-server-pilot-results.md). Release
v26.11.2506, pinned (F11). Status: **draft, 2026-11-22, revised the same
day after a Codex review** (unproven boot without the installer's EFI
variables, secrets on the ESP, no public-ingress rule in the host firewall,
a weakened load gate, no schedule cutoffs, plus verification gaps).
**Decided 2026-11-22** (operator): E4 a pilot subdomain of the production
zone with no DNS token (TLS-ALPN-01 for Pangolin, HTTP-01 on a temporary
tcp/80 for Envoy); E6 measure the baseline on flutterina, and amend the
transfer gate to the measured home uplink if it is below 170 Mbit/s; every
other recommendation (E1–E3, E5, E7–E10) as written. Nothing here is
deployed and no paid resource exists.

## Starting point (2026-11-22)

- Cluster: `bluefin-pilot-cp` + `bluefin-pilot-node` on melog, joined only
  over the tailnet, Cilium host firewall enforcing, 8 Argo CD Applications
  `Synced`/`Healthy` (checked 2026-11-22). The edge joins this cluster as a
  third node.
- Hetzner: firewall `bluefin-pilot` exists, applied to nothing (tcp/443,
  udp/443, udp/51820, udp/21820, udp/41641, icmp; no tcp/22, 6443, 6447,
  10250, udp/8472). No pilot server.
- cpx22 in hel1, read 2026-11-22: 2 shared vCPU, 4 GB, 80 GB disk,
  **€0.033/h gross** (F1's €0.039/h is stale), 20 TB traffic included.
  Seven days ≈ €5.55 plus the primary IPv4.
- The cluster host firewall (`fixtures/host-firewall.yaml`, policy
  `pilot-host`) admits from `world` **only udp/41641**. Host endpoints carry
  only `reserved:host`, so a hostname selector matched nothing. Public
  listeners on the edge need new rules (step 2).
- `tailnet-prep.sh` rewrites `/etc/default/kubelet`
  (`KUBELET_EXTRA_ARGS=--node-ip=…`) on every boot, so any other kubelet
  flag has to be added there, not in a second file.
- The render already leaves the 1.35 MB `pilot-lvm2` sysext out of Ignition
  (credentials over 1 MiB are refused), and bootstrap delivers it only to a
  node with the activation unit. The edge render just omits the data-disk
  units.
- Upstream facts (pinned source `d7f2890f`):
  - Node inputs arrive only as **system credentials**; `ignition.*` kernel
    arguments are ignored. Without SMBIOS/fw_cfg the documented path is
    encrypted `.cred` files in `/loader/credentials/` on the ESP, which
    systemd-stub passes on every boot (`tpm2-credential-sealing.md`,
    `usb-installer.md`).
  - A `--with-key=null` credential is obfuscated, not secret; upstream
    reserves it for non-secret payloads. It is refused on a machine with a
    TPM2 and Secure Boot on.
  - systemd-boot ships `secure-boot-enroll if-safe`, which enrolls the
    Bluefin keys by itself in VMs in Setup Mode. The keys and `loader.conf`
    are on the *installer's* ESP; whether the installed ESP carries what
    `if-safe` needs is **unproven** (local installs enrolled from the
    installer, stage 1, into a writable OVMF vars file that stays behind).
  - `bluefin-cluster` has `prepare`, `serve`, `join`, `hosts`, `passphrase`
    commands and **no passphrase rotation**.

## Decisions needed before implementation

Each has a recommendation. E1, E2, E6 and E10 block the paid step.

**E1: Install path.** Recommended: **install locally, rehearse locally,
stream the disk.**
1. Install with the proven `vm install` flow into a raw disk image of the
   cpx22 disk's size (Hetzner documents 80 GB; the exact byte count is
   read with `blockdev --getsize64` in the rescue boot, and the image is
   cut to it before streaming, never larger).
2. **Rehearsal (free, before any paid action):** boot a copy of that image
   in a new QEMU VM with **fresh, empty OVMF variables** (Setup Mode, no
   keys, like F1's cpx12), no SMBIOS or fw_cfg credentials at all, only
   what is on the image's ESP, user-mode networking only. Check: the
   fallback loader `\EFI\BOOT\BOOTX64.EFI` boots; what `if-safe` does
   (record `SetupMode`, `SecureBoot`, enrolled keys before and after); the
   ESP credentials are picked up (`systemd-creds list` at boot, Ignition
   staged in `/run/ignition/user.ign`); first-boot root creation; the
   release pin; and the E2 flow end to end against the real cluster (the
   rehearsal VM joins the tailnet with a throwaway key and the cluster as
   `bluefin-pilot-edge`, then is deleted with its tailnet device and Node).
   If anything fails here, fix it here.
3. On Hetzner: rescue boot, then a **full write** (no reliance on discard
   or sparse holes): `zstd -c disk.raw | ssh rescue 'zstd -d | dd of=<disk>
   bs=4M iflag=fullblock oflag=direct status=progress'`, where `<disk>` is
   the one disk `lsblk` shows (refuse if there is more than one). Zeros
   compress to almost nothing, so transfer stays small. Then `sync`,
   compare `sha256sum` of the whole device with the image's, check the GPT
   (`sgdisk -v`), and only then remove the temporary tcp/22 rule (operator
   IP only, recovery H3) and reboot.
Alternatives (fallbacks, in order): recovery H4.1 (installer on an
attached Hetzner Volume); H4.2 (write the OS DDI directly). Whichever path
passes, recorded with its exact commands, becomes procedure H4, and a
second run of it (reinstall, step 1e) is what proves provider recovery.

**E2: Secrets during first boot.** There is no way to get a secret onto a
Hetzner disk the provider cannot read without a TPM, and the join passphrase
cannot be rotated. Recommended: **keep the ESP secret-free and send
enrollment secrets over the tailnet.**
- ESP (null-key): `ignition.config` (SSH public key, units, the release
  pin; no secret) and the **Tailscale auth key**, as a new **single-use**,
  pre-approved, not ephemeral, 1-day key for `tag:bluefin-pilot` only.
  That key is the one unavoidable on-disk secret; single use means it is
  worthless once the node has joined. A bootstrap step deletes its `.cred`
  from the ESP after the join.
- No root password credential: root stays locked until the node is on the
  tailnet; then bootstrap sets a unique console password over SSH
  (`chpasswd -e` with a hash from new vault item
  `root-console-password-edge`), stored in `/etc/shadow`. Until then the
  console fallback is the rescue system (H3), not a login.
- The **join passphrase** goes over SSH on the tailnet into
  `homelab.conf` (`HOMELAB_JOIN_PASSPHRASE`) followed by a restart of the
  join unit; the template then removes it from `homelab.conf`. The
  rehearsal (E1.2) proves the join unit picks it up that way.
- Verify after cleanup: ESP inventory shows only `ignition.config.cred`;
  a cold boot (`poweroff`/`poweron`) brings the node back with the same
  tailnet identity, Ignition still staged, console login with the new
  password, Node `Ready`.
If a TPM is present (`ls /sys/class/tpm` in rescue) **and** Secure Boot
ends up on, null-key credentials are refused: then `ignition.config` and
the auth key are sealed on the node itself, from the rescue system, with
`systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs=` (no PCRs: the rescue
and installed boot chains differ, so any PCR policy would fail to unseal),
and step 1c proves the installed UKI decrypts them after enrolment and a
cold boot. Rejected: `ignition.config.url` (moves the secret to a server,
and every later boot needs the URL too).

**E3: Public ingress through the host firewall.** Recommended: a separate
`CiliumClusterwideNetworkPolicy` `pilot-edge-public` admitting `world` on
tcp/443 and udp/443, and udp/51820 + udp/21820 only during the Pangolin
arm and tcp/80 during the Envoy arm's issuance only (E4), scoped with
`nodeSelector` on the edge's label. Because host endpoints
here carry only `reserved:host`, the selector may again match nothing: the
step 2 control proves it with a known listener (`python3 -m http.server`
or a socat fixture on 443 before any edge workload) and
`cilium-dbg monitor --type policy-verdict` on the edge showing *allowed*,
plus a not-allowed port showing *denied*, so a Hetzner firewall drop is
never mistaken for Cilium's. If the selector does not match, fall back to
the same rule cluster-wide (the home nodes are behind NAT and have no
public listener), recorded as such.

**E4: Test DNS and ACME. Decided: a pilot subdomain, no DNS token.** The
production DNS-01 token (`cfDnsApiToken`, Cloudflare) can edit the whole
production zone (tokens scope to a zone, not a subdomain), so the pilot
uses none. The operator adds `*.pilot.<production domain>` (A only, E8)
pointing at the edge IP by hand in Cloudflare after creation; it is more
specific than the production wildcard, so production names are unaffected.
Both arms use Let's Encrypt **staging** and per-hostname certificates (no
wildcard without DNS-01). Pangolin's Traefik uses **TLS-ALPN-01** on 443
(a pilot-only `tlsChallenge` resolver, not the production `dnsChallenge`).
cert-manager has no TLS-ALPN-01 solver, so the Envoy arm uses **HTTP-01**
through a Gateway listener on tcp/80, which is opened in the
`bluefin-pilot` Hetzner firewall and in `pilot-edge-public` (E3) for the
Envoy arm only and closed again after its certificates are issued and one
renewal-path check (`cmctl renew`) has passed. Cleanup deletes the record.

**E5: Running the two arms.** Both need 443/tcp+udp on the one IPv4.
Recommended: **sequential on the same node**, Pangolin arm first, same
hostnames and load profile. Before the Envoy clock starts, the Pangolin
Application, pod and its sockets must be gone (`ss -lntup`). Alternatives:
a floating IP (≈€0.005/h plus host config); alternate ports (breaks the
like-for-like HTTP/3 check). Each arm gets the full plan gate; an arm that
misses its window is reported **incomplete**, not passed.

**E6: Load baseline (fixed before step 5). Decided: measure it.** The
plan gate is "HTTPS at 2× the Phase 0 peak request rate and concurrency,
plus a sustained tunnel transfer at flutterina's recorded peak throughput
(170 Mbit/s, beszel) for ≥ 1 h per day". flutterina's Traefik has neither
metrics nor access logs, so:
- **Request rate and concurrency:** a minimal Traefik access log on
  flutterina (decided 2026-11-22 over Prometheus metrics, which would need a
  scraper and sample concurrency only once a minute). JSON to stdout, so it
  lands in `traefik.service`'s journal; every field dropped except
  `StartUTC`, `Duration`, `RouterName`, `DownstreamStatus` and
  `RequestProtocol` (no client IPs, paths, hosts or headers; checked against
  the pinned v3.7.19 image locally). Deployed through materia: one
  `traefik.service` restart, safe since BUG-009's `ExitPolicy=continue`.
  Collect 7 days while the free parts of this phase are built, export the
  journal lines to `~/.cache/bluefin-pilot/`, then remove the block. Peak
  request rate per second and per minute, and peak concurrency (requests
  in flight, from start + duration), excluding Pangolin-internal routers;
  the gate is 2× each. Recorded in the results before step 5.
- **Transfer:** measure the home uplink first (the workstation is the load
  source). If it carries 170 Mbit/s, the gate stands. If not, the plan is
  amended **before step 5** to the measured uplink figure, and the result
  is stated as "sustained at N Mbit/s (home uplink bound)", never as sized
  for flutterina's peak.

**E7: What "tunnel" means here.** Since #163 app traffic reaches the edge
over Tailscale. Recommended: the sustained transfer uses the future data
path, edge pod → Cilium VXLAN over the tailnet → a backend pinned to the
home worker (a dedicated HTTP fixture with a pinned image; not Jellyfin,
whose claim is tied to the control plane's data PV). Plus one Gerbil check:
a Newt pod on the home worker registered as a pilot site, which proves
Gerbil's WireGuard under `hostNetwork` beside Cilium; it is a function
check, not the load gate.

**E8: IPv6 (F6).** The homelab Cilium is IPv4-only, so the host firewall
does not see IPv6. Recommended: disable IPv6 on the public NIC (sysctl via
Ignition) and show, per port (tcp/22, 443, 6443, 6447, 10250; udp/443,
8472, 41641), from an external IPv6 host, that nothing answers; the Hetzner
firewall stays as a second layer. Alternatives: the Hetzner firewall alone;
Cilium IPv6 (cluster-wide, out of scope).

**E9: Optional cloud control-plane variant.** Recommended: **defer** until
both arms pass; it needs a second paid server (cpx32, €0.060/h) and its own
confirmation.

**E10: Schedule.** The cloud pilot runs at most 7 days from `server
create`. Recommended plan (hours from creation):

| Window | Work | Latest start |
| --- | --- | --- |
| 0–12 h | install, steps 1–2 | — |
| 12–30 h | Pangolin steps 3–4 | 24 h |
| 30–78 h | Pangolin 48 h run | 36 h |
| 78–90 h | switch, Envoy steps 3–4 | 90 h |
| 90–138 h | Envoy 48 h run | 100 h |
| 138–156 h | spare: one voided window's retry, reinstall test (1e) | — |
| by 160 h | export evidence, teardown, inventory empty | — |

A window not started by its latest start is skipped and reported
incomplete. Deletion happens by the confirmed deadline unless the user
extends it in writing; a Phase 5 hand-over counts against the same
deadline. Everything that can be built and rehearsed without the server
(tooling, fixtures, both arms' manifests on the home worker with test
ports, the load and probe harness) is done before creation.

## Layout

| Item | Where |
| --- | --- |
| Edge render | `mise bluefin:pilot:render --vm bluefin-pilot-edge --topology tailnet`: role node, no data/backup units, no root password credential, IPv6 sysctl; `tailnet-prep.sh` gains the edge's kubelet flags (`--node-labels`, `--register-with-taints=pilot.bluefin/edge=true:NoSchedule`) in the same `KUBELET_EXTRA_ARGS` line |
| Disk image | `mise bluefin:pilot:vm install --vm bluefin-pilot-edge --raw --size <bytes>` and `vm rehearse` (fresh OVMF vars, ESP credentials only); `mise bluefin:pilot:esp-creds` writes null-key `.cred` files with `mtools` |
| Hetzner | `mise bluefin:pilot:hz create\|rescue\|stream\|console\|delete`: `pilot=bluefin` labels, the `bluefin-pilot` firewall at creation, the temporary tcp/22 rule limited to the operator's IP, refuses any server name but `bluefin-pilot-edge` |
| Edge bootstrap | `mise bluefin:pilot:bootstrap --edge`: console password, join passphrase over SSH, ESP auth-key removal, `pilot-edge-public` policy |
| Edge workloads | `provisioning/bluefin/gitops/workloads/pilot-edge-pangolin/` and `…/pilot-edge-envoy/`, one Application enabled at a time |
| Edge state | local PV on the edge (`/var/lib/pilot-edge`), synthetic data only |
| Probes | `mise bluefin:pilot:edge-probe` (HTTPS/HTTP/3 with the staging root as explicit trust, outage log) and `mise bluefin:pilot:edge-load` (E6 profile, CSV) |
| Evidence | raw captures, renders, credentials and disk images stay under `~/.cache/bluefin-pilot/` (0700); the results file gets redacted figures only |

## Steps and verification (plan Phase 4, with thresholds)

Thresholds are the plan's (or a prospective amendment, E6); each is
recorded in the results before its step. Before creation: the tailnet
policy tests (pilot ↔ production denial) re-run, and again after any grant
change.

1. **Install.**
   0. **Server type (operator request, 2026-11-22):** at creation time,
      check whether **cx23** is orderable in hel1 (`hcloud server-type
      describe cx23`; it comes and goes, and was available on 2026-11-22 at
      €0.011/h gross, 40 GB disk). If it is, first run F1's two-minute
      firmware probe on a cx23 (Debian image, `test -d /sys/firmware/efi`,
      delete): flutterina's cx23 boots legacy BIOS, and Bluefin needs UEFI.
      If the new cx23 boots UEFI, use it: it is flutterina's own type, so the
      step 5 run sizes the real box, at a third of cpx22's price; the E1
      image is then cut to its 40 GB disk. If it boots BIOS or is not
      orderable, use cpx22 as below. Record the outcome in F1.
   a. `hcloud server create` cpx22 (or cx23, step 0) hel1, firewall at creation, label
      `pilot=bluefin`, rescue enabled. In rescue: `lsblk`, `blockdev
      --getsize64`, `ls /sys/class/tpm`, `efibootmgr -v`, `SetupMode` /
      `SecureBoot` variables, enrolled keys.
   b. Stream (E1.3), verify readback, remove tcp/22, reboot to disk.
   c. Over the tailnet once joined (no console login exists yet):
      `test -d /sys/firmware/efi; bootctl status; findmnt /`, os-release
      2506, sysupdate transfers pinned (F11), Secure Boot state and keys
      after `if-safe` (F4), `systemd-creds list`.
   d. Bootstrap (E2), then reboot twice and `poweroff`/`poweron` once,
      recording Secure Boot state each time (does NVRAM persist?). H1
      console: root login works with `tailscaled` stopped.
   e. In the spare window: reinstall over the installed disk by the same
      path (procedure H4), back to `Ready`.
   Pass: boots from disk, release 2506, the three restarts clean, H4
   recorded. Fail: fallbacks per E1, each attempt recorded.
2. **Join and network.** First Node object already has the tailnet
   `InternalIP`, the edge label and the taint (`kubectl get node -o yaml`
   from the first registration). MetalLB speakers and L2 announcements
   exclude the edge. Then Phase 2's tests: `cilium connectivity test`
   under enforcement; E3's control and denial probes against the public
   IPv4 (tcp 22, 6443, 6447, 10250 refused; udp 8472 judged by Cilium
   verdict, not silence); E8's IPv6 probes; 10-minute tailnet outage and
   10-minute NIC outage on the edge: `Ready` within 5 min of restore,
   repeated 64 MiB transfers between pods pinned to opposite sites with
   zero checksum mismatches; a long-lived TCP stream across each outage;
   DNS from an edge pod; pod-to-tailnet from an edge pod. `readyz` p95 from
   the edge over the path actually used (`tailscale status`: direct or
   relay, recorded), threshold 500 ms carried from Phase 2.
3. **Edge pod (each arm).** Pangolin: one pod, app + Gerbil + Traefik,
   `hostNetwork`, Gerbil `NET_ADMIN`, nodeSelector + toleration, state on
   the edge PV, staging ACME on the E4 domain, digests as in
   `components/pangolin/`. Envoy: Gateway with an EnvoyProxy bound on the
   edge (its generated Deployment's placement and TCP/UDP binds checked),
   cert-manager staging issuer, `ClientTrafficPolicy` HTTP/3, the same
   routes as `HTTPRoute`s. Verify per arm: all containers ready; `ss
   -lntup` diffed against the pre-deploy capture shows exactly the
   intended public ports; from outside, HTTPS and `curl --http3-only`
   with the staging root as trust, checking hostname, chain and the HTTP
   version actually negotiated; a route to the home backend (E7); a health
   check request (Pangolin: a target health check on the home backend
   turns healthy; Envoy: active health check); Pangolin only: the Newt
   site check; E3/step 2 denials repeated with the arm running; SSH over
   the tailnet. Envoy only: one tailnet-only route via the Tailscale
   operator, and existing routes keep serving for 10 minutes with the
   control plane stopped.
4. **Restarts under probe load.** Pangolin: back up the pilot state,
   restore into a fresh pod on a clean PV (database readable, org and
   resources present), then (a) kill the app process: pod UID unchanged,
   only the app's `restartCount` moves; (b) delete the pod. Envoy: (a)
   delete the proxy pod; (b) delete the controller pod. Pass for each:
   (a) outage ≤ 2 min, (b) ≤ 5 min, no crash loop, no manual action, from
   the probe log; endpoints and (Pangolin) the database readiness query
   pass afterwards.
5. **48 hours per arm** with the E6 profile. Pass: zero OOMs, zero kubelet
   pressure/eviction events, ≥ 25 % RAM and disk headroom, 5xx +
   connection errors < 0.1 % outside deliberate restarts. Sampled each
   minute: `free`, `df`, CPU and `%steal`, per-container memory, the load
   tool's error counts. A control-plane outage on the workstation voids
   that window (retry in the spare window). Fail → report the larger size
   and cost.
6. **Cleanup** by the deadline: delete the server and its primary IPs,
   rescue SSH keys, the `*.pilot` DNS record and the tcp/80 rule if still open (E4), the edge's
   tailnet device and auth key; `hcloud {server,primary-ip,ssh-key,volume}
   list -l pilot=bluefin` empty. The `bluefin-pilot` firewall stays until
   the whole pilot ends.

Exit (plan): provider install and recovery work, the edge worker is stable
across the WAN, and each arm serves ingress beside cluster networking at a
measured capacity, or is reported incomplete.

## Paid actions and confirmation

Creating the server (step 1a) is the first paid action, and only after the
E1.2 rehearsal has passed. Before it, the user confirms cost (cpx22
€0.033/h, ≈ €5.55 for 7 days, or cx23 €0.011/h, ≈ €1.85, plus IPv4, and
the step 1.0 cx23 probe at a few cents), the deletion deadline (creation +
7 days, written into the results), and that the E6 baseline is in. A
floating IP or a cpx32 each need their own confirmation.

## Risks and open points

- **Secure Boot auto-enrol on Hetzner** may enable enforcement on first
  boot; if NVRAM does not persist, every power cycle is a fresh Setup Mode
  and the credential outcome may change between boots. The rehearsal shows
  what the image does; step 1d shows what Hetzner keeps.
- **No console login until the tailnet works.** If the first boot never
  reaches the tailnet, the only access is the rescue system (H3). The
  rehearsal makes that unlikely; accepted for a disposable node.
- **Cilium on a public NIC** is new. Keep `--reapply-firewall` ready and
  the H1 console open while enforcing.
- **The control plane is on the workstation**, which OOMs and reboots now
  and then; see the void rule in step 5.
- **Pangolin's first-run setup** (admin, org) is interactive: script it
  through the API with synthetic values, or record it as a manual step.
- **Public repo:** tailnet prep logs the node IP and control-plane FQDN;
  results get redacted copies only. Scan every commit and issue comment.
