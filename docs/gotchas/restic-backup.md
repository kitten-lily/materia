# Restic and database backups

Read this guide when changing backups, restoring a database, provisioning a Storage Box, or evaluating Proton Drive.

- **`restic-backup` is `Type=oneshot` + timer-activated, not `Restart=always`.**
  No `[Install]` section on the `.container.gotmpl` (never started directly);
  `Stopped = true` + `Oneshot = true` in the component manifest tell Materia
  to never auto-start it and not to flag a quick exit as a failure. Only
  `restic-backup.timer` (`Static = true`, `WantedBy=timers.target`) triggers
  it, on the `resticOnCalendar` attribute-driven schedule.

- **Restoring a SQLite app (Pangolin, Beszel) from the nightly copy (#195).**
  flutterina's `sqlite-dump` component writes a `VACUUM INTO` copy of each
  database into `systemd-sqlite-dumps` at 23:30; restic carries it off-host
  at 00:00. The live `data.db`/`db.sqlite` in the app volumes are backed up
  too, but only as files read while the app writes, so restore from the copy:
  1. Pick the snapshot and check the copy: `mise db:restore-test --target
     core@<flutterina tailnet IP> [--snapshot <id>]` must pass (freshness,
     the `.done` sha256s, `integrity_check`, exact row counts).
  2. Restore `<name>.sqlite` from that snapshot (restic with the
     restic-backup job's own env, as the restore test does) and compare its
     sha256 with line 2 of `<name>.done`.
  3. Stop the app. For Pangolin that is the whole pod (stopping `app` takes
     `gerbil`/`traefik` down via `Requires=`, so this is an edge outage).
  4. Replace the database file with the copy, and **delete its `-wal` and
     `-shm`**: they belong to the old file and would be replayed onto the new
     one. Pangolin: `pangolin-config/_data/db/db.sqlite` (rollback-journal
     mode on flutterina, usually no sidecars). Beszel:
     `beszel-data/_data/data.db`; keep `id_ed25519` (the hub's SSH key) and
     either keep or drop `auxiliary.db` (only `_logs`).
  5. Start the app (Pangolin: `pangolin-pod.service`, then app, gerbil,
     traefik) and check its routes.

  Drilled 2026-11-21 on snapshot `1412a832`. The restore test's throwaway hub
  answered `/api/health` on the restored Beszel copy. A throwaway Pangolin
  `app` on the restored `db.sqlite`, with `--network none`, the live configs
  read-only and `materia-serverSecret`, answered `/api/v1/` and generated the
  same Traefik config (20 routers, 10 services) as the live app. Pangolin's
  `db.sqlite` is not in WAL mode on flutterina despite the code setting it;
  a read-only `VACUUM INTO` there makes a writer wait, measured at under
  60 ms per commit for a 21 MB database.
- **A manual restic run prunes that day's earlier snapshot.** restic-backup's
  `forget` keeps one snapshot per day (`resticKeepDaily`), the latest. Running
  `restic-backup-trigger.service` by hand at 09:25 on 2026-11-18 removed the
  00:00 snapshot of that day (`no matching ID found for prefix`). When a test
  needs "an older snapshot", take one from a previous day.
  `mise db:restore-test --target <host> [--snapshot <id>]` (#194) checks the
  db-dump files and app volumes of one pinned snapshot end to end.

- **OpenSSH private keys need a trailing newline after the END marker.**
  `ssh`'s `ssh_config` `IdentityFile` loader fails with `error in libcrypto`
  on an ed25519 key whose final line (`-----END OPENSSH PRIVATE KEY-----`)
  has no trailing newline, even though `ssh-keygen -y` accepts the same
  file (OpenSSH bug #3849). Some `ssh-keygen` builds produce a key without
  the final newline. When storing a key for podman secret mount, ensure the
  trailing newline is present: `tail -c 1 <file> | wc -l` is 0 if the last
  byte isn't a newline — append one with `printf '\n' >> <file>`. Do NOT
  pipe through `sed '$a\'` — that syntax is not portable across GNU/BSD
  `sed` and can silently corrupt the key content (BUG-003, layer 2).
- **`ssh-keygen -y` and `ssh` use different key-loading code paths.**
  `ssh-keygen -y` is more tolerant — it accepts keys with missing trailing
  newlines that `ssh`'s `IdentityFile` loader rejects with `error in
  libcrypto`. Don't trust `ssh-keygen -y` alone as a "key is valid" check;
  always test with an actual `ssh -v` connection attempt (or `ssh -G` for
  config resolution, though note `ssh -G` does NOT load/parse keys — only
  a real connection exercises that path).

- **openssh static build: no Alpine package, must build from source.**
  Alpine 3.22 has no `openssh-static` package (apk returns "no such package").
  The `restic-backup` image builder stage builds the `ssh` client from the
  OpenSSH portable tarball with `LDFLAGS=-static --with-privsep-path=/tmp`
  (privsep is sshd-only; `/tmp` is a harmless placeholder in the builder stage).
  Static builds need both header and static-archive packages: `zlib-dev` +
  `zlib-static`, `openssl-dev` + `openssl-libs-static`. The `opensshVersion`
  ARG in the Dockerfile is Renovate-trackable — bump it when a new release is
  needed. **`./configure` with no `--prefix`/`--sysconfdir` defaults the
  system-wide config path to `/usr/local/etc/ssh_config`, not
  `/etc/ssh/ssh_config`** — confirmed via `strings` on the built binary
  (BUG-001). Any `.container.gotmpl` mounting a system ssh config for this
  binary must target `/usr/local/etc/ssh_config`.
- **`RESTIC_SFTP_ARGS` is not a real restic env var.** Restic's sftp backend
  only accepts custom SSH args via the `-o sftp.args=...` CLI flag (added
  v0.16.1) — no `-o` flag has an environment-variable form. Since the
  wrapper never passes CLI flags to restic, SSH options (`IdentityFile`,
  `UserKnownHostsFile`, `StrictHostKeyChecking`) are set via a static
  `ssh_config` data resource bind-mounted to `/usr/local/etc/ssh_config`
  (see BUG-001 — NOT `/etc/ssh/ssh_config`, the conventional path most
  distro-packaged OpenSSH builds use; this statically-built client's
  compiled-in sysconfdir defaults to `/usr/local/etc` since the Dockerfile
  passes no `--sysconfdir` to `./configure`) — OpenSSH's system-wide client
  config, read regardless of `$HOME` (scratch has none).
- **Scratch images need `Tmpfs=/tmp` for restic.** Restic stages backup pack
  files in `os.TempDir()` (`/tmp` by default). Scratch has no `/tmp`
  directory at all, so `restic backup` fails with "no such file or
  directory" on the temp pack path unless the `.container.gotmpl` adds
  `Tmpfs=/tmp` (quadlet's tmpfs-mount directive — ephemeral, not part of any
  materia-managed path, which avoids the data-dir drift described in [Materia behaviour](materia-behaviour.md)).
- **A restic run killed by a unit timeout leaves its repository lock behind,
  and restic never skips a stale lock on its own, so every later run fails
  (BUG-012).** `restic-backup` ran with `TimeoutStartSec=900`. On bow
  (2026-10-13) a backup ran past it and left a *shared* lock. Later
  backups could share that lock and kept saving snapshots, but `forget
  --prune` needs the lock exclusively and failed (exit 11) every night, so
  retention stopped. On flutterina (2026-10-15) the kill landed 2 s after
  prune printed `done`, leaving an *exclusive* lock. That blocks every
  command, including the wrapper's `restic cat config`. The old wrapper
  read any non-zero exit there as "no repository" and ran `restic init`,
  which failed with a misleading `config file already exists`. Result: no
  backup for 9 days, and `systemctl --failed` was the only on-host sign.
  healthchecks.io received the `/fail` pings, but nobody acted on them.
  Fixes: the wrapper runs `restic unlock` before every job (without
  `--remove-all` this removes only locks not refreshed for 30 min, or
  same-host locks whose PID is gone; live restic refreshes every 5 min).
  It runs `restic init` only on exit 10 ("repository does not exist").
  The unit now has `TimeoutStartSec=4h`. The same-host PID rule rarely
  applies here: every container gets a random hostname, so in practice
  the 30-minute age is what makes a lock stale. Inspect a repo with the
  job's own credentials by running the image with `--entrypoint restic`
  and the same `Secret=`/`Volume=` lines (`list locks --no-lock`,
  `cat lock <id> --no-lock` show the owner and age).
- **The restic-backup workflow must not pass `resticVersion`/
  `opensshVersion` build-args.** It hardcoded `resticVersion=v0.18.0` in
  both build steps, overriding the Dockerfile `ARG` that Renovate bumps, so
  the v0.19.1 bump (#18) never reached an image (`restic version` in the
  deployed image said 0.18.0). The override also hid that restic 0.19
  needs Go ≥ 1.25.8, which the old `golang:1.23-alpine` builder couldn't
  provide. The Dockerfile is now the only version source (BUG-012).

- **Duplicated source-of-truth values need a flagged pairing, not just a
  comment.** Two values in this repo are intentionally copied from an
  external or provisioning-time source into a materia attribute/resource,
  that need to stay in sync: `hcPingURL`
  (`attributes/vault.yml globals`, mirrors the Proton Pass
  `healthchecks/ping-url` field the `.bu` template also reads at transpile
  time) and `known_hosts` (`components/restic-backup/known_hosts`, mirrors
  `provisioning/storageboxes/<box>/known_hosts` refreshed by `mise
  hz:storagebox:keyscan`). If either upstream value rotates, update both
  copies manually. **`known_hosts` drift is now CI-gated**
  (`.github/workflows/preflight.yml`'s `known-hosts-drift` job, equivalent
  to `mise check:known-hosts`): a PR that updates a storagebox source
  without refreshing the component copy fails preflight. Run
  `mise check:known-hosts --fix` after `hz:storagebox:keyscan` to copy the
  union of all box sources into the component file (the keyscan task now
  prints this reminder). `hcPingURL` has no such check — it mirrors an
  external Proton Pass field this repo can't read at CI time — so it stays
  a true manual pairing. The `known_hosts` drift bug bit `bow` once
  (issue #34's follow-on): the sub2 subaccount was added to the source
  (`622ee5e`) but the component copy (committed `aa8688a`) was never
  refreshed, so restic-backup failed host-key verification on every run
  until #34's nftables fix unblocked the egress path and surfaced it.

## Storage Boxes

`hz:storagebox:*` provisions the Hetzner Storage Box that the
`restic-backup` component (#2) backs up to. Same conventions as `hz:*`:
`hcloud` with a `fnox get` token, explicit name flags, config committed as
`provisioning/storageboxes/<name>/storagebox.toml`.

| Task | Description |
|---|---|
| `mise hz:storagebox:create --box-name <n>` | Create box from `storagebox.toml` — SSH-only, delete-protected, daily Hetzner snapshots |
| `mise hz:storagebox:delete --box-name <n> --confirm` | Delete box (delete-protected boxes also need `--disable-protection`) |
| `mise hz:storagebox:keyscan --box-name <n>` | Pin the box's SSH host keys to `provisioning/storageboxes/<n>/known_hosts` (commit it) |
| `mise hz:storagebox:subaccount --box-name <n> --server-name <s>` | Per-server subaccount, home `backups/<s>`, SSH-only |
| `mise hz:storagebox:install-key --box-name <n> --server-name <s>` | Generate ed25519 key, install via `install-ssh-key` (port 23), write private key straight into the vault |

Order per server: `create` → `keyscan` (commit `known_hosts`) →
`subaccount` → `install-key` → the printed `sftp://...` repository
attribute (`components.restic-backup.resticRepository`) and the SSH key
(`components.restic-backup.storageBoxSshKey`) are both written straight
into `attributes/<server>.yml` by `install-key` itself, via `sops --set`
— no manual `sops edit` step remains for either. A
multi-line private key copy-pasted by hand into an interactive editor is
exactly the kind of thing that picks up CRLF/whitespace corruption from
terminal reflow, producing a key that looks plausible (BEGIN/END markers
intact) but fails to load (`error in libcrypto`) — see BUG-003. Passwords
are printed once — store them in Proton Pass (both are resettable via
`hcloud storage-box [subaccount] reset-password`) — one item per box
(`storagebox-<box>`) with a `primary-password` field and a
`<server>-password` field per subaccount. Subaccounts have no
API-side SSH keys; `install-ssh-key` writes `<home>/.ssh/authorized_keys`
in both port-23 (OpenSSH) and port-22 (RFC4716) formats.

## Resource map

```text
  restic-backup/                 # restic-backup component (base role)
    MANIFEST.toml                # component manifest — Secrets, Defaults, Services
    restic-backup.container.gotmpl # oneshot backup job, pulls the GHCR image by digest
    restic-backup.timer.gotmpl   # attribute-driven schedule (resticOnCalendar), targets the trigger below
    restic-backup-trigger.service # untracked-restart wrapper (systemctl restart), see BUG-004
    ssh_config                   # static /usr/local/etc/ssh_config (sftp SSH options, see BUG-001)
    known_hosts                  # copy of provisioning/storageboxes/<box>/known_hosts
  db-dump/                       # nightly logical DB dumps into a named volume restic carries off-host (bow-only, #194)
    MANIFEST.toml                # no Secrets (references each app component's), NoRestart, Stopped+Oneshot dumps, static timer
    dump.bash                    # shared dump script (not .sh: see the Script-resource gotcha): counts.pre, dump, counts.post, .done via atomic renames
    db-dump-grimmory.container.gotmpl     # mariadb-dump --databases grimmory, same image pin as grimmory-mariadb
    db-dump-mediamanager.container.gotmpl # pg_dump mediamanager, same image pin as mediamanager-postgres
    db-dump-pinepods.container.gotmpl # pg_dump pinepods, same image pin as pinepods-postgres (#196)
    db-dumps.volume              # systemd-db-dumps: <name>.sql/.counts.pre/.counts.post/.done (root, 0700/0600)
    db-dump-trigger.service.gotmpl # systemctl restart of every dump unit + healthchecks.io db-dump-<host> pings
    db-dump.timer.gotmpl         # dbDumpOnCalendar, default 23:30, before restic's 00:00 run
  sqlite-dump/                   # nightly consistent SQLite copies on flutterina (Pangolin, Beszel), the db-dump counterpart (#195)
    MANIFEST.toml                # no Secrets, NoRestart, Stopped+Oneshot dumps, static timer
    dump.cjs                     # `dump`: VACUUM INTO from a read-only connection, integrity_check, counts, .done with sha256s; `check`: verify a restored copy
    sqlite-dump-pangolin.container.gotmpl # pinned Pangolin image (Node + better-sqlite3), Network=none, systemd-pangolin-config by name (no Requires= on the app)
    sqlite-dump-beszel.container.gotmpl   # same image, systemd-beszel-data: data.db only (auxiliary.db is just _logs)
    sqlite-dumps.volume          # systemd-sqlite-dumps: <name>.sqlite/.counts/.done (root, 0700/0600)
    sqlite-dump-trigger.service.gotmpl # systemctl restart of both dump units + healthchecks.io db-dump-<host> pings
    sqlite-dump.timer.gotmpl     # sqliteDumpOnCalendar, default 23:30
    test/compat.bash             # dump + check on a WAL fixture; sqlite-dump-compat.yml runs it after every Pangolin bump
images/
  restic-backup/
    Dockerfile                   # scratch + static restic + static openssh + wrapper
    wrapper/                     # Go entrypoint: ping, init, backup, forget
```

## Proton Drive proof of concept

The tested musl CLI needs Alpine with `libstdc++`. Headless login works with the `pass` store, and a transplanted session needs a passphrase-free GPG key and a copy scrubbed of locks and sockets. Put global options after the subcommand: a leading `-v` runs the version command and exits successfully without uploading. Upload only populated restic fan-out directories, verify files remotely, and reconcile deletions explicitly so the mirror honors retention. The POC records the CLI flags, trash semantics, and measured behavior. [Proton Drive POC results](../../specs/plans/issue-103-poc-results.md)

## References

- restic scripting/env vars: https://restic.readthedocs.io/en/stable/075_scripting.html
- restic sftp backend: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
