# Materia behaviour

Read this guide when changing manifests, templates, attributes, secrets, reconciliation, or release gates.

- **Podman secrets are create-time.** Env secrets injected via
  `Secret=...,type=env` are read when the container is created. A rotated value
  needs the secret updated THEN `systemctl restart` the consumer — restarting
  alone won't repopulate. Materia handles the update; the restart is still
  required. **Podman secrets can also go stale** — materia doesn't always
  detect that a secret's *value* changed (vs. its *name*). After rotating a
  secret value in the vault, if the container still sees the old value,
  `sudo podman secret rm materia-<name>` the stale one and re-run
  `materia-update` to force recreation (BUG-003, layer 3). **It happened
  again on 2026-10-24 (#163 phase 4), and the run log looks fine:**
  materia logged `Update PodmanSecret serverKeyPem` and the secret's
  `UpdatedAt` moved, yet `podman secret inspect --showsecret` still held
  the old key. bb-storage/bb-asset then died with `tls: private key does
  not match public key` against the new cert, crash-looped to
  `start-limit-hit`, and materia aborted on bow. After rotating any secret,
  compare what podman holds with the vault (`--showsecret | openssl pkey
  -pubout | sha256sum` against the cert/vault) before trusting the run.

- **A `.sh` file in a component is a materia *Script*, not a data file.**
  materia maps the `.sh` extension to `ResourceTypeScript`
  (`pkg/components/component.go`, v0.8.1) and installs it into its
  `scripts_dir`, not `{{ m_dataDir }}`. On bow that install failed with
  `openat .dump.sh.<id>.materia_tmp: read-only file system` and aborted
  the whole run (`8/14 steps completed`), the same blast radius as every
  other single-resource failure here (#194). A helper script meant to be
  bind-mounted into a container must use another extension
  (`db-dump/dump.bash`). An unrecognised extension is a plain data file
  under the component's data dir.

- **`.gotmpl` suffix is stripped.** `config.yml.gotmpl` installs as
  `config.yml`. Only the last `.gotmpl` is stripped; `conf.gotmpl.gotmpl`
  installs as `conf.gotmpl`.
- **`m_dataDir` returns the host path.** `{{ m_dataDir "pangolin" }}` expands
  to `/var/lib/materia/components/pangolin` — use it for Volume= bind mounts
  in `.container` files so configs land in the right place.
- **Materia restarts containers by default.** `.container` and `.pod` resources
  trigger a service restart on update automatically. Use `RestartedBy` and
  `ReloadedBy` in the component manifest to control which resources trigger
  restart/reload for which services. Set `Settings.NoRestart = true` to disable
  automatic restarts entirely.
- **Secrets prefix.** Materia prefixes podman secrets with `materia-` by
  default (`containers.secrets_prefix` config). The `secretEnv`/`secretMount`
  macros handle this transparently — don't manually prefix the name.
- **`secretMount` cannot set `mode=`, `uid=`, or `gid=`.** Confirmed against
  materia's actual source (`internal/materia/snippet.go`): the macro only
  ever emits `Secret=<name>,type=mount,target=<value>` — despite the
  materia-templates(5) docs implying "additional arguments as defined in the
  Podman manual" are supported. Podman's `type=mount` default mode (`0444`
  in the version tested) is group/other-readable, which breaks anything with
  strict permission requirements (OpenSSH private keys refuse to load with
  "Permissions ... too open" — BUG-002). For secrets needing a specific mode,
  bypass the macro and hand-write the `Secret=` line directly, e.g.
  `Secret=materia-<name>,type=mount,target=<path>,mode=0400` — the
  `materia-` prefix matches the default `SecretName()` behavior (plain
  string concatenation, confirmed via the project's own test mocks) as long
  as `secrets_prefix` isn't overridden.
- **Never hand off a multi-line secret via manual copy-paste into `sops
  edit`.** `mise hz:storagebox:install-key` used to `cat` a freshly
  generated private key to the terminal with instructions to paste it into
  an interactive editor session under a YAML `|-` block. Terminal
  scrollback reflow, clipboard managers, or one misindented line can
  silently corrupt a multi-line key while leaving it looking plausible
  (BEGIN/END markers intact) — `ssh` then fails to load it with
  `error in libcrypto` (BUG-003), a much harder-to-diagnose failure than an
  outright rejected key. Fix: inject secret file content programmatically
  with `jq -Rs .` (JSON-encodes raw bytes, embedded `\n` escapes, no reflow
  risk) piped into `sops --set '["path"]["to"]["key"] <json>' vault.yml`
  — decrypts, sets, and re-encrypts in place, no human ever retypes the
  value.
- **`fnox.toml` sets `env = false`: no secret reaches a shell, so every
  caller reads one with `fnox get NAME`.** The workstation's fish config
  runs `fnox activate fish`, whose hook (`--on-event fish_prompt` plus
  `--on-variable PWD`) resolves every env-enabled secret on every prompt
  inside the checkout, as concurrent `pass-cli` calls — five here. Against
  a live session that is waste plus the age private key and Hetzner token
  sitting in every interactive shell. Against a logged-out or cleared
  pass-cli state it is corruption: concurrent first-time initialisation
  writes a `pass-cli.db` the stored local key cannot open
  (`hmac check failed` … `file is not a database`), and the next prompt
  re-breaks it before `pass-cli login` can run. Measured and fixed in
  krytis first (starlit-os/krytis#987, its `docs/skills/mise.md`
  § Switching the backend under a live session). `env = false` stops the
  hook resolving anything; `fnox get` ignores the mode. It also empties
  `fnox exec` (`fnox exec --help`: "`env = false` secrets are not [set],
  and are removed if the parent environment has them"), so no task uses
  it: tasks do `VAR="${VAR:-$(fnox get VAR)}"; export VAR`, exported so
  nested `mise hz:*` calls reuse it — one sequential `pass-cli` call per
  secret, never a concurrent batch. To recover a logged-out pass-cli, log
  in from `bash` (`export PROTON_PASS_LINUX_KEYRING=dbus; pass-cli login`):
  bash carries no fnox hook, and a fish prompt in a worktree on an older
  branch still reads that branch's `env = true` `fnox.toml`.

- **Templated config files are bind-mounted individually from the data dir.**
  Materia installs templated files to `{{ m_dataDir "pangolin" }}/config/`;
  `.container` files bind-mount each file on top of the runtime volume
  (`Volume=...config/config.yml:/app/config/config.yml:z`). Never bind-mount
  the whole data dir as an app-writable directory — see next gotcha.
- **The data dir is fully managed — app-writable paths need named volumes.**
  Materia treats everything under `/var/lib/materia/components/<name>/` as its
  own: any file it didn't install is drift, planned for removal on every run
  (the planner has no ignore mechanism). Pangolin's db, gerbil's generated key,
  logs, and generated traefik configs were all scheduled for deletion. Runtime
  state lives in named volumes (`pangolin-config.volume`) instead.
- **`Secrets` must be a top-level manifest key.** In `MANIFEST.toml`, the
  `Secrets = [...]` line has to appear BEFORE the first table header
  (`[Defaults]`, `[[Services]]`, ...). TOML assigns keys to the most recently
  opened table, so a `Secrets` line inside/after a table silently becomes a
  table key, the top-level field parses empty, and secret creation just never
  appears in the plan — no error anywhere. This (not the attributes engine) was
  why podman secrets weren't created; with it fixed, SOPS creates them fine and
  no manual `podman secret create` workaround is needed.
- **Attribute scoping is strict per-component — a missing key is a fatal
  vault-load error, not a template no-op.** `attributes/vault.yml`'s
  `components.<name>.*` keys are only visible when templating that specific
  component; they are NOT inherited by other components even if the value is
  conceptually shared. `beszel-hub.container.gotmpl`'s `{{ .baseDomain }}`
  referenced a value that existed only under `components.pangolin`, so
  materia-update failed with `map has no entry for key "baseDomain"` while
  loading beszel-hub — and because this is a fatal load error, it aborted
  the *entire* run, blocking reconciliation of every component on the host,
  not just beszel-hub. Fix: any value used by more than one component
  belongs in top-level `globals` (`sops --set '["globals"]["key"] "value"'`
  + `sops unset attributes/vault.yml '["components"]["old-owner"]["key"]'`
  with `SOPS_AGE_KEY` from `fnox get`), not duplicated per-component.

- **`Stopped = true` is the general "never auto-start" flag, not just for
  `.build`/`.image` services.** Confirmed against the materia manifest
  reference: "Prevents materia from starting the service." Any timer-
  activated oneshot service (not just build/image quadlets) should set it —
  used for `restic-backup.service` so only its `.timer` (not `materia
  update`) ever starts it. Pair with `Oneshot = true` ("prevents materia
  from checking if this service started successfully") for jobs that don't
  stay running.
- **Upgrading materia on a running host is a state migration, not an image-line
  edit.** The two `.bu` templates and `server:adopt-render` pin
  `ghcr.io/stryan/materia:v0.8.1@sha256:…` (#105, #173, #181), and Renovate
  updates all three, but Butane/adopt-render changes never reach an
  already-installed quadlet. Run `mise materia:sync-image --target <user@host>`
  first, inspect the plan, then repeat with `--apply`; it reads the repository
  pin, rejects `Unknown`/`Disable` plans, updates the live quadlet and verifies
  the new run, digest and failed-unit set. **A Renovate bump of the pin
  upgrades nothing by itself:** #181 moved the pins to v0.8.1 on 2026-11-07,
  and all three hosts were still on v0.8.0 until they were synced by hand on
  2026-11-20 (bow, krytis-runner, flutterina; every plan "No changes made").
  After merging a materia bump, run the task on each host. krytis-runner's
  target is `root@krytis-runner`.

  Two independent migration traps made a direct v0.7 → v0.8 edit destructive
  (#173, BUG-015/BUG-016). First, v0.7's
  `/var/lib/materia/output/lastrun.toml` stores `plan` as an array, while v0.8
  facts unmarshal it as a structured table; every v0.8 command aborts with
  `plan.Plan: expected table but found []any`. Upstream's v0.8 release notes
  require removing old last-run files. The sync task overlays an empty output
  directory for its read-only plan, then removes the exact legacy
  `lastrun.toml`/`lastplan.toml` paths only on apply.

  Second, both provisioning templates accidentally said literal
  `HostName=%q`. `mise ign` substitutes `${SERVER_NAME}`, not `printf` tokens,
  so `%q` reached the live quadlet unchanged. v0.7's old facts still found the
  host; v0.8 found no matching `[Hosts.<name>]` and planned to stop and remove
  **every installed component**. The guarded plan caught it before mutation.
  Templates now use `HostName=${SERVER_NAME}`; the sync task plans with the
  target's actual OS hostname and rewrites the live `HostName=` on apply.

  This drift was first caught by #86: bow's stale `:stable` image was v0.7.0
  (pulled 2026-06-16), whose `coalesceServices` emitted a zero-valued
  `(<parent>) Unknown Unknown` action when a service's only planned step was
  Enable or Disable. The usb-drive deploy therefore aborted the whole host.
  Upstream fixed that planner bug in v0.7.1 (`f1e7425`). Never infer live
  materia behavior from the template pin; use the sync task's plan and live
  evidence.

- **Materia's oneshot final-state wait is currently broken upstream —
  don't pair `Oneshot = true` with `RestartedBy`.** Confirmed against
  `stryan/materia` source (`pkg/services/service_state.go`): the
  internal sentinel used to mean "oneshot service, skip the final-state
  wait" (`services.StateInternalWildcard`, string value `"wildcard"`) is
  deliberately excluded from `serviceStateMap` ("Note we don't put this
  in the map since its internal"). Every place that reconstructs the
  sentinel from its stored string — `executor/execute.go`'s final health
  check and `executor/service_helpers.go`'s `waitService`, both via
  `services.NewServiceState(string)` — gets `StateUnknown` back instead,
  since the lookup silently falls through. `WaitUntilState`'s short
  circuit (`if state == StateInternalWildcard { return nil }`) can then
  never trigger, so it always polls for `ActiveState == "unknown"` (a
  state that never legitimately occurs) until materia's own default
  timeout elapses, then reports `FATA operation timeout: service ...
  did not reach state unknown` — even though the underlying job finished
  and exited 0. This is deterministic, not a race: any `Oneshot = true`
  service with a `RestartedBy` trigger will fail this way every time its
  watched resources change, regardless of job duration. Confirmed on
  flutterina (#31): `restic-backup.service` looked fine for months
  because `RestartedBy` only fires on a resource change, and the first
  real trigger (the `BACKUP_PATHS` quoting fix, commit `d6b4fbd`) hit it
  immediately. Workaround until this is fixed upstream: don't set
  `RestartedBy` on an `Oneshot` service — let its `.timer` pick up
  resource changes on its next natural fire instead of forcing an
  immediate synchronous restart. `restic-backup.service` had its
  `RestartedBy` removed for this reason; resource changes to it now take
  up to 24h (next timer fire) to apply instead of immediately. See
  `specs/plans/issue-31-oneshot-wait-timeout.md`.
- **That plan's "next timer fire" assumption was wrong — `RemainAfterExit=
  yes` makes a `.timer`'s daily fire a permanent no-op after the first
  successful run (BUG-004).** `restic-backup.container.gotmpl`'s generated
  unit has `Type=oneshot` + `RemainAfterExit=yes`, so once the service
  completes successfully it settles into `active (exited)` and stays
  there. `OnCalendar` timers fire by issuing a plain `systemctl start`,
  and `start` on an already-`active` unit is a no-op in systemd — it does
  NOT re-run `ExecStart`. So the *first* successful run permanently
  blocks the timer from ever triggering the service again, until
  something else cycles the unit through `inactive` (a manual `restart`,
  or materia auto-restarting because the `.container.gotmpl` itself
  changed — quadlet `.container` changes always restart their service,
  independent of `RestartedBy`). Symptom: `systemctl status
  restic-backup.timer` shows `Trigger: n/a` forever after the first run,
  even though `list-timers`/`LastTriggerUSec` shows it firing correctly
  on schedule — the fire happens, but silently does nothing. Caught
  2026-07-15 when healthchecks.io flagged both `restic-backup-bow` and
  `restic-backup-flutterina` down: bow's last real run was stuck at
  2026-07-14 17:48 (~22h stale), flutterina's at 2026-07-14 05:00 (~35h
  stale) — in both cases the *only* thing that had been producing real
  runs recently was an incidental `.container.gotmpl` image-digest bump,
  not the timer's own daily schedule. `sudo systemctl restart
  restic-backup.service` immediately fixes a stuck instance (confirmed:
  the backup ran AND `NextElapseUSecRealtime` correctly repopulated with
  the next day's midnight) but is a same-day workaround only — the next
  `OnCalendar` fire hits the identical no-op once that run also settles
  into `active (exited)`. **Do not just drop `RemainAfterExit=yes` to
  fix this** — tried on 2026-07-15 (commit `0b2bb11`, reverted as
  `0620018`) and it broke `materia-update` entirely, on every future
  run: materia's default "quadlet `.container` file changed → always
  restart" health check unconditionally expects the restarted service
  to end up `active`, and that check is NOT covered by `Oneshot = true`
  (that flag only skips a *different* code path — the one issue #31
  patched around). Confirmed live on flutterina: `FATA Execute in
  unhealthy state: Expected map[restic-backup.service:active], Actual
  map[restic-backup.service:inactive]`, which blocks reconciliation of
  every component on the host, not just restic-backup — and recurs on
  every future `restic-backup.container.gotmpl` change (i.e. every
  Renovate digest bump), so it's strictly worse than the original bug.
  **Fix (implemented 2026-07-16):** neither known materia restart
  trigger can correctly restart a `Type=oneshot` service without
  materia either timing out (issue #31's wildcard-sentinel bug, for
  `RestartedBy`-triggered restarts) or asserting a wrong expected state
  (this bug's default-trigger path, confirmed in
  `pkg/planner/planner.go`'s `resourceActionWithMetadata` — it never
  consults `Oneshot` at all for a plain-image container, unlike the
  adjacent `.build`/`.image` branch). Both are materia Go source bugs,
  not fixable in this repo. Workaround: `Settings.NoRestart = true` on
  `components/restic-backup/MANIFEST.toml` disables materia's default
  `.container`/`.pod`-change auto-restart entirely for the component,
  and a new `restic-backup-trigger.service` (`[[Services]]` entry,
  `Stopped = true` — installed but never auto-started; safe because
  materia classifies it as `ResourceTypeService`, which the buggy
  Container/Pod-only auto-restart loop never touches) whose only job is
  `systemctl restart restic-backup.service` is what `restic-backup.timer`
  now targets, instead of the service directly. `systemctl restart`
  (unlike `start`) always re-executes `ExecStart` regardless of the
  target's current state, fixing the original no-op unconditionally.
  Trade-off: ALL `restic-backup` resource changes (not just the
  `RestartedBy`-covered ones #31 already accepted this for) now take up
  to 24h to apply instead of immediately — a real behavior change, since
  quadlet-file changes previously applied immediately (the only thing
  that had been keeping backups running pre-fix). Pending live
  verification across 2+ real unattended timer fires before considered
  fully closed — see
  `specs/plans/issue-38-restic-backup-timer-noop.md` and
  `specs/bugs/BUG-004-restic-backup-timer-remainaftereexit-noop.md`.

- **CI can publish more than one image per push — verify the digest against
  the run, not just "the latest one someone noted down".** A digest
  recorded during earlier epic work turned out to belong to a CI run
  triggered before the final application logic was merged (a different,
  earlier run on the same day, from a commit that touched the Dockerfile
  but not yet the full wrapper source). The image pulled and ran — podman
  pull succeeded, exit code was 0 — but the binary was empty of the
  expected logic (confirmed with `strings` on the extracted binary; zero
  matches for expected log-message literals). `gh run list
  --workflow=<file>` + `gh run view <id> --log` (grep for
  `containerimage.digest`) is the authoritative source for "which digest
  came from which commit" — don't infer it from run ordering or timestamps
  alone.
- **A CI "gate" step only proves what it actually invokes.**
  `restic-backup-image.yml`'s original gate steps ran `restic version` and
  `ssh -V` to prove those binaries are static and functional — neither
  ever invoked `/usr/local/bin/wrapper` (the actual entrypoint). This is
  why a stale/incomplete wrapper build was able to publish successfully:
  the gate tested the dependencies, not the product (issue #19, found via
  e01s11's local `podman run` + `strings`-on-the-binary check). **Fixed:**
  a third gate step now runs the image with no env vars set and asserts a
  non-zero exit plus the exact `RESTIC_REPOSITORY is required` message —
  cheap (no real backend/secrets needed) but proves the wrapper's actual
  Go logic executed, not just its static dependencies. Verified locally
  against both the old stale digest (correctly fails the new gate) and the
  corrected one (passes) before landing.

- **Per-host settings for a role-assigned component: use
  `[Hosts.<name>.Extensions.<component>.Defaults]` + `{{ if exists }}`,
  not a vault key and not `Overrides`.** `beszel-agent` reports bow's LVM
  data disk through an optional `Volume=` to
  `/extra-filesystems/data__Data` (beszel's extra-disk convention:
  `statfs` gives usage, the mount's real device gives I/O, and the part
  after `__` is the display name). The line is wrapped in
  `{{ if exists "beszelExtraFilesystem" }}`. Only bow sets that value, in
  `MANIFEST.toml`. Confirmed against materia v0.7.2 source:
  `ExtendComponentManifests` *merges* an Extension's `Defaults` into the
  component's, and the template vars are vault attributes merged over
  those Defaults, so `exists` sees the value. `Overrides` *replaces* the
  whole `Defaults` table instead. A bare `{{ .key }}` on a host that lacks
  the key is the fatal `map has no entry for key` error (see `baseDomain`
  above); `exists` avoids it. Never put `:z`/`:Z` on a whole-data-disk
  bind: that recursively relabels every library on it. **An extra disk
  also needs an explicit root device (`beszelRootFilesystem` →
  `FILESYSTEM=`).** A rootful podman container's `/etc/hosts` comes from
  tmpfs, so the agent can't find root and picks the *most active* I/O
  device instead. On bow that was the data LV, so the root entry
  overwrote the Data entry under the same `dm-N` key. The agent logged
  `Detected disk name=Data`, then the hub never got it. The only clue is
  a `Using most active device for root I/O` warning. **Flatcar's btrfs
  partitions show up as useless "storage pools"** (OEM plus an unlabeled
  one, ~1 GB each, KB used): the agent lists everything under
  `/sys/fs/btrfs` and has no filter for it. `beszelHideBtrfsPools` adds
  `Mask=/sys/fs/btrfs` (quadlet, podman ≥4.6), so the agent sees no btrfs.
  Opt-in per host, so a host with real btrfs keeps its pools. See
  `specs/plans/beszel-agent-extra-filesystem.md`.

- **A repo change that requires a host-side manual step will not happen,
  and on materia it fails the *entire* host, not just its component.**
  Commit `612f8c3` changed the postgres pin from v17.11 to v18.6 and
  described the required `podman volume rm systemd-mediamanager-db` only
  in its commit body and a quadlet comment. Nothing in the repo performs
  a volume wipe — materia installs the new `.container` and restarts the
  service, full stop. Postgres then refused the v17 `PGDATA` (`FATAL:
  database files are incompatible with server`), crash-looped to
  `start-limit-hit`, and `materia-update` aborted its plan on the
  dependent step (`WARN 0/8 steps completed` / `FATA service
  mediamanager-postgres.service unhealthy`) — so bow received **no**
  commits at all from 2026-09-18 to 2026-09-21, silently missing the
  BUG-009 pod fix, the #113 healthchecks, and every Renovate bump. This
  is the third instance of the same all-or-nothing blast radius already
  recorded above (a missing attribute key aborting every component; the
  `RemainAfterExit` revert's wrong expected state doing the same), so
  treat any single-component breakage on a materia host as a
  whole-host outage until proven otherwise. Rules: (1) a change needing
  destructive host-side state surgery is not a Renovate-class change —
  make the step executable (a `mise` task, or a runbook line actually
  run per host) rather than prose; (2) after landing one, verify the
  next `materia-update` on each affected host actually succeeded —
  `journalctl -u materia-update.service | grep FATA` is the check.
  See `specs/bugs/BUG-010-mediamanager-postgres-major-bump-volume-not-wiped.md`.
- **A failed materia run can lose another component's restart for good.**
  materia installs files early in its plan and restarts services late. If
  the run aborts in between, the new file stays on disk, and the next run
  sees no diff, so it never plans that restart again. The service keeps
  running the old unit (`systemctl` warns `changed on disk, the version
  systemd has loaded is outdated`). Caught on bow on 2026-11-18 (#196): the
  09:04 run installed `audiobookshelf.container` without its `Podcasts`
  mount (step 1) and planned `Restart Service audiobookshelf.service`
  (step 11). An unrelated db-dump file then aborted it at 8/14 steps. The
  green 09:10 run planned only db-dump steps, and audiobookshelf kept the
  old bind mount. After any failed run, list the restarts it planned and
  never reached: `journalctl -u materia-update.service --since <run> -o cat
  | grep 'Restart Service'`. Run them by hand with `systemctl daemon-reload
  && systemctl restart <svc>`. Then confirm the live state, e.g. `podman
  inspect … {{range .Mounts}}`, not just the file on disk. Also, `grep -c`
  for a path in a quadlet can match a comment that mentions it. Match
  `^Volume=` instead.

## Renovate coverage

The [Renovate config](../../renovate.json5) extends the native Quadlet manager to match `*.container.gotmpl`, uses regex versioning for Pangolin's `ee-` prefix, and tracks badger through GitHub tags and the manifest pin. It also tracks the Materia image pins in the Butane and adopted-host installers. Updating an installed host still requires `mise materia:sync-image`. [Renovate documentation](https://docs.renovatebot.com)

For the `known_hosts` and `hcPingURL` pairings, see [Restic and database backups](restic-backup.md).

[SOPS](https://github.com/getsops/sops) · [age](https://github.com/FiloSottile/age)
