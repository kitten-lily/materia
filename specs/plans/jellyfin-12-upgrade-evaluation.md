# Jellyfin 10.11.11 → 12.x upgrade evaluation

Status: EVALUATED, NOT EXECUTED (2026-09-27)
Component: `components/jellyfin/` (host `bow`)
Related: #47 (HW transcoding), #113 (healthcheck coverage)

## Verdict

**Upgrade — to `12.1`, not `12.0`, and not as a Renovate-style digest bump.**

It is a one-way database migration behind a manual cold backup. Every
blocker found is clearable; nothing in the component's shape has to
change (same `/config`, `/cache`, `8096`, same `JELLYFIN_` env
contract). Two things make it *not* a routine bump: the migration
cannot be rolled back without restoring `/config`, and the required
post-upgrade full library scan is long (23,311 `BaseItems` on bow).

`12.1` over `12.0`: 12.1 (2026-09-15, one week after 12.0) carries the
two migration-path fixes — *"Fix database optimization memory use and
pre-migration backup integrity"* (PR #17836) and *"Clean up invalid
data before running migrations"* (PR #17835) — i.e. fixes to the exact
code path this upgrade is risky for. There is no reason to run 12.0's
migration when 12.1's is the one that got patched.

## Evidence

### Upstream (jellyfin.org/posts/jellyfin-release-12.0, GitHub releases)

- Version scheme changed: the leading `10.` was dropped. `10.11.x` →
  `12.0` → `12.1`. The server reports `12.0.0`/`12.1.x`. There is no
  `10.12`.
- Stable tags: `v12.0` 2026-09-08, `v12.1` 2026-09-15.
- Upgrade from any `10.11.x` is supported directly; **no intermediate
  step**.
- DB schema is rewritten on first boot. *"a backup is the only way back
  to your previous version."* Optional deliberate run:
  `--mode MigrateSystem` (migrates, then exits).
- **Full library scan REQUIRED after upgrade** — auto-resolved
  alternate versions are cleared by the migration and rebuilt from
  disk. First scan is much slower than normal; some movies reappear as
  "newly added".
- Third-party plugins built for 10.11 will not load (server targets
  .NET 10, plugin interfaces changed). Remove before upgrading.
- Legacy `/emby/` + `/mediabrowser/` routes removed; deprecated
  auth mechanism disabled, including on existing servers.
- Usernames are now case-insensitive; two accounts differing only by
  case **fail the migration**.
- Modern web layout becomes the default (Legacy still selectable); TV
  layout unchanged. Hard-refresh browsers after upgrade.
- FFmpeg 8.1; subtitle writing moved to SubtitleEdit; `.ogg` reclassified
  as audio; subtitle settings moved from server-wide to per-library.
- Contains security fixes (path traversal, setup-wizard re-run, plugin
  package names, XSS in web).

### Live state on `bow` (2026-09-27, via SSH)

| Fact | Value |
|---|---|
| Running | `Jellyfin.Server 10.11.11.0`, `Up 12 days (healthy)` |
| Users | exactly one (`lily`) → **no case-collision blocker** |
| Library size | 23,311 rows in `BaseItems` |
| Config volume | `systemd-jellyfin-config` = 3.4G (`metadata` 3.1G, `data` 328M, `plugins` 1.5M); `data/jellyfin.db` = 95 MB |
| Installed plugins | `Intro Skipper 1.10.11.24`, `TMDb Box Sets 13.0.0.0`, `TheTVDB 22.0.0.0` — all three are 10.11-ABI builds |
| Disk | `/` 811G free (config volume lives here); `/var/lib/materia-data` 96% used, 229G free |
| `/dev/dri` | present (`card0`, `renderD128`); SELinux **Permissive** |
| Backups | `restic-backup.service` last ran 2026-09-27 00:00:25, `status=0/SUCCESS`; timer next 2026-09-28 00:00 (BUG-004 trigger workaround is holding) |

### Plugin readiness (repo.jellyfin.org manifest + upstream releases)

| Plugin | Installed | 12.x build | `targetAbi` |
|---|---|---|---|
| TheTVDB | v22 | **v24** (2026-09-09) | `12.0.0.0` |
| TMDb Box Sets | v13 | **v15** (2026-09-15) | `12.1.0.0` |
| Intro Skipper | v1.10.11.24 | **v12.0.4.0** (2026-09-11, branch `12.0`) | "Jellyfin 12.0.0 or newer"; its manifest URL serves per-server-version builds |

All three have shipped 12.x-compatible builds. No plugin is stranded.

### Component-shape check (`skopeo inspect --config` on `:12.1` vs `:10.11.11`)

Unchanged and therefore **no quadlet restructuring needed**:
`ExposedPorts 8096/tcp`, `JELLYFIN_DATA_DIR=/config`,
`JELLYFIN_CACHE_DIR=/cache`, `JELLYFIN_CONFIG_DIR=/config/config`,
`JELLYFIN_FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg`, entrypoint
`/jellyfin/jellyfin`. `Jellyfin.Server/Program.cs` still does
`.AddEnvironmentVariables("JELLYFIN_")` at v12.1 (line 388), so
`JELLYFIN_PublishedServerUrl` keeps working.

## Blocker found in *this repo*: Renovate can never offer 12.x

`components/jellyfin/jellyfin.container.gotmpl` pins a **three-part**
tag (`10.11.11`). Jellyfin publishes only `12`, `12.1`, and dated
`12.1.20260915-010956` tags — no three-part `12.x.y`. Renovate's
`docker` versioning is precision-matching by design ("a user on `12.14`
expects to be upgraded to `12.15` and not `12.15.0`" —
docs.renovatebot.com/modules/versioning/docker), so no candidate tag is
ever considered. Confirmed empirically: dependency dashboard (#6) lists
`docker.io/jellyfin/jellyfin 10.11.11@sha256:aefb67e6…` with **no
available update**, 19 days after 12.0 shipped, and the pinned digest
is still current for the `10.11.11` tag — so even the digest watch is
silent.

Consequence beyond this upgrade: jellyfin is the one image in the fleet
that silently stopped receiving *any* Renovate PR, including the
security fixes 12.0 ships. This must be fixed in the same change, or
the pin goes stale again after 12.1.

**Fix:** a `packageRules` entry giving jellyfin a tolerant versioning
scheme, e.g.

```json5
{
  matchPackageNames: ["docker.io/jellyfin/jellyfin"],
  versioning: "regex:^(?<major>\\d+)\\.(?<minor>\\d+)(\\.(?<patch>\\d+))?$",
}
```

which matches both `10.11.11` and `12.1` while excluding the rolling
`12`/`latest` tags and the dated `unstable`/`2026092110` builds that a
plain `loose` versioning would happily propose as enormous "major"
upgrades. Verify with a Renovate lookup dry run before landing, not by
reading the regex.

## Risks

1. **Irreversible migration.** Rollback = stop, restore `/config` from
   a cold copy, revert the pin. restic's nightly is a *hot* copy of a
   live SQLite DB — adequate as a second line, not as the primary
   rollback artifact. Take the cold copy.
2. **Long post-upgrade scan.** 23k items, 5.0T of media on a 96%-full
   disk. Expect hours of scanning with degraded browse performance, and
   do not stop the server mid-migration.
3. **Client breakage.** Access is tunnel-only (no `PublishPort`) and
   fronted by Pangolin SSO, so browser clients dominate; any native
   app still using the deprecated auth or `/emby/` routes breaks.
   Enumerate the devices in use before scheduling.
4. **Metadata/artwork churn.** Artwork is no longer upscaled, sorting
   changes, subtitle settings move per-library — cosmetic but visible.
5. **Transcoding regression surface.** FFmpeg 8.1 replaces the 10.11
   build. #47 (HW transcode unverified) is *not* fixed by this upgrade;
   `/dev/dri` is present and SELinux is Permissive on bow, so the
   passthrough itself is not blocked — the remaining question is
   jellyfin's own transcoding settings, re-checkable after the upgrade.

## Execution plan (when scheduled)

1. Remove the three plugins in the jellyfin dashboard (or move
   `/config/plugins` aside), restart, confirm the server still starts.
2. Cold backup: `systemctl stop jellyfin.service`, then
   `tar -C /var/lib/containers/storage/volumes/systemd-jellyfin-config
   -czf /var/tmp/jellyfin-config-pre12-$(date +%F).tgz _data`
   (`/` has 811G free; the volume is 3.4G). Keep until the upgrade is
   signed off.
   Verify: `tar -tzf … | head` and a size check.
3. Repo change (one commit): pin
   `docker.io/jellyfin/jellyfin:12.1@sha256:78d3ea1207d1322471fcac39a614f004f2ccf7e878f95ab2977d752f07e4dd7e`
   (multi-arch index digest, `12.1.20260915-010956`). Second commit:
   the `renovate.json5` versioning rule above.
4. Let materia reconcile (or `materia-update` manually). Watch
   `journalctl -u jellyfin.service -f` through the migrations — do not
   interrupt.
   Verify: `podman exec jellyfin /jellyfin/jellyfin --version` reports
   `12.1.*`; container reaches `(healthy)`.
5. Trigger a **full library scan**; wait for completion.
6. Re-add plugins at their 12.x builds (TheTVDB v24, TMDb Box Sets v15,
   Intro Skipper from its version-aware manifest).
7. Hard-refresh the browser; smoke `https://jellyfin.<baseDomain>/`
   (expect the Pangolin SSO 302, then the Modern layout), play one
   movie and one episode, one transcode.
8. Re-check #47 with FFmpeg 8.1 in place; close or update with findings.
9. Delete the pre-upgrade tarball only after a clean day of use.

## Rollback

`systemctl stop jellyfin.service` → wipe `_data` in
`systemd-jellyfin-config` → untar the pre-upgrade tarball → revert the
pin commit → `materia-update`. The 12.x DB cannot be downgraded in
place; nothing short of the restore works.
