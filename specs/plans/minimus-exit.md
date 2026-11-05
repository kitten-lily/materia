# Plan: move off minimus (reg.mini.dev) to Docker Official Images

## Why

minimus was acquired by echo.ai, and `reg.mini.dev` no longer serves
anonymous pulls. `auth.mini.dev/api/v1/registry/token` returns 403, and
Renovate's dashboard (#6) has failed to look up all three images since
about 2026-10-22. They have had no security updates since. Running
containers still have their cached images, but a rebuilt or pruned host
could not pull traefik at all, and flutterina would have no edge.

Decision (user, 2026-11-05): **Docker Official Images**, which allow
anonymous pulls, can be pinned and work with Renovate as-is. Docker
Hardened Images need a login on every host and in Renovate; that is
deferred to #174.

## Swaps (same versions as the frozen minimus pins)

| Component | Host | From | To |
|---|---|---|---|
| pangolin `traefik` | flutterina | `reg.mini.dev/traefik:v3.7.16` | `docker.io/library/traefik:v3.7.16@sha256:1336e85a…` |
| grimmory `grimmory-mariadb` | bow | `reg.mini.dev/mariadb:v12.3.3` | `docker.io/library/mariadb:12.3.3@sha256:d46e102f…` |
| mediamanager `mediamanager-postgres` | bow | `reg.mini.dev/postgres:v18.6` | `docker.io/library/postgres:18.6@sha256:3a426452…` |

Renovate takes over version bumps afterwards (e.g. traefik v3.7.17).

## Differences that matter (verified locally 2026-11-05)

- **traefik:** official runs as root, so `AddCapability=NET_BIND_SERVICE`
  is dropped. Smoke-tested in the production shape: badger v1.8.0 loads,
  the router is enabled, a request through badger is served on `:80`, and
  a minimus-written `acme.json` (`1000:1000`, mode 600) reads without
  errors and keeps its owner and mode.
- **mariadb:** a datadir initialised as UID 1000 (minimus) is chowned to
  `999:999` by the official root entrypoint. Data kept, and
  `mariadb-dump` contains it. Env and data dir are unchanged (`MARIADB_*`,
  `/var/lib/mysql`).
- **postgres:** the official 18 image defaults `PGDATA` to
  `/var/lib/postgresql/18/docker`. Without an override and with data at
  `/var/lib/postgresql/data`, it **refuses to start** (exit 1). The
  quadlet sets `PGDATA=/var/lib/postgresql/data`. With it, the UID-1000
  cluster is chowned to 999, the data is kept and `pg_isready` passes. The
  test cluster's locale is `en_US.utf8` (collation version 2.41 on the
  official image).

Not changed: `letsencrypt.volume` and `grimmory-mariadb-config.volume`
keep `User=1000`/`Group=1000`. Those only apply at volume creation, the
new images handle both owners, and editing a `.volume` quadlet is an
untested planner path on hosts still running materia v0.7.0 (#173).

## Rollout

`.mise/tasks/db/backup` makes the host-side step executable (BUG-010 rule).

1. Land `mise db:backup` (no host effect).
2. `mise db:backup --target core@bow`. Per DB:
   - a logical dump (`mariadb-dump --all-databases` / `pg_dumpall`) from a
     throwaway official client container on `newt-net`, reading the
     existing materia podman secret;
   - exact per-table row counts;
   - `podman volume export` with the app and DB briefly stopped.

   Everything goes to `/var/lib/db-backups/<stamp>/` (root, 0700).
3. Only after step 2 succeeds, land the image swaps. On bow, run
   `materia-update` and confirm no `FATA`.
4. `mise db:backup --target core@bow --compare /var/lib/db-backups/<stamp>`
   fails on any missing table or row loss. Then check that both apps load.
   Postgres then warns of a **collation version mismatch** (glibc 2.44 on
   minimus/Wolfi → 2.41 on Debian). For each of `mediamanager`, `postgres`
   and `template1`, run `REINDEX DATABASE`, then
   `ALTER DATABASE … REFRESH COLLATION VERSION`.

   **Done on bow, 2026-11-05:** backup `20261105T101227Z` (grimmory 73
   tables / 863 rows, mediamanager 15 / 8). After the swap: materia-update
   green, both apps up over the tailnet, and `--compare` found no missing
   tables and no row loss.
5. flutterina (traefik) applies at its next `materia-update`. Check the
   public hostnames answer as before (baseline 2026-11-05:
   `pangolin.<domain>` and `beszel.<domain>` returned 200), and that
   `journalctl -u traefik.service` shows `Plugins loaded`.

   **Done on flutterina, 2026-11-05**, together with the badger v1.8.0 bump,
   in a single traefik restart. materia-update green (`update_rc=0`). traefik
   runs `docker.io/library/traefik@sha256:1336e85a…` and logged
   `Plugins loaded. plugins=["badger"]`. app, gerbil, traefik and the pod
   are active. pangolin/beszel return 200 from outside, still advertising
   HTTP/3, and beszel's `/api/health` returns 200. No minimus images are
   left in the repo.

## Rollback

- Image: revert the swap commit. The cached minimus images are still on
  the hosts (only new pulls are refused) [INFERENCE: true until the hosts
  prune images].
- Data, mariadb: stop `grimmory.service`, then
  `podman run --rm -i --network newt-net --secret materia-mariadbRootPassword,type=env,target=MYSQL_PWD <mariadb image> mariadb -h grimmory-mariadb -uroot < grimmory.sql`.
- Data, postgres: stop `mediamanager.service`, drop and recreate the
  `mediamanager` DB, and load `mediamanager.sql` through
  `psql -h mediamanager-postgres -U mediamanager -d postgres`. Or, with
  both services stopped, `podman volume import <volume> <name>-volume.tar`.
