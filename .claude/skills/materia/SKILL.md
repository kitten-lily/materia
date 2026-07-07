---
name: materia
description: Use when authoring or modifying Materia repository resources — components, quadlets, manifests, attributes, templates, or secrets. Covers resource types, Go template macros, manifest fields, podman secret handling, and the plan/update workflow.
user-invocable: true
---

# Materia Repository Authoring Guide

## Core concepts

- **Repository** = git repo with `MANIFEST.toml`, `components/`, `attributes/`.
- **Component** = directory under `components/` (a service + its resources).
- **Resource** = a file in a component, installed to the host on `materia update`.
- **Attribute** = a template variable, stored in vault files under `attributes/`.

## Resource kinds

| Extension(s) | Kind | Install location |
|---|---|---|
| `.container`, `.network`, `.volume`, `.pod`, `.kube`, `.build`, `.image` | Quadlet | `/etc/containers/systemd/<component>/` |
| `.service`, `.timer`, `.socket`, `.path`, `.mount`, etc. | Systemd unit | `/etc/systemd/system/` + data dir |
| `.sh` (or in manifest `Scripts`) | Script | `/usr/local/bin/` + data dir |
| everything else | File (data) | `/var/lib/materia/components/<component>/` |
| `MANIFEST.toml` | Manifest | data dir (not templated outside `Scripts`) |

Resources ending in `.gotmpl` are templated with Go templates. The `.gotmpl`
suffix is stripped from the installed filename (only the last one).

## Templating

Use `{{ .attributeName }}` for attribute values.

### Macros

| Macro | Description |
|---|---|
| `{{ m_dataDir "component" }}` | Data dir: `/var/lib/materia/components/<component>` |
| `{{ m_quadletDir "component" }}` | Quadlet dir on host |
| `{{ m_scriptsDir "component" }}` | Scripts dir on host |
| `{{ m_serviceDir "component" }}` | Systemd dir on host |
| `{{ m_facts "factname" }}` | Host facts (`hostname`, `interface.eth0.ip4.0`, etc.) |
| `{{ m_default "attr" "fallback" }}` | Attribute value or fallback |
| `{{ exists "attr" }}` | True if attribute is defined |
| `{{ secretEnv "attrName" "TARGET" }}` | Podman secret as env var (TARGET optional) |
| `{{ secretMount "attrName" "ARGS" }}` | Podman secret as file mount (ARGS optional) |
| `{{ isRoot }}` | True if materia runs rootful |
| `{{ snippet "name" "arg" }}` | Insert a pre-made text snippet (experimental) |

### Snippets

Built-in snippets include `"autoUpdate"` (with argument `"registry"`).
Custom snippets are experimental — defined in manifests.

## Component manifest (`components/<name>/MANIFEST.toml`)

```toml
[Defaults]
containerTag = "latest"
# Any default attribute values for this component

[Settings]
NoRestart = false      # disable automatic container/pod restarts on update
NoExpansion = false     # disable .quadlets file expansion
# SetupScript = "script.sh"   # EXPERIMENTAL — runs on install
# CleanupScript = "script.sh" # EXPERIMENTAL — runs on removal
# PreScript = "script.sh"     # EXPERIMENTAL — runs before update
# PostScript = "script.sh"    # EXPERIMENTAL — runs after update

[[Services]]
Service = "app.service"
RestartedBy = ["app.container", "config/config.yml"]  # resources that trigger restart
ReloadedBy = ["config/config.toml"]                    # resources that trigger reload
Disabled = false    # don't enable/start this service
Static = false      # true for .timer files (quadlet-generated services)
Stopped = false     # don't start the service
Oneshot = false     # don't check if it stayed running
Timeout = 0         # seconds for service actions

Secrets = ["serverSecret", "cfDnsApiToken"]
# Attributes listed here are created as podman secrets automatically.
# Reference them in templates with secretEnv/secretMount.
```

### Service restart behavior

- `.container` and `.pod` resources restart their service automatically on update
  (unless `NoRestart = true`).
- `RestartedBy` / `ReloadedBy` extend this to data resources — e.g. a config
  file change can trigger a container restart or `systemctl reload`.

## Repository manifest (`MANIFEST.toml`)

```toml
[Hosts.edge]
Components = ["pangolin"]
Roles = ["base"]

[Roles.base]
Components = ["podman-exporter"]

# Per-host overrides (replace entire tables):
[Hosts.edge.Overrides.pangolin.Defaults]
containerTag = "stable"

# Per-host extensions (merge into existing tables):
[[Hosts.edge.Extensions.pangolin.Services]]
Service = "pangolin.timer"

# Remote components:
[Remote.mycomp]
Revision = "v1"       # optional
Subpath = "component"  # optional
[Remote.mycomp.git]
URL = "https://github.com/example/mycomp"
```

## Attributes

### Vault files (file engine — unencrypted TOML)

```
attributes/vault.toml          # global — all hosts, all components
attributes/<hostname>.toml     # host-specific
attributes/<role>.toml         # role-specific
```

### Format

```toml
[globals]
lanDnsServer = "192.168.1.10"

[components.pangolin]
baseDomain = "example.com"
serverSecret = "replace-with-secret"

[hosts.edge]
keyForEdge = "value"

[roles.base]
beszelKey = "ssh-blah"
```

### Engines

- **file** — unencrypted TOML. For testing / non-secret repos.
- **sops** (recommended) — SOPS-encrypted YAML/INI. Recommended for production.
- **age** (recommended) — age-encrypted TOML. Simple, modern.

Configure via `MATERIA_ATTRIBUTES=sops` or `MATERIA_ATTRIBUTES=file`.

## Podman secrets

1. Declare in component manifest: `Secrets = ["serverSecret"]`
2. Set the attribute value in a vault: `serverSecret = "..."` (in `attributes/`)
3. Reference in templates:
   - Env: `{{ secretEnv "serverSecret" "SERVER_SECRET" }}` →
     `Secret=...,type=env,target=SERVER_SECRET` in the rendered quadlet
   - Mount: `{{ secretMount "serverSecret" "/path:ro" }}`
4. Materia creates the podman secret automatically (prefixed `materia-` by
   default).

Secrets are read at container creation time. Rotating requires updating the
attribute (→ materia updates the secret) + restarting the consumer service.

## Running materia

```sh
# Configure source + attributes engine
export MATERIA_SOURCE__KIND=git
export MATERIA_SOURCE__URL=https://github.com/owner/materia
export MATERIA_ATTRIBUTES=file
export MATERIA_FILE__BASE_DIR=attributes

materia plan     # dry-run — validate, show what would change
materia update   # apply changes to the host
```

### Config file alternative

`/etc/materia/config.toml`:
```toml
[source]
kind = "git"
url = "https://github.com/owner/materia"

[attributes]
# engine = "file"  # auto-detected; or force one: "file", "sops", "age"

[file]
base_dir = "attributes"
```

## Common patterns

### Bind-mounting config files into containers

```ini
# In a .container.gotmpl file:
Volume={{ m_dataDir "pangolin" }}/config:/app/config:z
```

Materia installs `config/config.yml.gotmpl` to
`/var/lib/materia/components/pangolin/config/config.yml` (templated), and the
container bind-mounts that directory.

### Conditional resources

```gotmpl
{{- if ( exists "localWeb" )}}
Volume={{ .localWeb }}:/srv/www:Z
{{- end }}
```

### Named volume

```ini
# letsencrypt.volume
[Volume]
```
```gotmpl
# In traefik.container.gotmpl:
Volume=letsencrypt.volume:/letsencrypt:z
```

### Host-specific attributes

Create `attributes/edge.toml`:
```toml
[components.pangolin]
baseDomain = "realdomain.com"
```
This overrides `vault.toml` values for the `edge` host only.

## Default install locations (rootful)

| What | Path |
|---|---|
| Materia data root | `/var/lib/materia` |
| Source repo cache | `/var/lib/materia/source` |
| Component data | `/var/lib/materia/components/<name>/` |
| Quadlets | `/etc/containers/systemd/<name>/` |
| Systemd units | `/etc/systemd/system/` |
| Scripts | `/usr/local/bin/` |
| Config | `/etc/materia/config.toml` |
