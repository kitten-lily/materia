# Materia Podman Orchestration Repository

![materia](https://healthchecks.io/badge/275e26c5-7cfd-482b-ad60-1c459f/wAZlLEmn/materia.svg) ![backup](https://healthchecks.io/badge/275e26c5-7cfd-482b-ad60-1c459f/oGzwBG-c/backup.svg)

GitOps source of truth for Podman-hosted services, managed by
[Materia](https://primamateria.systems/). See `AGENTS.md` for the full design,
conventions, and gotchas. See `.claude/skills/materia/SKILL.md` for a
materia-specific authoring guide.

## Design in one line

Materia pulls this repo on each target host, templates resources with Go
templates + attributes, installs quadlets/configs to the right directories, and
restarts affected services — no hand-rolled reconciler, no webhook, no
seed-secrets service.

## Layout

```
MANIFEST.toml                # repository manifest — host → component assignments
attributes/
  vault.yml                  # global attributes (SOPS-encrypted, age backend)
components/
  pangolin/                  # Pangolin edge node component
    MANIFEST.toml            # component manifest — defaults, services, secrets
    pangolin.pod              # podman pod (shared network namespace)
    letsencrypt.volume        # named volume for ACME certs
    app.container.gotmpl     # Pangolin app
    gerbil.container.gotmpl  # Gerbil (WireGuard tunnel manager)
    traefik.container.gotmpl # Traefik reverse proxy
    config/
      config.yml.gotmpl          # Pangolin config (non-secret, templated)
      privateConfig.yml.gotmpl   # Pangolin private config (branding, templated)
    traefik/
      traefik_config.yml.gotmpl  # static Traefik config (templated)
      dynamic_config.yml.gotmpl  # dynamic Traefik config (templated)
mise.toml                    # pinned toolchain (age, sops, fnox, hcloud, butane, yq)
fnox.toml                    # fnox secret injection (Proton Pass provider)
.sops.yaml                   # SOPS creation rules (age recipient)
renovate.json5               # Renovate config (image + plugin updates)
provisioning/
  templates/
    hetzner.bu                # Butane template — any Hetzner Cloud server
    bare-metal.bu              # Butane template — any bare-metal server
    bare-metal-debug.bu        # minimal RAM-boot discovery-only variant
  servers/
    flutterina/
      server.toml              # per-server config (type, hetzner/bare_metal settings)
      materia.ign               # gitignored, rendered by `mise ign`
  ghostty.terminfo.b64       # pre-compiled Ghostty terminfo (base64)
  BARE-METAL.md              # bare-metal bring-up runbook
.mise/tasks/                 # mise file tasks (ign, server/new, hz/*, ipxe/*, clean)
```

Server identity is unified: one name is the Hetzner Cloud server name, the
OS hostname, the `MANIFEST.toml` `Hosts.<name>` key, and the
`provisioning/servers/<name>/` directory. No global server-name env var —
every server-scoped task takes `--server-name` explicitly. Add a server with
`mise server:new --server-name <name> --type hetzner|bare-metal`.

## How it works

1. Materia syncs this repo to the target host.
2. For each component assigned to the host, it templates `.gotmpl` resources
   using attributes from `attributes/vault.yml` (and host-specific vaults).
3. Quadlet files (`.container`, `.network`, `.volume`) go to
   `/etc/containers/systemd/pangolin/`.
4. Data files (configs) go to `/var/lib/materia/components/pangolin/`.
5. Podman secrets declared in `MANIFEST.toml` (`Secrets = [...]`) are created
   automatically; referenced in templates via `{{ secretEnv "attrName" }}`.
6. Materia restarts services whose resources changed (per `RestartedBy` in the
   component manifest).

## Why a pod?

All three containers share one network namespace (a podman pod). This is
architecturally required: Gerbil creates WireGuard tunnel interfaces in the
shared namespace, and Traefik must reach the tunnel endpoint IPs
(100.89.137.0/20 CGNAT range) to proxy traffic to tunneled resources. With
separate containers on a network, those IPs would be unreachable from Traefik.

## Attributes

`attributes/vault.yml` is a SOPS-encrypted vault (age backend). All values
are encrypted by default (keys/structure visible, values ciphertext). Edit
with `sops edit attributes/vault.yml`.
For host-specific overrides, create `attributes/<hostname>.yml` (also
SOPS-encrypted). The age private key is baked into Ignition and lives at
`/etc/materia/key.txt` on the target host.

## Provisioning

```sh
mise install                                       # installs age, sops, fnox, hcloud, butane, yq, etc.
mise ign --server-name flutterina                   # render Ignition (fetches secrets from Proton Pass via fnox)
mise hz:upload-image                                # one-time Flatcar snapshot upload to Hetzner
mise hz:create --server-name flutterina             # provision server (Ignition passed as user_data)
```

To add a new server: `mise server:new --server-name <name> --type
hetzner|bare-metal`, then follow the printed next steps (or see
`provisioning/BARE-METAL.md` for the bare-metal/iPXE flow).

To preserve pangolin state across a rebuild:

```sh
mise hz:pull-config --server-name flutterina        # backup runtime volumes to ./pangolin-backup.tar.gz
mise hz:rebuild --server-name flutterina --confirm  # rebuild server from latest snapshot + Ignition
mise hz:push-config --server-name flutterina        # restore the backup into the fresh server's volumes
```

Override Hetzner instance type/location with task flags or in
`provisioning/servers/<name>/server.toml`. See `mise tasks` for all
available tasks.
