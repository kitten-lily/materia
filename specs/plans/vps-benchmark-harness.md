# Plan — VPS benchmark harness (`mise bench:*`)

Status: PLANNED → IMPLEMENTED 2026-09-24. No GitHub issue (tooling-only,
no component/IaC change). Related: #102 (Hummingbird migration, adds
Contabo as a third provisioning target — this harness is how a candidate
Contabo/Hetzner instance gets compared against flutterina before anything
is migrated onto it).

## Problem

Sizing decisions for the edge node are currently made from provider spec
sheets ("1 vCPU / 2 GB / 25 GB") plus beszel's *observed* utilisation of
the box we already run. Neither answers the question that actually
matters: **can candidate hardware move the traffic flutterina moves?**

Evidence from the 2026-09-24 sizing review (beszel `system_stats`,
30 days of `480m` buckets, system `Flutterina`):

| metric | value |
|---|---|
| CPU mean | 2.39 % of 2 vCPU |
| CPU within-bucket max, p95 / max | 59 % / 77.8 % of 2 vCPU |
| RAM used mean / max | 1.24 / 1.42 GB (`mm` peak 1.54 GB) |
| Swap | none (`s`/`su`/`mz` all 0) |
| Disk used | 13.07 GB of 30.04, +4.39 GB / 30 d |
| Peak network (Hetzner, 432 s avg) | 21 MB/s out, 20 MB/s in |

Steady-state CPU is irrelevant — the box idles. The ceiling is the
**burst** path: bow's media traffic transits the edge through
gerbil/newt's *userspace* WireGuard (`wireguard-go`) and Traefik's TLS
termination, both of which are single-stream CPU-bound AEAD work. A spec
sheet cannot tell you whether a given shared vCPU sustains 170 Mbit/s
through that path; a benchmark can.

## Scope

A provider-agnostic, distro-agnostic harness that produces **comparable
JSON** for any reachable host, plus a renderer that diffs result files.

Non-goals: provisioning candidate VPSes (that is `hz:create` /
`contabo:create` in #102), continuous benchmarking, replacing beszel.

## Design

### Why these five sections

Every test maps to a bottleneck observed on the real workload. Nothing
generic is included for its own sake (no Geekbench-style composite
score — a composite hides exactly the axis that decides this).

| Section | Test | Maps to |
|---|---|---|
| `crypto` | `openssl speed -evp aes-128-gcm -evp chacha20-poly1305` @ 8 KiB, 1 thread and N threads | Traefik TLS (AES-GCM w/ AES-NI) and wireguard-go (ChaCha20-Poly1305). The single most decision-relevant number. |
| `cpu` | `sysbench cpu` 1 thread + N threads; `%steal` sampled from `/proc/stat` across the N-thread run | General headroom; **steal** exposes oversubscribed shared vCPU (the specific risk on budget providers). |
| `disk` | `fio`: seq write 1 MiB; 4 KiB randwrite `fsync=1` (IOPS + p99 latency); 4 KiB randread QD16 | `fsync=1` is the SQLite commit path — Pangolin's app DB and beszel's PocketBase. Seq write is the restic backup window. |
| `net` | HTTP download of a fixed 100 MB object; ICMP RTT to the same host | Edge ingress/egress and provider peering. |
| `tunnel` | Two network namespaces joined by a veth pair, `wireguard-go` on each side, `iperf3` through the tunnel | End-to-end userspace-WireGuard throughput — the actual gerbil/newt data path, including syscall and scheduler cost, not just raw cipher speed. |

`tunnel` is **opt-in** (`--sections`), not in the default set: it needs a
privileged container and saturates every core for its duration, which is
not something to fire at a live public ingress without intent. On an
idle candidate box it is the number worth having.

Known distortion, documented rather than hidden: the `tunnel` test runs
both WireGuard endpoints *and* both iperf3 endpoints on the box under
test, so the absolute figure is roughly half of what the box could do
proxying between two external peers. It is valid as a **relative**
comparison across boxes, which is the question being asked.

### Execution model

- Everything runs inside a throwaway `podman` container built on the
  target from an inline Dockerfile (`alpine:3.22` + `openssl fio
  iperf3 sysbench wireguard-go wireguard-tools`). Reason: the fleet runs
  Flatcar, which has **no package manager** — installing benchmark tools
  on the host is impossible, and polluting a candidate VPS's host
  filesystem is undesirable anyway. Podman is the one runtime guaranteed
  present on every host this repo manages.
- `--network=host` for `net` (container NAT would understate throughput).
- `fio` writes into a bind-mounted host directory (`--workdir`, default
  `/var/tmp/bench`), never the container's overlay, or the numbers
  measure the graph driver rather than the disk.
- Host facts (CPU model, core count, RAM, disk, kernel, virt type) are
  collected **outside** the container via plain shell, since
  `systemd-detect-virt` and `/etc/os-release` are host properties.
- `--target` is any ssh destination; omit it to benchmark the
  workstation (useful as a sanity reference and for testing the harness
  itself).

### Output

`bench/results/<label>.json`, one object per run. `bench/` is
gitignored — results embed hostnames/IPs and the repo stays generic
(CONVENTIONS.md § Keep the repo generic).

`mise bench:compare` reads every `bench/results/*.json` and renders one
table per section, so two providers sit side by side.

## Files

```
.mise/tasks/bench/vps       # NEW — run the suite against a target, write JSON
.mise/tasks/bench/compare   # NEW — render a comparison table across results
.gitignore                  # EDIT — ignore bench/
specs/plans/vps-benchmark-harness.md  # this file
AGENTS.md                   # EDIT — harness + its gotchas
```

No component, quadlet, attribute, or provisioning change. Preflight
surface is unchanged.

## Verification (executed 2026-09-24)

1. Local run, all five sections, on the workstation — valid JSON, every
   field populated. Exercised every code path including `tunnel`.
2. Remote SSH + remote-podman path proven against two **disposable
   Hetzner instances** (`bench-cx23`, `bench-cpx12`, Debian 13 + podman
   via cloud-init, hel1, created and destroyed within the session —
   `hcloud server list` confirms only `flutterina` remains, and the
   throwaway `bench-temp` ssh-key was deleted).
   `core@bow` was *not* used: the `ssh:Bow` FIDO2 key's agent signature
   was refused twice (`agent refused operation`), so it proves nothing.
3. `mise bench:compare` renders both results side by side.
4. `mise clean && mise ign --server-name flutterina` — Preflight green.

### Result — cx23 (current flutterina spec) vs cpx12 (1 vCPU / 2 GB)

| metric | cpx12 (1 vCPU) | cx23 (2 vCPU) |
|---|---|---|
| CPU | AMD EPYC-Genoa | AMD EPYC-Rome |
| RAM MB / swap MB | 1921 / 0 | 3826 / 0 |
| AES-128-GCM 1T MB/s | **8813.8** | 3562.1 |
| ChaCha20-Poly1305 1T MB/s | **3509.8** | 2146.4 |
| sysbench 1T ev/s | **3766.4** | 3325.4 |
| sysbench NT ev/s | 3744.3 | **6580.4** |
| steal % under load | 0.00 | 0.00 |
| seq write MB/s | 1488.4 | 1117.9 |
| 4k randwrite fsync IOPS | 2834 | 2644 |
| fsync p99 us | 32 | 23 |
| download MB/s / RTT ms | 672.1 / 0.77 | 727.2 / 0.67 |
| **wireguard-go Mbit/s** | **1781** | **2766.9** |

**This overturns the CPU half of the 2026-09-24 sizing review.** That
review inferred that one shared vCPU would cap the gerbil/newt userspace
WireGuard path at "100–200 Mbit/s" and throttle media streaming. Measured:
a single cpx12 vCPU sustains **1781 Mbit/s** through userspace WireGuard
*with both tunnel endpoints and both iperf3 endpoints competing for that
same core* — an order of magnitude above flutterina's observed 170 Mbit/s
peak. Its newer EPYC-Genoa core is also **2.5× faster than a cx23 core**
at AES-GCM, so a 1-vCPU cpx12 is not slower per-core than today's box; it
only loses aggregate (NT) capacity and parallelism. Steal was 0 on both.

What the benchmark does **not** overturn: RAM (1921 MB usable against a
measured 1.54 GB peak RSS, with zero swap) and disk (25 GB against 13.07 GB
used growing +4.4 GB/month). Those remain the blockers; CPU never was one.

Caveat: the benchmark instances are not flutterina. Hetzner does not
guarantee a host CPU model per server type — the `cx23` instance here
reported EPYC-Rome — so treat per-model figures as indicative of the
*plan*, not of one specific running server.

## Open

- Benchmarking **flutterina itself** needs the `ssh:Hetzner` FIDO2
  resident key loaded (`ssh-keygen -K` + `ssh-add`); the workstation
  currently carries only `ssh:Bow`, `ssh:Signing`, `ssh:KrytisBuild`.
  Run the safe sections only (`--sections crypto,cpu`) against a live
  public ingress — `tunnel` saturates every core and `disk` writes 512 MB.
- The `net` section's download source is a fixed public 100 MB object;
  it measures the path to *that* host, so it is only comparable between
  boxes benchmarked against the same URL. Override with `--net-url`
  when comparing across continents.
