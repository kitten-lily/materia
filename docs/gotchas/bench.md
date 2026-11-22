# Sizing benchmarks

Read this guide when running or comparing bench tasks and interpreting their results.

## Sizing tasks (`bench:*`)

`mise bench:vps` benchmarks any reachable host — a candidate VPS from any
provider, or the workstation — on the axes that actually bound the edge
node, and `mise bench:compare` renders every result in `bench/results/`
side by side. Plan and measured results:
`specs/plans/vps-benchmark-harness.md`.

| Task | Description |
|---|---|
| `mise bench:vps [--target <user@host>]` | Run the suite; omit `--target` to benchmark the workstation. `--sections crypto,cpu,disk,net,tunnel`, `--duration`, `--workdir`, `--net-url`, `--label` |
| `mise bench:compare` | Table of every `bench/results/*.json` |

Everything runs in a throwaway `alpine` podman container built on the
target — the fleet is Flatcar, which has **no package manager**, and a
candidate VPS shouldn't get its host polluted. The only requirement on a
target is podman; a stock Debian/Ubuntu image gets it via one cloud-init
`packages:` line. Extra ssh options go in **`BENCH_SSH_OPTS`**, not a
flag — mise's `usage` parser rejects a flag value starting with `-`.

Sections map one-to-one onto observed bottlenecks; nothing generic is
measured for its own sake. `crypto` (`openssl speed` AES-GCM +
ChaCha20-Poly1305 at 8 KiB) predicts Traefik's TLS ceiling and
wireguard-go's; `cpu` reports `%steal` sampled from the host-wide
`/proc/stat` across a saturating run (the tell for an oversubscribed
shared vCPU); `disk`'s 4 KiB `fsync=1` job is the SQLite commit path
(pangolin's app DB, beszel's PocketBase); `tunnel` runs real
`wireguard-go` between two netns and pushes iperf3 through it — the
actual gerbil/newt data path, not just cipher speed. `tunnel` is
**opt-in**: it needs NET_ADMIN/SYS_ADMIN and saturates every core, so it
is not something to fire at a live public ingress casually. Its absolute
number is ~half the box's real proxying capability (both WireGuard *and*
both iperf3 endpoints share the box) — it is a relative measure.

**Measured 2026-09-24, and it overturned an inference:** a *single*
`cpx12` vCPU (AMD EPYC-Genoa) sustains **1781 Mbit/s** through userspace
WireGuard with both endpoints competing for that one core, and is
**2.5× faster than a `cx23` core at AES-GCM** (8814 vs 3562 MB/s, 1
thread). The earlier "1 vCPU would cap the tunnel path at 100–200
Mbit/s" reasoning — derived from spec sheets and beszel utilisation —
was wrong by an order of magnitude against flutterina's 170 Mbit/s peak.
RAM and disk remain the real constraints on a 2 GB / 25 GB box; CPU never
was one. Do not size the edge node from core *counts* again without
measuring: a newer generation's single core beat an older generation's
pair on every single-threaded axis.

Four non-obvious things the harness had to work around, all of which
will bite any similar containerised probe:

- **`ip netns exec` AND `ip -n` both fail inside a container** with
  `mount of /sys failed: Operation not permitted`, even with
  `--privileged`. Both go through iproute2's `netns_switch()`, which
  unshares the mount namespace and remounts `/sys`. Use
  `nsenter --net=/var/run/netns/<ns>` — a plain `setns(2)` — which works
  with just `--cap-add=NET_ADMIN,SYS_ADMIN`.
- **`wireguard-go`'s UAPI socket (`/var/run/wireguard/<iface>.sock`)
  lives in the *mount* namespace, not the net namespace.** Two instances
  named `wg0` in two different netns collide with
  `UAPI listen error: unix socket in use`. Give each side a distinct
  interface name.
- **`fio --output-format=json` writes advisory notes to STDOUT ahead of
  the JSON document** (e.g. `note: both iodepth >= 1 and synchronous I/O
  engine are selected`), so piping it into `jq` breaks with
  `Invalid numeric literal`. Route the report through `--output=<file>`.
- **`openssl speed` labels rows with the canonical cipher name**
  (`AES-128-GCM`, `ChaCha20-Poly1305`), not the lowercase string passed
  to `-evp` — match case-insensitively or every value silently parses as
  0.

`bench/` is gitignored (results embed hostnames/IPs). The entry is
root-anchored (`/bench/`) — an unanchored `bench/` also swallows
`.mise/tasks/bench/`.
