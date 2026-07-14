# Implementation Plan — Issue #34: nftables missed podman's default bridge

**issue:** https://github.com/kitten-lily/materia/issues/34
**risk:** P1 (production backup job on `bow` has been silently failing on
every run since deployment — this fix restores it)
**epic:** standalone (discovered while investigating #31; unrelated root
cause)

## Summary

`restic-backup.service` on `bow` failed every run today with DNS
resolution failures and healthchecks.io ping timeouts. Root cause:
`provisioning/templates/bare-metal.bu`'s nftables rules only allow traffic
from `10.89.0.0/24` — which is `newt-net`'s subnet, not podman's default
bridge (`10.88.0.0/16`, network name `podman`, interface `podman0`).
`restic-backup.container` has no explicit `Network=`, so it runs on the
default bridge and every DNS/SSH/HTTPS call from it was silently dropped
by the `input`/`forward` chains' default-drop policy.

## Evidence (bow, 2026-07-14)

```
$ podman network inspect podman
  "network_interface": "podman0", "subnets": [{"subnet": "10.88.0.0/16"}]
$ ip route
10.89.0.0/24 dev podman1 proto kernel scope link src 10.89.0.1
```

Two separate podman-managed subnets exist on `bow`: the default bridge
(`10.88.0.0/16`, `podman0`) and `newt-net` (`10.89.0.0/24`, `podman1`).
The nftables fix from #9 only covered the latter — it happened to look
correct because `newt` worked, masking that the default bridge was never
covered.

## Fix

Widened the `input` DNS exception and `forward` egress exception in
`provisioning/templates/bare-metal.bu` from a single `/24` to a two-member
set:

```diff
-ip saddr 10.89.0.0/24 udp dport 53 accept
-ip saddr 10.89.0.0/24 tcp dport 53 accept
+ip saddr { 10.88.0.0/16, 10.89.0.0/16 } udp dport 53 accept
+ip saddr { 10.88.0.0/16, 10.89.0.0/16 } tcp dport 53 accept
```

```diff
-ip saddr 10.89.0.0/24 accept
+ip saddr { 10.88.0.0/16, 10.89.0.0/16 } accept
```

`10.88.0.0/16` is podman's hardcoded default-bridge subnet (stable across
podman versions per `libnetwork/config.go`'s
`DefaultSubnetForNetworks`/`network.default` config). `10.89.0.0/16` is a
generalization of the current `10.89.0.0/24` — containers-common's
`default_subnet_pools` allocates named networks a `/24` at a time starting
at `10.89.0.0/24` and incrementing, so this covers `newt-net`'s current
subnet plus every future named network without another nftables edit.

## Deployment

This is a `provisioning/templates/` change — per the "Butane changes don't
reach a running host" gotcha (AGENTS.md), it does not retroactively apply
to `bow`. Two paths, not mutually exclusive:

1. **Immediate hand-fix on `bow`** (restores backups today without a
   reboot): edit `/etc/nftables/rules/main.nft` to widen the two
   `ip saddr` lines the same way, then `sudo systemctl restart nftables`.
   Verify with `sudo nft list ruleset` and a manual
   `sudo systemctl start restic-backup.service` + `journalctl -u
   restic-backup.service -f`.
2. **Template fix** (this commit) — takes effect on `bow`'s next full
   re-provision (iPXE), and on any new bare-metal server from now on.

Both are needed: (1) fixes the live incident now, (2) prevents every
future bare-metal server from shipping with the same gap.

## Steps

1. Edit `provisioning/templates/bare-metal.bu`'s nftables block (done).
2. Add an `AGENTS.md` gotcha documenting the two-subnet distinction
   (default bridge vs. named-network pool) so this isn't rediscovered on
   the next bare-metal server.
3. Preflight: `mise clean && mise ign --server-name bow` (butane
   `--strict` validates syntax; `server.toml`'s placeholder disk paths
   don't block transpilation).
4. Commit as a single focused `fix:` commit.
5. Hand off the live-host hotfix commands to the user to run on `bow`
   directly (out of scope for an agent to execute unattended against a
   production firewall over SSH).

## Out of scope

- Actually applying the hotfix on `bow` — requires the user's physical
  security-key touch for SSH auth and is a live firewall change on a
  bare-metal box with no cloud console fallback; handed off, not executed
  here.
- Re-provisioning `bow` via iPXE to pick up the template fix organically —
  a separate, larger action the user can schedule independently.
