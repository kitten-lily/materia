# Investigation — Issue #103: Proton Drive CLI as a backup destination

**issue:** https://github.com/kitten-lily/materia/issues/103
**risk:** P2 (additive/parallel investigation — the existing
`restic-backup` → Storage Box path is not touched until a recommended
design is approved and its own rollout is gated)
**epic:** standalone

## Directive

User: investigate replacing/complementing the current Storage Box
(Hetzner SFTP) backup scheme with **Proton Drive**, used **directly
through the Proton Drive CLI — not through restic**. This rules out:
restic's own backend abstraction pointed at Proton Drive, and the
unofficial `rclone` ProtonDrive backend (whether wrapped by restic's
`rclone` backend or invoked standalone). The Proton Drive CLI binary is
the only supported transport considered here.

## Current baseline (unchanged by this issue)

`components/restic-backup/`:

- Go wrapper (`images/restic-backup/wrapper/main.go`) running as a
  `scratch`-based container (`images/restic-backup/Dockerfile`) with
  fully static `restic` + `ssh` binaries, no shell, no libc.
- `RESTIC_REPOSITORY=sftp://...` — a per-server subaccount
  (`backups/<server>`) on one shared Hetzner Storage Box (`bx11`, 1 TB,
  `provisioning/storageboxes/backup/storagebox.toml`), reached over the
  static `ssh` client with a hand-mounted `mode=0400` secret key
  (BUG-002) and a bind-mounted `ssh_config`/`known_hosts` (BUG-001).
- `BACKUP_PATHS=/var/lib/materia/components /var/lib/containers/storage/volumes`
  — component data + named podman volumes, **not** the large read-only
  media libraries on `bow` (movies/TV/music/books live on a separate LVM
  data disk, outside this scope today).
- Oneshot, `Type=oneshot` + `RemainAfterExit=yes`, triggered by
  `restic-backup.timer` → `restic-backup-trigger.service` (the
  `systemctl restart` indirection from BUG-004, working around a
  materia upstream bug with oneshot-service restart triggers).
- Retention: `KEEP_DAILY=7`/`KEEP_WEEKLY=4`/`KEEP_MONTHLY=6`, `restic forget --prune`.
- Dead-man's-switch pings to healthchecks.io per host
  (`restic-backup-<hostname>`).
- Hard-won: **7 documented bugs** (BUG-001 wrong ssh_config path,
  BUG-002 secret mount mode, BUG-003 key corruption via manual paste,
  BUG-004 oneshot timer no-op — pending live verification per #38,
  BUG-005 missing bind-mount dir, plus two more referenced in AGENTS.md).
  This component earned its stability the hard way; nothing here is
  removed or altered without its own explicit, separately-verified plan.

## Investigation: Proton Drive CLI

Confirmed against `proton.me/support/drive-cli`,
`proton.me/business/drive/cli`, the announcement blog post
(`proton.me/blog/proton-drive-cli`, published 2026-06-09), and the
authoritative `cli/README.md` in `github.com/ProtonDriveApps/sdk`.

### What it is

- **GA, official**, released 2026-06-09, built on the Proton Drive SDK
  (same engine as the official Drive apps), single self-contained
  binary (Bun-embedded runtime — "no runtime to install"), available for
  Linux (`x64` and `x64-baseline` for pre-AVX2 CPUs), macOS, Windows.
- Explicitly marketed for exactly this use case: "Encrypted backups —
  Upload archives from servers, laptops, or cron jobs" and "Scripted
  workflows — Run Drive operations from any shell, container, or CI
  runner with JSON output and predictable exit codes"
  (proton.me/business/drive/cli).
- Command surface at GA: `auth login`/`logout`, `filesystem
  list`/`upload`/`download` (+ trash), `sharing status`/`invite`/`set-url`,
  `version`, `help`. `--json`/`-j` for machine-readable output,
  `--verbose`/`-v` for logs. Interactive shell mode if invoked with no
  arguments.
- **Explicitly not a sync engine**: "only the applications include a
  full synchronization engine that runs in the background... a way to
  achieve many goals from a lightweight scripting environment," not "a
  full replacement." `filesystem upload`'s `--conflict-strategy`
  (skip/overwrite/rename) is the only diffing primitive — whole-file
  presence/absence at a given path, no binary/rsync diffing of changed
  files.
- **Fair use, not a hard API quota**: "only upload or download what has
  actually changed — don't reupload the same files repeatedly...
  accounts that generate unusually high traffic are temporarily
  throttled." No published numeric limit to design against mechanically.

### Authentication (the central operational question)

- `proton-drive auth login` — **browser-based**, no password on the
  command line. The README states this as a hard requirement ("A Proton
  account and browser access for sign-in").
- Session persistence is controlled by `PROTON_DRIVE_CREDENTIALS_STORE`:
  - `keychain` (default) — OS secret store (Keychain/Credential
    Manager/libsecret). A `scratch` or minimal server container has none
    of these running (no D-Bus session, no GNOME Keyring) — **not
    usable as-is** in this repo's containers.
  - **`pass`** — a GPG-encrypted entry in a
    [password-store](https://www.passwordstore.org/) tree
    (`ch.proton.drive/drive-sdk-cli/auth-session`). This is the
    realistic headless option: `pass` is just GPG + a git-friendly file
    tree, no keyring daemon required. **New key-management surface** —
    a GPG private key must exist wherever the CLI runs, distinct from
    this repo's existing SOPS+age scheme.
  - `unsafe_file` — plaintext `auth-session.json`. README says "do not
    use, for testing only." Not acceptable for production per this
    repo's own security posture (materia's own SOPS/age handling exists
    specifically to avoid plaintext secrets at rest).
- **Unconfirmed, blocking question**: does `auth login`'s browser flow
  support out-of-band completion (a URL/code printed to the terminal,
  completed on *any* device's browser, polled to completion — the
  device-authorization-grant pattern `gh auth login`/`docker login`
  use), or does it require a browser co-located with the CLI process?
  Neither the support page nor the CLI README states this explicitly.
  **Must be tested by hand** before any further design commits to a
  specific bootstrap flow. If it's strictly co-located, the workaround
  is: run `auth login` once on a workstation with a browser, then
  provision the resulting `pass` GPG-encrypted session data to the
  target host as a new kind of secret (parallel to, but distinct from,
  today's age-key provisioning) — this is a real design choice covered
  in "Open questions" below.
- **Unconfirmed**: session lifetime / refresh behavior. If the stored
  session needs periodic *interactive* re-authentication, a headless
  timer-triggered job cannot renew it unattended, and the whole design
  degrades to "someone re-logs-in by hand every N weeks" — a real
  operational cost that must be weighed against Storage Box's
  fire-and-forget SSH-key auth.

### Runtime compatibility

- The CLI's Linux builds are Bun-compiled standalone executables.
  `restic-backup`'s image is `scratch` (no libc at all — confirmed via
  the Dockerfile: `CGO_ENABLED=0`, static `restic`/`ssh`, `FROM scratch`).
  **Unconfirmed** whether the Bun-built `proton-drive` binary runs in a
  libc-less `scratch` environment or needs glibc (Bun typically targets
  glibc distros; the `x64-baseline` variant note is about CPU
  instruction sets, not libc). If it needs glibc, it cannot be added to
  today's `scratch` image directly — a new sibling image with a fuller
  base (e.g. `debian-slim`) would be needed instead. **Must be tested**:
  `podman run --rm -v ./proton-drive:/proton-drive:ro,z gcr.io/distroless/static /proton-drive version` (or similar) before assuming either outcome.

### rclone's separate ProtonDrive backend (why it's excluded)

For completeness, not because it's being pursued: `rclone`'s
independent (unofficial, predates the June 2026 CLI) ProtonDrive
backend is documented by both rclone and restic forum threads as
"experimental," with reports of Proton throttling/blocking rclone's API
access outright (2024). The user's direction to go "directly through
proton drive cli, not restic" already excludes this path; it's noted
here only so a future reader doesn't re-propose it as a shortcut.

## Recommended architecture (pending the open questions below)

**Complement, not replace** — a new, independent sibling component,
not a modification of `restic-backup`:

1. **Leave `restic-backup` exactly as-is.** SFTP → Storage Box stays
   primary and unmodified. Zero risk to hard-won, already-fragile
   infrastructure.
2. **New component, e.g. `proton-backup`**, its own quadlet/timer,
   `After=restic-backup.service` (runs once the primary backup has
   completed, not concurrently):
   - `restic copy --from-repo <storage-box-repo> --repo <local-repo>` —
     replicates snapshots not yet present in a **local** repo (named
     volume, e.g. `proton-backup-repo.volume`, so materia's
     data-dir-drift rule doesn't schedule it for deletion). This reads
     already-backed-up data from the existing Storage Box repo (restic
     decrypts once via its own protocol) rather than re-walking
     `BACKUP_PATHS` a second time — cheaper than a second independent
     `restic backup` invocation, and keeps the Proton-side repo
     versioned/deduplicated/encrypted by restic exactly like the primary.
   - `proton-drive filesystem upload <local-repo>/data
     /my-files/backups/<hostname>-restic/data --conflict-strategy skip`
     — restic pack files under `data/` are content-addressed and
     immutable once written, so `skip` naturally uploads only new files
     (satisfies Proton's fair-use "only upload what changed" guidance
     with zero custom diffing logic).
   - A second, always-`overwrite` upload of the small mutable control
     paths (`config`, `keys/`, `snapshots/`, `index/`) — cheap, and
     needed because unlike `data/` these can be rewritten.
   - Same dead-man's-switch ping discipline as `restic-backup`
     (`HC_SLUG=proton-backup-<hostname>`), same `-`-prefixed
     non-fatal-ping convention.
3. **Distinct restic password** for the local/Proton-side repo (a new
   `protonResticPassword` secret, not reusing `resticPassword`) —
   defense in depth: compromising one repo's key shouldn't unlock the
   other, same reasoning already applied elsewhere in this repo's
   secret design.
4. **Proton auth session as a new secret shape.** Whatever the Phase 0
   research spike finds for headless auth, the session material
   (`pass` GPG-encrypted store contents, or the GPG private key +
   pre-populated store) needs a provisioning path — likely a new
   `Secrets` entry holding an opaque blob, mounted read-only, parallel
   to today's `storageBoxSshKey` pattern but for a fundamentally
   different credential type (a whole GPG-backed store, not a single
   SSH key).

### Why complement, not replace

- Storage Box is proven: 7 fixed bugs, live on both hosts, dead-man's-switch
  monitored. Proton Drive CLI is 3 months old (GA June 2026) at
  investigation time — no production backup track record anywhere yet,
  unconfirmed headless-auth story, unconfirmed runtime compatibility,
  unconfirmed fair-use throttling behavior under real backup-sized
  traffic. Betting the *only* off-site copy on it would be a strictly
  worse risk profile than today.
- Complementing it turns this into genuine 3-2-1 (local podman
  volumes → Storage Box → Proton Drive, three independent failure
  domains, two independent cloud accounts/vendors) rather than a
  lateral swap.
- If Proton Drive proves itself over a defined soak period, *replacing*
  Storage Box becomes a much lower-risk follow-up decision made with
  real operational evidence instead of upfront — this plan explicitly
  leaves that door open without committing to it now.

## Open questions (research spike — before any component is built)

1. **Headless auth completion mechanism** — hands-on test: run
   `proton-drive auth login` over SSH with no local browser and observe
   whether it prints a completable-elsewhere URL or hard-fails. This is
   the single most important unknown; it decides whether the whole
   design is viable without a manual bootstrap-and-copy step.
2. **Session portability** — if login must happen on a workstation, can
   the resulting `pass` store entry be exported/copied to a server
   verbatim (it's just GPG-encrypted files under a known path) and does
   the CLI accept it there unmodified?
3. **Session lifetime** — does the stored session expire, and if so, on
   what cadence, and does the CLI refresh it silently or require
   interactive re-auth?
4. **Runtime/libc compatibility** — does the Bun-built Linux binary run
   under musl/`scratch`, or does it require glibc (determines whether
   this folds into a `scratch` sibling image or needs a heavier base)?
5. **Storage quota** — what is the current Proton plan's Drive quota,
   and how much headroom exists against the corpus size on both hosts
   (`/var/lib/materia/components` + named podman volumes)? Needs the
   user to check their account — not discoverable from this repo.
6. **Fair-use throttling in practice** — no published numeric limit;
   needs an empirical test uploading a realistically-sized restic repo
   slice and observing whether/when throttling kicks in.
7. **Cost** — is Drive CLI usage covered by the existing Proton plan
   (same account already used for Pass via `fnox`/`pass-cli`), or does
   meaningful backup volume require a plan upgrade?

## Phased plan (once Phase 0 questions are answered favorably)

### Phase 0 — Research spike

Answer all 7 open questions above by hand, on a workstation first (not
a production host). **Go/no-go gate**: if headless auth (#1/#2) turns
out to require a fundamentally manual, non-automatable re-auth cadence,
or the Bun binary doesn't run in any container-friendly Linux
environment (#4), stop here and report back rather than forcing a
worse design.

**Verify:** written findings for all 7 questions, posted as a comment
on issue #103.

### Phase 1 — Proof of concept (workstation/throwaway, no production host)

- Manually run `proton-drive auth login`, confirm session persists via
  `PROTON_DRIVE_CREDENTIALS_STORE=pass`.
- Manually run `restic copy` from a throwaway local repo into a second
  local repo, then `proton-drive filesystem upload` it, confirm files
  land correctly in Drive and `--conflict-strategy skip` behaves as
  expected on a second run with no new data.

**Verify:** a real, small restic repo's pack files appear in Proton
Drive via `filesystem list`; a second upload run with no new snapshots
uploads zero files (confirms the free incremental behavior the
recommended design depends on).

### Phase 2 — `proton-backup` component

- New `components/proton-backup/` — manifest, container/timer quadlets,
  a new wrapper image (base TBD per Phase 0 finding #4) running `restic
  copy` + `proton-drive filesystem upload` in sequence, healthchecks.io
  ping discipline matching `restic-backup`'s.
- New secrets: `protonResticPassword`, the Proton auth session blob
  (shape TBD per Phase 0 findings #1-3).
- `MANIFEST.toml`: assign to a role or both hosts directly, mirroring
  `restic-backup`'s assignment.

**Verify:** `materia plan`/`materia update` installs cleanly on a
non-production test path first if available; dry-run confirms the
generated quadlets are well-formed before touching `flutterina`/`bow`.

### Phase 3 — Pilot on one host

- Deploy to **one** host first (recommend `bow` — lower blast radius
  than the edge node), run for a defined soak period, confirm
  successful daily runs, dead-man's-switch pings green, and Drive
  storage usage tracks expectations from Phase 0 finding #5.

**Verify:** `systemctl status proton-backup.timer` active on `bow`; a
full week of green healthchecks.io pings; `proton-drive filesystem
list` shows the expected, growing-then-plateauing (once initial catch-up
completes) set of files.

### Phase 4 — Roll out to `flutterina`

- Same rollout, second host, after Phase 3's soak period passes clean.

**Verify:** both hosts report healthy `proton-backup.timer` runs; both
independently discoverable under their own path prefix in Drive
(`/my-files/backups/<hostname>-restic/`).

## Out of scope

- Any change to `restic-backup`, its retention policy, or its Storage
  Box repository — this issue is purely additive.
- Backing up the large read-only media libraries on `bow` (not in
  today's `BACKUP_PATHS`; not expanded by this issue).
- A "replace Storage Box entirely" decision — explicitly deferred to a
  future, separately-evidenced follow-up if Proton Drive proves itself
  over Phase 3/4's soak periods.
- Building/maintaining a fork of the Proton Drive CLI, or vendoring its
  source build — the official pre-built binary is used as-is (the
  `CLI_APP_VERSION_NAME`/`x-pm-appversion` customization requirement in
  the SDK README only applies to *rebuilding* the CLI, which this plan
  does not do).

## Risks

- **Auth model may not fit unattended automation at all.** This is the
  dominant risk — if Phase 0 finds no out-of-band completion path and
  sessions need periodic interactive renewal, the entire "cron job"
  pitch on Proton's own marketing page doesn't hold up for a fully
  unattended fleet. Mitigation: Phase 0 is a hard go/no-go gate before
  any component code is written.
- **New credential-management surface.** A GPG-backed `pass` store is a
  second secret-management scheme alongside this repo's existing
  SOPS+age vault, with its own provisioning/rotation story. Mitigation:
  scope it narrowly (one secret blob, one component) rather than
  generalizing a new pattern prematurely.
- **Proton Drive CLI is very new (GA ~3 months old at investigation
  time).** Undiscovered bugs, behavior changes, or policy tightening
  (e.g. the "fair use" throttling could become stricter without much
  notice, mirroring Proton's historical rclone throttling) are
  plausible. Mitigation: complement-not-replace keeps Storage Box as
  the safety net regardless of how Proton Drive behaves.
- **`restic copy` doubles the read/decrypt cost** of already-backed-up
  data on every run (even though it avoids re-walking the source
  filesystem). For today's `BACKUP_PATHS` size this is likely
  negligible, but should be watched if `BACKUP_PATHS` ever grows.
- **Runtime incompatibility could force a heavier image** than the
  existing minimal `scratch` design this repo has consistently
  preferred (restic-backup, all Minimus images). Mitigation: Phase 0
  finding #4 settles this before any Dockerfile is written; if a
  heavier base is unavoidable, document why rather than silently
  drifting from the established minimal-image convention.
