# Materia Podman Orchestration Repository

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
mise.toml                    # pinned toolchain (age, sops)
.sops.yaml                   # SOPS creation rules (age recipient)
renovate.json5               # Renovate config (image + plugin updates)
```

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

`attributes/vault.yml` is a SOPS-encrypted vault (age backend). Non-secret
values (domain, email) are visible in git; secret values (serverSecret,
cfDnsApiToken) are ciphertext. Edit with `sops edit attributes/vault.yml`.
For host-specific overrides, create `attributes/<hostname>.yml` (also
SOPS-encrypted). The age private key is baked into Ignition and lives at
`/etc/materia/key.txt` on the target host.

## Running

```sh
mise install                   # installs age + sops

export MATERIA_SOURCE__KIND=git
export MATERIA_SOURCE__URL=https://github.com/owner/materia
export MATERIA_ATTRIBUTES=sops
export MATERIA_SOPS__BASE_DIR=attributes

materia plan     # dry-run — validate repo + attributes
materia update   # apply
```
