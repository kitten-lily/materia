# Implementation Plan — Add pinepods component (podcast server) on bow

**issue:** https://github.com/kitten-lily/materia/issues/196
**risk:** P2. It is a new component on `bow` that **replaces
audiobookshelf's podcast role** and takes over its `Podcasts` directory. A bad first deploy
still fails `materia-update` for the **whole host** (BUG-010 class), so every
step that needs host-side state happens *before* the commit that needs it.
**epic:** standalone

## Summary

Add a `pinepods` component running
[PinePods](https://github.com/madeofpendletonwool/PinePods) 0.9.2, a Rust
podcast manager with a web UI, native apps, and a built-in gPodder-compatible
sync API. It runs on `bow` and is exposed at `pinepods.<baseDomain>` through the
current T2 path: Pangolin on flutterina → tailnet → `tailscale-gateway` serve
forward → `pinepods:8040` on `newt-net`.

**Decision (2026-11-18): PinePods replaces audiobookshelf for podcasts.**
Audiobookshelf keeps audiobooks only. Subscriptions move across as OPML.
abs's podcast library is deleted first, and its `Podcasts` mount is dropped
before PinePods takes the directory over (see "Cutover sequence").

Three containers, all standalone on `newt-net`, no pod. This follows the
`mediamanager` and `grimmory` pattern:

| Container | Image | Role |
|---|---|---|
| `pinepods` | `docker.io/madeofpendletonwool/pinepods:0.9.2@sha256:a0463a3a…` | app (nginx + Rust API under horust), port 8040 |
| `pinepods-postgres` | `docker.io/library/postgres:18.7@sha256:2ea8630d…` (same pin as mediamanager) | database |
| `pinepods-valkey` | `docker.io/valkey/valkey:8.1.9-alpine@sha256:4934d214…` | required cache/queue |

Digests were checked on 2026-11-18 with `skopeo inspect --raw | sha256sum`.
These are multi-arch index digests, the same form Renovate pins.

## Verified facts (2026-11-18)

Checked against the image and the `0.9.2` tag. These are not assumptions:

- **Image config:** `Entrypoint=["bash","/startup.sh"]`, no `User`,
  `ExposedPorts 8040/tcp`, **no `Healthcheck`**, no `Volumes`. Podman therefore
  inherits no probe, and the quadlet must declare one (issue #113 mechanics).
- **`startup/startup.sh` at tag 0.9.2:** it starts as root. When both `PUID`
  and `PGID` are set, it remaps the internal `pinepods` user. On every start
  it chowns the top-level dirs **non-recursively** (downloads, backups,
  local-media, cache, certs, logs). It then runs a **one-time** `chown -R
  PUID:PGID /opt/pinepods/downloads /opt/pinepods/backups`, gated by the
  marker `/opt/pinepods/downloads/.perms-migrated` (lines 252–260). The marker
  is created after a successful chown. A failure (RO/NFS) is skipped
  non-fatally and retried next boot. Then it runs
  `exec su-exec PUID:PGID horust`. Without PUID/PGID everything runs as root
  ("legacy mode").
- **Valkey is mandatory.** The API connects to Valkey before it listens. With
  Valkey down, nginx answers 502 for every `/api/*` request, `/api/health`
  included.
- **Postgres 17 and 18 are the only documented versions.** New installs
  default to 18.
- **Port 8042 is gone in 0.9.2.** gPodder sync is served on 8040 alongside the
  UI/API.
- **Public URL settings.** `HOSTNAME` must be the URL users reach (it is used in
  generated RSS and share links). `PINEPODS_PUBLIC_URL` overrides the URL shown
  to sync apps. Behind a proxy it honours `X-Forwarded-Host`/`-Proto`.

## Architecture decisions

### Standalone containers on `newt-net`, no pod

There is no shared-namespace requirement (the `pangolin.pod` exception exists
only because of Gerbil's CGNAT tunnel IPs). The app reaches its sidecars by
container name (`pinepods-postgres:5432`, `pinepods-valkey:6379`), and
`tailscale-gateway` reaches the app as `pinepods:8040`. There is no
`PublishPort`, so none of 8040, 5432 or 6379 is bound on the host. bow no longer
runs Newt (BUG-017 / remove-bow-newt). `newt-net` is still the shared named
network, and `tailscale-gateway` owns it on bow.

### Downloads take over audiobookshelf's `Podcasts` directory

PinePods replaces abs for podcasts, so its downloads reuse the existing
`/var/lib/materia-data/Podcasts` on the LVM data disk. That directory already
exists, so there is no BUG-005 bind-source risk. Backups get a new sibling:

```
/var/lib/materia-data/Podcasts           → /opt/pinepods/downloads  (rw, :Z)
/var/lib/materia-data/pinepods-backups   → /opt/pinepods/backups    (rw, :Z)
```

- **Ownership is safe only because abs is gone first.** The one-time
  `chown -R` re-owns the tree to UID 1000, and `:Z` relabels it to a private
  MCS label that only this container can access. If abs still mounted
  `Podcasts` (`:z`, rw), abs would lose access, and the two apps would
  briefly share writes. abs's mount is therefore removed in an **earlier**
  commit, and that commit must reach bow before PinePods is assigned.
- **The directory starts empty.** Deleting a library in the abs UI removes
  only abs's database entries, not the files on disk. Empty `Podcasts/` on the
  host after abs releases it. PinePods ignores files it didn't download (they
  would just be orphaned disk use). Episodes are downloaded again on demand.
- It stays on the LVM disk, not in a named volume. Named volumes are under
  `/var/lib/containers/storage/volumes`, which `restic-backup` backs up
  nightly, and re-downloadable podcast audio doesn't belong in Storage Box
  snapshots.
- The `.perms-migrated` marker lands in `Podcasts/`. Do not delete it.
- `pinepods-backups` is new. `mkdir -p` it on bow **before** the PinePods
  commit (BUG-005: podman does not create bind sources).
- `local-media` is not mounted. "Add Local Podcast" is out of scope.

### Cutover sequence (abs → PinePods)

Each step is a separate, verified state on bow. Never combine steps 3 and 5
in one push.

1. **Export** abs podcast subscriptions as OPML (abs UI → podcast library →
   OPML export). Keep the file off-repo.
2. **Delete** the abs podcast library in the abs UI.
3. **Commit A:** remove `Volume=/var/lib/materia-data/Podcasts:/podcasts:z`
   from `audiobookshelf.container.gotmpl` and update its comments. Push and run
   materia on bow.
   `verify:` `podman inspect audiobookshelf --format '{{range .Mounts}}{{.Source}} {{end}}'`
   has no `Podcasts`, `materia-update` shows no FATA, and audiobooks still play.
4. **Host prep:** empty `Podcasts/` (`sudo find /var/lib/materia-data/Podcasts
   -mindepth 1 -delete`, after a `du -sh` and a last look), then `sudo mkdir -p
   /var/lib/materia-data/pinepods-backups`.
   `verify:` `find /var/lib/materia-data/Podcasts -mindepth 1 | wc -l` → 0, and
   `test -d /var/lib/materia-data/pinepods-backups`.
5. **Commit B:** assign PinePods (Task 6).
6. **Import** the OPML in PinePods (Settings → Import).
   `verify:` the subscription count equals the abs count noted at step 1.

### Runs non-root via PUID/PGID=1000, not `User=`

The entrypoint must start as root to remap the user and chown, then it drops
privileges itself. Setting quadlet `User=1000` would break `usermod`/`chown`,
so use `Environment=PUID=1000` and `PGID=1000`. This differs from mediamanager,
whose entrypoint skips permission work as non-root. Here root-then-drop is the
designed path.

### Postgres sidecar: copy mediamanager's proven shape

- Image and digest are identical to `mediamanager-postgres`, so a single
  Renovate PR bumps both.
- `Environment=PGDATA=/var/lib/postgresql/data` plus the named volume
  `pinepods-db.volume` at that path. The 18+ relocation gotcha applies. The
  pinepods docs warn against that mount path on postgres:18, but that warning
  is about Docker's default anonymous-volume layout. The override is proven on
  bow by mediamanager.
- `POSTGRES_DB=pinepods_database`, `POSTGRES_USER=pinepods`, and
  `POSTGRES_PASSWORD` from secret `pinepodsDbPassword`.
- `Notify=healthy` + `HealthCmd=pg_isready -U pinepods -d pinepods_database`
  gate the app's start. The app has `Requires=`/`After=` on postgres and
  valkey. Do not rely on the app's own retry. Its startup behaviour on an
  absent DB is unverified, and a crash loop fails the host.
- The volume stays root-owned with no `User=`/`Group=`, because the entrypoint
  chowns PGDATA.

### Valkey sidecar: ephemeral, health-gated

- No volume **if** the smoke test shows an acceptable loss profile. That is
  [INFERENCE]: pinepods uses Valkey for caching and task state. The test must
  *replace* the valkey container (`podman rm -f` + recreate, not just restart)
  while a download is queued and a user is logged in. Record what is lost
  (sessions? queued jobs? nothing?) and whether the app recovers without a
  restart of its own. Accept ephemeral only if every loss is self-healing or
  trivially redone.
- If persistence is needed, a volume alone is not enough. The
  `valkey/valkey` image writes nothing to `/data` unless told to. Specify
  `Exec=valkey-server --appendonly yes --appendfsync everysec` (or `--save`
  RDB snapshots) plus `pinepods-valkey.volume` at `/data`, and re-run the same
  replace test to prove that the state survives.
- `HealthCmd=["valkey-cli","ping"]` (JSON form, no shell needed) plus
  `Notify=healthy`.
- Upstream's compose uses `valkey/valkey:8-alpine`. Pin the precise
  `8.1.9-alpine`, so Renovate keeps three-part precision (see the jellyfin
  precision gotcha).

### App health check

`HealthCmd=` with `HealthStartPeriod=60s` and `HealthOnFailure=kill`, probing
`http://localhost:8040/api/health` through the in-container nginx. That probe
exercises nginx, the API and Valkey together. The probe binary
(`curl`/`wget`) is **unverified**, so check it in the smoke test
(`podman run --rm --entrypoint sh <img> -c 'command -v curl wget'`). The image
is Debian-based with bash, so the plain-string `/bin/sh -c` form is fine if a
client exists.

### Secrets and attributes

`MANIFEST.toml` lists `Secrets = ["pinepodsDbPassword"]` as the first line,
**before** any table header (the top-level-key gotcha). The value goes in
`attributes/bow.yml` under `components.pinepods.pinepodsDbPassword`, written
with `sops --set` from a generated value (`openssl rand -base64 32 | jq -Rs`),
never pasted by hand.

The app gets `DB_PASSWORD` via `secretEnv`. Non-secret env:
`DB_TYPE=postgresql`, `DB_HOST=pinepods-postgres`, `DB_PORT=5432`,
`DB_USER=pinepods`, `DB_NAME=pinepods_database`,
`VALKEY_HOST=pinepods-valkey`, `VALKEY_PORT=6379`, `TZ=Etc/UTC`,
`DEBUG_MODE=false`, `SEARCH_API_URL`/`PEOPLE_API_URL` (upstream hosted
defaults, accepted 2026-11-18: search queries go to `*.pinepods.online`), and
`HOSTNAME=https://pinepods.{{ .baseDomain }}`. `baseDomain` is already a
global attribute, so no new vault key is needed for it.

There is no admin bootstrap env. `USERNAME`/`PASSWORD` would put a credential
in a vault for a one-time action. The web UI prompts for the first admin on
first visit, and we do that right after deploy (see the exposure step below).

### Exposure: T2 path, Pangolin SSO **off**

- Add `"8040": { "TCPForward": "pinepods:8040" }` to
  `components/tailscale-gateway/serve/serve.json`. That restarts the gateway
  (`RestartedBy`), which briefly drops every forwarded connection and triggers
  the `advertise-services` re-advertise. Check the unit journal for
  `advertised:` afterwards.
- Pangolin resource `pinepods.<baseDomain>`: **site `flutterina`**, host
  `<bow-ts-ip>:8040`. Change site *and* host (the T2 retarget gotcha). Verify
  through `/api/v1/traefik-config` in the `app` container.
- **SSO off.** Native PinePods apps and gPodder clients (AntennaPod, Kasts)
  call the API directly with app passwords. They cannot follow Pangolin's 302
  (the beszel-agent #23 class). The app's own login (plus optional
  OIDC/TOTP) is the auth layer, as for jellyfin/audiobookshelf.
- **First-admin race:** with SSO off and no bootstrap env, whoever loads the
  site first creates the admin. Mitigation: create the Pangolin resource with
  **SSO on** (Pangolin's default). Create the admin through it as the only
  Pangolin-authenticated user. Confirm that a logged-out request to the
  first-run endpoint no longer offers admin creation, and only then turn SSO
  off. A disabled resource would offer no route at all. The private
  alternative (tailnet `bow-ts-ip:8040` straight from the workstation) works
  only if the tailnet grants allow that port to your device. Do not rely on it
  unverified.

### Backups

- `pinepods-db.volume` is covered by restic's nightly volume backup
  (crash-consistent, same as mediamanager).
- Extend `mise db:backup` to cover pinepods. A row alone is **not enough**:
  `counts()` and `dump()` hardcode `-U mediamanager -d mediamanager`
  (`.mise/tasks/db/backup`, the postgres branches). Add `db user|db name`
  fields to the `DBS` entries and thread them through `counts`, `dump` and the
  `--compare` path. Then add
  `pinepods|postgres|pinepods-postgres|pinepods-postgres.service|pinepods.service|materia-pinepodsDbPassword|systemd-pinepods-db|pinepods|pinepods_database`.
  Future major postgres bumps then have the dump/row-count path that BUG-010
  lacked. (Separately, that task's client `PG` pin is still 18.6 while the
  servers run 18.7. That is harmless for dumps, but bump it in the same
  change.)
- Downloads are not backed up (they can be downloaded again). In-app backups
  land in `/var/lib/materia-data/pinepods-backups`, which is outside restic's
  paths. That is acceptable, since the DB volume is the source of truth.

## Files

```
components/pinepods/
  MANIFEST.toml                       # Secrets first; [[Services]] ×3 with RestartedBy
  pinepods.container.gotmpl           # app, PUID/PGID, binds, healthcheck, Requires= sidecars
  pinepods-postgres.container.gotmpl  # copy of mediamanager-postgres shape
  pinepods-valkey.container.gotmpl    # ephemeral, valkey-cli ping health
  pinepods-db.volume                  # root-owned, no User=/Group=
MANIFEST.toml                         # add "pinepods" to Hosts.bow Components (Commit B, LAST)
components/audiobookshelf/audiobookshelf.container.gotmpl  # drop Podcasts mount (Commit A, FIRST)
components/tailscale-gateway/serve/serve.json  # + 8040 forward
.mise/tasks/db/backup                 # + pinepods row
AGENTS.md                             # pinepods layout entry; abs layout line + Audiobookshelf
                                      # gotcha now say audiobooks only; new gotchas learned
```

Renovate needs no change. The `quadlet` manager already matches
`*.container.gotmpl`. Check after merge that the dependency dashboard (#6)
lists all three images (the minimus "silent lookup failure" lesson).

## Tasks

Each task ends with a runnable `verify:`.

1. **Local smoke test (no host touched).** Run the three images with rootless
   podman on a throwaway named network, using the exact env, PUID/PGID and
   binds above (tmp dirs). Confirm the following: the UI answers on 8040;
   `/api/health` returns 200; a probe client exists in the image; the downloads
   dir is chowned to 1000 and files are written as 1000; the app waits or fails
   cleanly with postgres down; restarting valkey keeps the user logged in and
   in-flight state. Then subscribe to one feed, download one episode, and
   connect one gPodder client via an app password over plain HTTP. Also
   run the valkey replace test from the Valkey section. Record the results in
   this file.
   `verify:` `curl -fsS localhost:8040/api/health`. Check ownership **inside
   the container**: `podman exec pinepods stat -c %u /opt/pinepods/downloads/<file>`
   → `1000`. Host-side `stat` under rootless shows a subordinate UID, so use
   `podman unshare stat` there if needed.
1b. **Quadlet-level validation.** Direct `podman run` does not exercise
   `Notify=healthy`, `Requires=`/`After=` or `HealthOnFailure`. Copy the three
   rendered quadlets (hand-substituted, since there is no local materia
   renderer) into `~/.config/containers/systemd/`. Then `systemctl --user
   daemon-reload` and start `pinepods.service` cold.
   `verify:` `/usr/libexec/podman/quadlet -dryrun -user` parses all three. The
   app's `ActiveEnterTimestamp` is later than both sidecars' healthy time
   (`journalctl --user -u pinepods-postgres -u pinepods-valkey -u pinepods`).
2. **Component files** (`components/pinepods/*`), not yet assigned to any host.
   `verify:` `mise clean && mise ign --server-name bow` renders. TOML parses
   (`yq -p toml . components/pinepods/MANIFEST.toml`). `grep -n '#'` shows no
   inline comments after values.
3. **Vault:** `sops --set` `components.pinepods.pinepodsDbPassword` in
   `attributes/bow.yml`. `verify:` `sops -d attributes/bow.yml | yq
   '.components.pinepods | keys'`.
4. **abs cutover, steps 1–4** of "Cutover sequence" (OPML export, delete
   library, Commit A, host prep). `verify:` as listed per step.
5. **`db:backup` parameterization + pinepods row** (see Backups). `verify:`
   `mise db:backup --target <bow>` still dumps grimmory + mediamanager unchanged
   *before* pinepods exists (that entry is skipped as not running). After
   deploy: `mise db:backup --target <bow>` runs after
   deploy and prints pinepods row counts.
6. **Assign + expose (one push, Commit B, only after Task 4 is verified):** add `pinepods` to `Hosts.bow`, add the
   serve.json forward, then run materia on bow.
   `verify:` `journalctl -u materia-update.service -n 200 | grep -c FATA` → 0.
   `systemctl is-active pinepods pinepods-postgres pinepods-valkey`.
   `podman healthcheck run pinepods`. The gateway journal shows `advertised:`.
7. **Pangolin resource + first admin** per the exposure section, then the
   **OPML import** (cutover step 6).
   `verify:` `curl -sI https://pinepods.<baseDomain>/` → 200 (not a 302 to
   pangolin after SSO is turned off). Run the traefik-config check on
   flutterina's site. `curl --http3-only -sI` gives the same status.
8. **Docs:** AGENTS.md: add the pinepods layout entry. Rewrite the
   audiobookshelf layout line and its gotcha bullet (it currently explains
   the ro AudioBooks / rw Podcasts split) to say audiobooks only, with podcasts
   moved to pinepods. Add any new gotchas, then close the issue.
   `verify:` `git diff --stat` touches only the intended files. Preflight is
   green.

## Rollback

Remove `pinepods` from `Hosts.bow` and the serve.json forward, then push.
materia stops and removes the units. Volumes and `pinepods-backups` remain
until deleted by hand. Returning podcasts to abs means reverting Commit A.
Before that, `sudo chown -R` `Podcasts/` back to abs's owner (abs runs as
root) and let abs's `:z` relabel it. Then re-create the abs library and import
the OPML.

## Decisions (2026-11-18)

- **Replace abs for podcasts:** yes. Cutover sequence above.
- **Upstream-hosted search/people APIs:** accepted. Self-hosting the search
  API (needs Podcast Index keys) is a possible later change.

## Open questions

1. **OIDC.** PinePods supports OIDC. Wiring it to an IdP is out of scope and
   a later improvement.
2. **Disk.** bow's LVM data disk was ~94% used during #70. Emptying the old
   abs `Podcasts/` frees some space. Check `df -h /var/lib/materia-data` before
   Task 6, and set the app's download-retention settings.
3. **Listening history.** OPML carries subscriptions only. Played or
   in-progress state from abs is lost. Acceptable unless you say otherwise.

## Review log

**2026-11-18, after the review:** storage was revised to take over abs's
`Podcasts/` once abs releases it (user decision). This supersedes the
dedicated-directory rationale in finding 2 below.

**2026-11-18, Codex (GPT) review: proceed-with-changes.** All five findings
were accepted and applied above:

1. `db:backup` hardcodes the mediamanager user/db, so a row alone fails. The
   plan now parameterizes the task (confirmed in source).
2. The plan wrongly claimed a recursive chown on *every* start. It is one-time,
   gated by `.perms-migrated` (confirmed at startup.sh:252–260). Facts and
   storage rationale were corrected. Dedicated storage still stands on
   first-start re-own + independent management.
3. Host-side `stat` under rootless shows subordinate UIDs. The check now runs
   in-container, and Task 1b validates the generated units (`Notify=healthy`,
   ordering).
4. A Valkey volume alone persists nothing. The plan now specifies a replace
   test, plus AOF config and a volume if persistence is needed.
5. The "disabled resource" bootstrap offered no route. It is now SSO-on first,
   then admin, then a verify step, then SSO off.
