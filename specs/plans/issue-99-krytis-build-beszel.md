# Implementation Plan — Issue #99: Add beszel-agent monitoring to krytis-build

**issue:** https://github.com/kitten-lily/materia/issues/99
**risk:** P2 (new host onboarding path — no changes to existing hosts/components;
the new "adopted" server type is additive to `server:new`, existing `hetzner`/
`bare-metal` types untouched)
**epic:** standalone

## Summary

`krytis-build` is the OS hostname (per Proton Pass "Krytis Build VPS"
item) of the self-hosted GitHub Actions runner VPS owned by the `krytis`
repo (Contabo Cloud VPS, Debian 13/trixie) — registered as the
`krytis-vps` GitHub Actions runner label, but **not** the same machine as
`bow` (materia's own Hetzner/Flatcar Buildbarn host; confirmed by the
user, corrected from an earlier wrong assumption). This plan uses
`krytis-build` as the materia server identity throughout, matching this
repo's "one name is the OS hostname" convention — `krytis-vps` is only
ever krytis's own GitHub Actions runner label, a separate namespace. It
was hand-provisioned via krytis's own `mise runner-vps:install`; this
repo has no visibility into it at all — no `[Hosts.krytis-build]` entry,
no Ignition/Butane provisioning, never touched materia.

Goal: bring `krytis-build` under materia management for exactly one
component, `beszel-agent`, so it reports into the same beszel-hub
(`beszel.ririi.dev`) as `bow`/`flutterina`.

## Architecture decisions

### New "adopted" server type — materia's daemon installed by hand, not Ignition

Every existing host (`bow`, `flutterina`) was born via Ignition at first
boot (`hetzner.bu`/`bare-metal.bu`). Per this repo's own documented
constraint ("Butane changes don't reach a running host — Ignition runs
once at first boot"), that flow cannot apply here: `krytis-build` is already
running, already serving as a live CI runner, and cannot be reprovisioned
from scratch.

materia's daemon is architecturally just a podman quadlet
(`ghcr.io/stryan/materia:stable`, `Exec=update`) triggered by a systemd
timer — nothing about it actually requires Flatcar or Ignition, only
podman + systemd + the same four files Ignition would otherwise write
(`/etc/materia/config.toml`, `/etc/materia/key.txt`,
`/etc/containers/systemd/materia-update.container`,
`/etc/systemd/system/materia-update.timer`). `krytis-build` already has
podman (installed by `files/runner-vps/provision.sh` in the krytis repo).

So: add a third `server:new --type adopted` alongside `hetzner`/
`bare-metal`, and a new `server:adopt-render` task that renders those four
files locally (reusing the exact same fnox-sourced secrets `mise ign`
uses — shared age key, healthchecks ping URL, detected `REPO_URL`) for
manual `scp`+SSH install. No Butane/Ignition involved; the rendered
`materia-update.container`/`.timer` content is copied verbatim from
`hetzner.bu` so the deployed unit is identical in behavior to every other
host's.

`provisioning/servers/krytis-build/server.toml` still gets created (keeps
the "one name identifies a server everywhere" convention intact — the
`MANIFEST.toml` `Hosts.<name>` key and the `provisioning/servers/<name>/`
directory stay paired even though there's no `[bare_metal]`/`[hetzner]`
table to fill in), but its `type = "adopted"` is never read by `mise ign`
(that task only handles `hetzner`/`bare-metal` and errors on anything
else) — it exists purely so `server:adopt-render` can confirm it's
pointed at the right kind of host and so a future reader of
`provisioning/servers/` sees why this one has no Hetzner/bare-metal
section.

### `Components = ["beszel-agent"]` directly, not `[Roles.base]`

`Roles.base` bundles `restic-backup` alongside `beszel-agent`. Backups
aren't in scope here (`krytis-build` isn't a data host — its persistent
state is the GitHub Actions runner registration and BuildStream's local
CAS, neither of which restic-backup's generic
`/var/lib/materia/components` + `/var/lib/containers/storage/volumes`
target paths would meaningfully cover, and it's not asked for). Assign
the single component explicitly on the host entry, same style as `bow`'s
`Components = ["music", "grimmory", ...]` list.

### Sequencing: land the host + component code before wiring `Components`

This repo's own documented incident (AGENTS.md, the `baseDomain`/
`beszel-agent` "map has no entry for key" gotcha): landing a component
reference in `MANIFEST.toml` before its attributes exist makes the *next*
`materia-update` on that host fail fatally, aborting reconciliation of
**every** component on the host, not just the new one. `krytis-build` has
no other components today so the blast radius is smaller (nothing else to
break), but the same sequencing concern shaped the plan of record below.

In practice the two steps collapsed into one PR: the user minted the
beszel-hub TOKEN/KEY and added them to the "Krytis Build VPS" Proton Pass
item's Beszel section *before* this PR was implemented, so
`attributes/krytis-build.yml` could be created with real values and
`Components` set to `["beszel-agent"]` in the same change — no
intermediate `Components = []` state was ever committed. The sequencing
constraint still applies for any *future* component added to this host
(or any other): land the attributes first, wire `Components` second.

## Files to create / modify

### 1. `.mise/tasks/server/new` — add `--type adopted`

```diff
 #USAGE flag "--type <type>" help="Provisioning type" {
-#USAGE   choices "hetzner" "bare-metal"
+#USAGE   choices "hetzner" "bare-metal" "adopted"
 #USAGE }
```

New case in the `case "$_type"` validation block and the `server.toml`
heredoc switch:

```toml
# Server config for "${_server_name}", read by `mise server:adopt-render`.
# Committed — non-secret.
#
# type = "adopted": an already-running, non-Flatcar host that never went
# through Ignition. materia's daemon (podman quadlet + timer) is installed
# by hand via `mise server:adopt-render` + manual scp/SSH instead of being
# baked in at first boot. See specs/plans/issue-99-krytis-build-beszel.md.

type = "adopted"
```

"Next steps" output for `adopted` prints `mise server:adopt-render
--server-name ${_server_name}` instead of the `ign`/`hz:*`/`ipxe:*`
sequence.

### 2. `.mise/tasks/server/adopt-render` (new)

```sh
#!/usr/bin/env bash
#MISE description="Render materia's daemon install files for an already-running (non-Ignition) host"

#USAGE flag "--server-name <name>" help="Server name (must have provisioning/servers/<name>/server.toml with type = \"adopted\")"

set -euo pipefail

_server_name="${usage_server_name:?server name required, use --server-name}"
_server_toml="provisioning/servers/${_server_name}/server.toml"

[[ -f "$_server_toml" ]] || { echo "error: $_server_toml not found — run: mise server:new --server-name ${_server_name} --type adopted" >&2; exit 1; }

_type=$(yq -o=json -p=toml "$_server_toml" | jq -r '.type // empty')
[[ "$_type" == "adopted" ]] || { echo "error: $_server_toml has type=\"${_type}\", expected \"adopted\" — use 'mise ign' for hetzner/bare-metal hosts" >&2; exit 1; }

REPO_URL=$(git remote get-url origin)
_out="provisioning/servers/${_server_name}/bootstrap"
mkdir -p "$_out"

fnox get AGE_SECRET_KEY > "$_out/key.txt"
chmod 600 "$_out/key.txt"
_hc_ping_url=$(fnox get HC_PING_URL)

cat > "$_out/config.toml" <<EOF
[source]
kind = "git"
url = "${REPO_URL}"

attributes = "sops"

[sops]
base_dir = "attributes"
EOF

cat > "$_out/materia-update.container" <<EOF
[Unit]
Description=Materia: quadlet manager
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStartPre=-/usr/bin/curl -fsS -m 10 --retry 5 -o /dev/null ${_hc_ping_url}/materia-update-${_server_name}/start
ExecStopPost=-/usr/bin/bash -c 'url="${_hc_ping_url}/materia-update-${_server_name}"; [ "\$EXIT_STATUS" = "0" ] || url="\$url/fail"; curl -fsS -m 10 --retry 5 -o /dev/null "\$url"'

[Container]
Image=ghcr.io/stryan/materia:stable
ContainerName=materia
Exec=update

Environment=MATERIA_SOURCE__KIND="git"
Environment=MATERIA_SOURCE__URL=${REPO_URL}
Environment=MATERIA_ATTRIBUTES="sops"
Environment=MATERIA_SOPS__BASE_DIR="attributes"
Environment=SOPS_AGE_KEY_FILE=/etc/materia/key.txt

SecurityLabelDisable=true
HostName=${_server_name}
Network=host

Volume=/etc/materia:/etc/materia
Volume=/run/dbus/system_bus_socket:/run/dbus/system_bus_socket
Volume=/run/podman/podman.sock:/run/podman/podman.sock
Volume=/var/lib/materia:/var/lib/materia
Volume=/etc/containers/systemd:/etc/containers/systemd
Volume=/usr/local/bin:/usr/local/bin
Volume=/etc/systemd/system:/etc/systemd/system
EOF

cat > "$_out/materia-update.timer" <<EOF
[Unit]
Description=Materia daily update

[Timer]
OnBootSec=2min
OnCalendar=*-*-* 05:00:00
Unit=materia-update.service

[Install]
WantedBy=timers.target
EOF

echo "wrote ${_out}/{config.toml,key.txt,materia-update.container,materia-update.timer}"
echo "SECRET: key.txt — deliver over SSH, do NOT commit (gitignored already)."
echo ""
echo "Install on ${_server_name} (over SSH):"
echo "  ssh <host> 'sudo mkdir -p /etc/materia'"
echo "  scp ${_out}/config.toml <host>:/tmp/ && ssh <host> 'sudo mv /tmp/config.toml /etc/materia/config.toml'"
echo "  scp ${_out}/key.txt <host>:/tmp/ && ssh <host> 'sudo mv /tmp/key.txt /etc/materia/key.txt && sudo chmod 600 /etc/materia/key.txt'"
echo "  scp ${_out}/materia-update.container <host>:/tmp/ && ssh <host> 'sudo mv /tmp/materia-update.container /etc/containers/systemd/materia-update.container'"
echo "  scp ${_out}/materia-update.timer <host>:/tmp/ && ssh <host> 'sudo mv /tmp/materia-update.timer /etc/systemd/system/materia-update.timer'"
echo "  ssh <host> 'sudo systemctl daemon-reload && sudo systemctl enable --now materia-update.timer && sudo systemctl start materia-update.service'"
echo "  ssh <host> 'sudo journalctl -u materia-update.service -n 50 --no-pager'   # confirm it converged"
```

The rendered `materia-update.container` is byte-identical in shape to the
one `hetzner.bu` writes (same env vars, same volumes) — only the
`HostName=`/`SERVER_NAME` substitution differs, and there's no
`SecurityLabelDisable=true` behavior change. `HC_PING_URL`'s dead-man's-
switch slug becomes `materia-update-krytis-build`, distinct from `bow`'s and
`flutterina`'s (healthchecks.io project already supports arbitrary slugs
in slug mode — no new setup needed there).

### 3. `.gitignore` — ignore the new render output

```diff
 # Rendered Ignition — secret (contains baked keys), never commit.
 *.ign
+
+# Rendered adopted-host bootstrap files (contains the age private key).
+provisioning/servers/*/bootstrap/
```

### 4. `MANIFEST.toml` — host entry, empty `Components` for now

```diff
 [Hosts.bow]
 Components = ["music", "grimmory", "audiobookshelf", "jellyfin", "buildbarn", "mediamanager"]
 Roles = ["base", "tunneled"]
+
+[Hosts.krytis-build]
+Components = []
```

`Components` flips to `["beszel-agent"]` in the follow-up commit once
`attributes/krytis-build.yml` is populated (see Sequencing above). No
`Roles` — deliberately outside `base`/`tunneled` (no restic-backup, no
Newt tunnel; this host isn't reachable through Pangolin and doesn't need
to be — the beszel-agent only needs outbound connectivity to
`beszel.ririi.dev`, same as any other WebSocket client).

### 5. `provisioning/servers/krytis-build/server.toml` (new)

```toml
# Server config for "krytis-build", read by `mise server:adopt-render`.
# Committed — non-secret.
#
# type = "adopted": an already-running, non-Flatcar host that never went
# through Ignition. materia's daemon (podman quadlet + timer) is installed
# by hand via `mise server:adopt-render` + manual scp/SSH instead of being
# baked in at first boot. See specs/plans/issue-99-krytis-build-beszel.md.
#
# This is the krytis repo's self-hosted GitHub Actions runner VPS
# (Contabo, Debian 13/trixie) — not the same machine as `bow`. Provisioned
# and owned by krytis's own `mise runner-vps:*` tasks; materia only
# manages the one component assigned to it here.

type = "adopted"
```

### 6. `AGENTS.md` — Gotchas entry

Document the adoption path so the next non-Flatcar host doesn't
re-derive it from scratch:

> **Adopting an already-running host (no Ignition).** materia's daemon
> is just a podman quadlet + systemd timer — nothing about it requires
> Flatcar/Ignition, only podman + systemd + the same four files Ignition
> would otherwise write. `server:new --type adopted` +
> `server:adopt-render` render them locally for manual `scp`+SSH install
> instead of baking them into a first-boot Ignition config. Used for
> `krytis-build` (issue #99) — a pre-existing, already-in-service host
> (krytis's self-hosted CI runner) that can never be wiped and
> reprovisioned the way `bow`/`flutterina` were. Sequencing still
> matters: land the host + `Components = []` first, populate
> `attributes/<name>.yml`, *then* wire the real `Components` list — same
> "map has no entry for key" fatal-abort risk as any other new
> component, see the `baseDomain`/`beszel-agent` gotcha above.

## Deployment steps (out of IaC scope, tracked in the issue)

1. ~~User creates the beszel-hub "Add System" entry for `krytis-build`
   at `https://beszel.ririi.dev` → gets TOKEN + KEY.~~ Done — landed in
   the "Krytis Build VPS" Proton Pass item's Beszel section before this
   PR was implemented.
2. ~~`sops attributes/krytis-build.yml`, set `beszelKey`/
   `beszelToken`.~~ Done in this PR (`beszelHubUrl` was already a
   `globals` attribute — `beszel-hub`/`beszel-agent` on `bow`/`flutterina`
   already depend on it, confirmed present).
3. ~~Flip `[Hosts.krytis-build] Components = ["beszel-agent"]`.~~ Done in
   this PR.
4. `mise server:adopt-render --server-name krytis-build` — done in this
   PR's working tree; rendered files live at
   `provisioning/servers/krytis-build/bootstrap/` (gitignored, not part
   of the PR diff).
5. **Remaining:** run the printed `scp`/`ssh` sequence against
   `krytis-build` (FIDO2 key required — this agent cannot do this step;
   the user runs it after merge).
6. **Remaining:** verify:
   ```
   ssh <host> 'sudo systemctl status materia-update.timer materia-update.service'
   ssh <host> 'sudo podman ps'   # beszel-agent container running
   ```
   and confirm the new system shows up green in the beszel-hub dashboard.


## Out of scope

- Bringing any other component onto `krytis-build` — this issue is
  beszel-agent only.
- A fully declarative "adopt" flow (e.g. a first-boot-equivalent
  self-installing unit) — `server:adopt-render` + manual scp/SSH is a
  one-time bootstrap for a single host; revisit if a second adopted host
  makes the manual step worth automating further.
- Changing how `bow`/`flutterina` are provisioned — Ignition/Butane stays
  the default path for any *new* Hetzner/bare-metal host.
