# BUG-007 — badger v1.6.x/v1.7.0 fails Traefik's plugin-catalog integrity check: every hostname 404s

**status:** fixed
**found:** 2026-08-25, reported as "all endpoints including
pangolin.<baseDomain> return 404"
**severity:** P0 (total edge outage — every public resource on flutterina,
the Pangolin dashboard itself, and Newt's token exchange)
**epic:** standalone (pangolin component, Renovate PR #52)

## Symptom

Every hostname behind the edge returned `404 page not found`, including
`pangolin.<baseDomain>` (the dashboard). All three pod services were
`active (running)`; the app was healthy and serving (`Updated exit node
reachableAt`, site endpoint churn in its log). No failed units.

`journalctl -u traefik.service` had the cause, once per router:

```
ERR Plugins are disabled because an error has occurred. error="unable to set up plugins environment: unable to install plugin badger: unable to check archive integrity of the plugin github.com/fosrl/badger: plugin integrity check failed" plugins=["badger"]
ERR error="invalid middleware \"badger@file\" configuration: invalid middleware type or middleware does not exist" entryPointName=websecure routerName=next-router@file
ERR error="invalid middleware \"badger@http\" configuration: invalid middleware type or middleware does not exist" entryPointName=websecure routerName=8-Jellyfin-router@http
```

Every router in this repo's `dynamic_config.yml` **and** every router
Pangolin generates through the HTTP provider references the `badger`
middleware, so a failed plugin load drops 100% of routes. With no router
matching, Traefik's default response is a bare 404 — which looks like a
routing/DNS problem, not a plugin problem.

## Root cause

Traefik verifies a remote plugin by asking the plugin catalog to validate
it (`pkg/plugins/downloader.go`, `RegistryDownloader.Check`, traefik
v3.7.11):

```go
endpoint, err := d.baseURL.Parse(path.Join(d.baseURL.Path, "validate", pName, pVersion))
...
req.Header.Set(hashHeader, hash)   // X-Plugin-Hash: sha256 hex of the zip
...
if resp.StatusCode == http.StatusOK { return nil }
return errors.New("plugin integrity check failed")
```

with `pluginsURL = "https://plugins.traefik.io/public/"` (`manager.go`).
Anything other than HTTP 200 fails, and `SetupRemotePlugins` then disables
**all** plugins, not just the failing one.

Measured directly:

| version | `GET /public/validate/github.com/fosrl/badger/<v>` |
|---|---|
| v1.5.0 | 200 |
| v1.6.0 | 404 |
| v1.6.1 | 404 |
| v1.7.0 | 404 |

The archive itself is fine and unrelated to the failure: the download
endpoint still serves a byte-identical, valid zip
(`sha256 33bcd3d7…9e8` for v1.6.1) from both this workstation and
flutterina, and `unzip -t` passes. The catalog just has no valid record
for those tags — `v9.9.9` returns the same 404, and the endpoint ignores
the `X-Plugin-Hash` header entirely for a plugin it *does* know
(`plugindemo` returns 200 with a deliberately wrong hash). So this is
catalog-side and version-scoped, not a hash mismatch, not a corrupt
download, not a CDN edge, not our network.

Upstream has the same finding: fosrl/badger#31 (Pangolin maintainer:
"We must have previously accidentally tagged a version v1.6.0 that the
Traefik plugin catalog indexed without us knowing… Please keep using
v1.5.0 in the meantime"), tracked at traefik/piceus#156 and on the
Traefik community forum. Re-releasing as v1.6.1 did not clear it, and
v1.7.0 inherits the same rejection.

Our trigger: Renovate PR #52 (`ad538a3`, 2026-08-24) bumped
`badgerVersion = "v1.5.0"` → `"v1.6.1"` in
`components/pangolin/MANIFEST.toml` as part of the grouped "pangolin
stack" update. The value is templated into `traefik_config.yml`, so
materia rewrote the config and restarted `traefik.service` — the restart
is what surfaced it (the previously running process had loaded v1.5.0
before the bump and kept serving). Nothing about the bump was visible as
a failure: materia's run was green, all units stayed `active (running)`.

v1.6.0+ is only needed for Pangolin >= 1.22's new public-resource type.
This host runs `ee-1.21.1`, so v1.5.0 is not a downgrade in
functionality.

## Fix

1. `components/pangolin/MANIFEST.toml`: `badgerVersion = "v1.5.0"`, with
   the reason inline.
2. `renovate.json5`: `matchPackageNames: ["fosrl/badger"]` +
   `allowedVersions: "<=1.5.0"` so the grouped pangolin-stack update
   can't re-raise it. Lift only when the catalog returns 200 for the
   target version.
3. `.github/workflows/preflight.yml`: new `badger-plugin-catalog` job
   reads the pinned version out of the manifest and fails the PR if
   `GET plugins.traefik.io/public/validate/github.com/fosrl/badger/<v>`
   isn't 200 (unreachable catalog → warn + skip, so an outage at
   Traefik Labs doesn't wedge CI). This would have failed PR #52.

Verified before deploying, by running the real image locally with our
plugin config and a tmpfs `/plugins-storage`
(`podman run --tmpfs /plugins-storage reg.mini.dev/traefik:v3.7.11`):
v1.7.0 and v1.6.1 both reproduced the exact production error, v1.5.0
logged `Plugins loaded. plugins=["badger"]`.

Deployed with `systemctl restart materia-update.service` on flutterina —
plan was `Update File traefik/traefik_config.yml` → `Restart Service
traefik.service`. After it:

```
INF Loading plugins... plugins=["badger"]
INF Plugins loaded. plugins=["badger"]
```

zero `invalid middleware` lines, and `https://pangolin.<baseDomain>/` →
200, `https://beszel.<baseDomain>/` → 200,
`https://jellyfin.<baseDomain>/` → 302 to `/web/`.

## Follow-up

- Watch fosrl/badger#31 / traefik/piceus#156. When the catalog accepts a
  newer tag, raise the Renovate `allowedVersions` ceiling; the preflight
  job then proves the new pin before it can reach a host.
- Pangolin >= 1.22 will *require* badger >= v1.6.0. If the catalog is
  still broken by then, the escape hatch is Traefik's
  `experimental.localPlugins` (source tree at
  `/plugins-local/src/github.com/fosrl/badger`, no catalog contact at
  all). badger's `go.mod` has zero external dependencies, so vendoring
  is 4 Go files plus `.traefik.yml` — cheap if it becomes necessary, but
  it trades a version pin for vendored third-party source, so not done
  pre-emptively.
