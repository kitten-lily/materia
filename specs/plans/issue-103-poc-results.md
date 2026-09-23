# POC results — Issue #103: Proton Drive CLI as a backup destination

**issue:** https://github.com/kitten-lily/materia/issues/103
**test plan:** `specs/plans/issue-103-poc-test-plan.md`
**parent plan:** `specs/plans/issue-103-proton-drive-backup.md`
**harness:** `mise poc:proton-drive --section runtime|restic|auth|portability|upload|clean`
**run:** 2026-09-23, workstation (`adora`), rootless podman, CLI 0.8.0
(`cli-drive@0.8.0+06e8c605`, SDK `js@0.21.0+06e8c605`), restic 0.19.1.
No production host touched, no Proton account used.

## Scope of this run

The test plan splits into what needs a real Proton account and what
doesn't. **Everything that does not need an account has been executed**
— and that turned out to include the load-bearing headless-auth
question, which the plan assumed needed a human (it does not: the CLI
prints the sign-in URL *before* any account interaction, so the flow's
shape is observable without signing in).

| Section | Needs account | Status |
|---|---|---|
| A — runtime/libc (open Q #4) | no | **done** |
| A′ — credential stores | no | **done** (new, not in the plan) |
| A″ — auth URL shape (open Q #1) | no | **done** (new — answers the go/no-go gate) |
| D1 — restic copy/incremental/prune | no | **done** |
| B — interactive `auth login` | **yes** | **done** (run 2) |
| C — session portability (open Q #2) | **yes** | blocked on a re-export — see finding 6 |
| D2 — `filesystem upload` skip check | **yes** | harness ready, not run |
| Open Q #3 (session lifetime), #5–#7 (quota, throttling, cost) | **yes** | not answerable here |

## Findings

### 1. The musl build is NOT static — `scratch` is out, `alpine` + `libstdc++` works

The test plan's optimistic reading ("a musl build fits this repo's
`scratch` convention *if* it's statically linked") does not hold.

```
proton-drive-linux-x64-musl: ELF 64-bit LSB executable, x86-64, dynamically linked,
  interpreter /lib/ld-musl-x86_64.so.1, not stripped
NEEDED  libstdc++.so.6
NEEDED  libc.musl-x86_64.so.1
NEEDED  libgcc_s.so.1
```

- **`FROM scratch` → fails**: `exec container process (missing dynamic
  library?) /proton-drive: No such file or directory`.
- **`alpine:3.22` bare → fails**: `Error loading shared library
  libstdc++.so.6` + ~50 relocation errors.
- **`alpine:3.22` + `apk add libstdc++` → works**:
  `Proton Drive CLI cli-drive@0.8.0+06e8c605`, exit 0.

So a `proton-backup` image cannot reuse `images/restic-backup/`'s
`scratch` base. Cost of the fallback: the POC image is **144 MB**
(115 MB binary + alpine + libstdc++) versus restic-backup's current
~25 MB. That is the single largest deviation from this repo's
minimal-image convention, and it is unavoidable with this CLI —
the binary embeds a Bun runtime.

`readelf -d` shows **no** `libsecret`/`dbus` `NEEDED` entries, so the
keychain store is loaded lazily; a container without libsecret is not
blocked from using another store (confirmed empirically below).

### 2. Credential stores behave as hoped — `pass` is viable, `keychain` is not

Unauthenticated `filesystem list /my-files` in a container, per store:

| `PROTON_DRIVE_CREDENTIALS_STORE` | output | exit |
|---|---|---|
| `keychain` (default) | `Failed to load session from secrets (…): libsecret not available` | 1 |
| `pass` (installed, uninitialised) | `You need to login first` | 1 |
| `pass` (binary absent) | `Failed to load session from pass (ensure pass is installed and gpg-agent can decrypt): Executable not found in $PATH: "pass"` | 1 |
| `unsafe_file` | `You need to login first` | 1 |

- Default `keychain` is confirmed unusable in a container, as the parent
  plan assumed — but it fails *loudly*, not silently.
- `pass` degrades cleanly to "not logged in" when the store is empty,
  i.e. it is a real code path, not a stub.
- **Exit codes are correct** (1 on every failure class: missing store,
  no session, bad path, unknown command). Proton's "predictable exit
  codes" marketing holds; a wrapper can branch on them.

### 3. Headless auth: out-of-band sign-in IS supported (open question #1 — answered)

This was the parent plan's explicit go/no-go gate. Run in a container
with **no `DISPLAY`, no browser binary, stdin `/dev/null`**:

```
$ proton-drive auth login
Sign in in your browser. Keep the terminal open. Waiting for authentication to complete...
Open following URL manually (can be on another device) if browser did not open automatically:
https://account.proton.me/desktop/login?app=drive&pv=3#payload=0%3A…%3Acli-drive
```

The CLI prints a completable-elsewhere URL and polls — the
`gh auth login` device-flow pattern, verbatim ("can be on another
device"). **A headless VPS can be authenticated over SSH**: run
`auth login`, open the URL on a laptop, finish sign-in there.

Caveats this run cannot settle: whether the polled session is bound to
the requesting host in any way (needs Section C), and how long it lives
(open question #3 — needs elapsed time plus an account).

### 4. `--conflict-strategy` does not exist — the plan's upload commands are wrong

CLI 0.8.0's actual surface:

```
filesystem upload [-f STRATEGY] [-d STRATEGY] [-t] localPath... parentPath
  -f, --file-conflict-strategy    create-new-revision | rename | replace | skip
  -d, --folder-conflict-strategy  merge | rename | replace | skip
  -t, --skip-thumbnails
```

Three corrections to the parent plan and the test-plan comment:

1. There is no `--conflict-strategy` and no `--verbose` on the
   subcommand — it is `-f`/`-d`, and `-v`/`-j` are *global* options
   (`proton-drive -v filesystem upload …`).
2. The final argument is a **parent folder**, not a destination path.
   `upload <local>/data /my-files/poc` creates `/my-files/poc/data`.
   Folders need `-d merge` or the second run conflicts at the folder
   level before it ever reaches file comparison.
3. `replace` **trashes** the remote file rather than deleting it —
   trashed data still consumes quota until `filesystem empty-trash`.
   Relevant for open question #5 (quota headroom).

Also documented in `upload --help`, and a meaningful de-risking of the
design: *"Files with the same content are automatically skipped."*
Content-level dedupe is built in, independent of the conflict strategy.
Still needs the Section D2 empirical check against a real account.

### 5. restic side of the design holds — with one gap the plan missed

All of this ran locally, no Proton account (`--section restic`):

- `restic copy` into a second repo with a **different password** works
  (defence-in-depth item 3 of the parent plan is fine). Note restic
  ≥0.17 changed the flags: destination is `-r`, source is
  `--from-repo`/`--from-password-file`. `--repo2`/`--password-file2`
  as written in the test plan is deprecated and **fails** with
  `Fatal: wrong password or no key found`.
- **Re-copy with no new source data is a true no-op**: zero new files
  in the destination repo → zero to upload. The "free incremental"
  assumption holds at the restic layer.
- **A new snapshot produces only additions**: 2 new `data/` packs, 1 new
  `index/`, 1 new `snapshots/` file. Every pre-existing file's sha256 is
  unchanged across three copy runs — so `-f skip` never has to make a
  correctness decision about a mutated file.
- **Gap: retention does not propagate to an upload-only remote copy.**
  `forget --keep-last 1 --prune` on the local repo *deleted* 1 pack, *deleted*
  2 index files and wrote 1 replacement, and *deleted* 1 snapshot file. An
  upload-only mirror keeps all of them. Simulated that mirror (union of
  pre- and post-prune state) and checked it:
  - `restic check --read-data` → `no errors were found`, with a
    non-critical `pack … contained in several indexes` warning.
  - `restic restore latest` → restores correctly.
  - **but** `restic snapshots` on the mirror lists the *forgotten*
    snapshot as well: 11 files on the mirror vs 7 in the local repo
    after a single prune cycle.

  So the Drive copy stays restorable, but it never shrinks and never
  honours retention. Over months that is unbounded growth against a
  fair-use-policed quota. Phase 2 needs an explicit delete step
  (`filesystem delete` the packs/indexes/snapshots prune removed, then
  `empty-trash`) — the parent plan's "upload `data/` with skip +
  overwrite the control paths" design has no deletion half.

### 6. Interactive `auth login` works; transplanting the session needs two GPG fixes

Run 2 (2026-09-23, real Proton account, `--section auth`): sign-in
completed from the printed URL on another machine, and the CLI stored
exactly one artefact —
`~/.password-store/ch.proton.drive/drive-sdk-cli/auth-session.gpg`
(plus `.gpg-id`). So the session really is a single GPG-encrypted file,
which is the shape the parent plan's "ship it as a materia secret"
design assumed.

Moving that store to a second container failed twice, both times for
GPG-plumbing reasons rather than anything Proton-side. Both are fixed in
the harness and both are provisioning-relevant for Phase 2:

1. **Stale keyboxd lock files travel with a copied `.gnupg`.** Taring
   the GPG home verbatim carries `public-keys.d/pubring.db.lock` and
   `.#lk*`; in the destination every gpg call then loops on
   `database_open … waiting for lock (held by N)` for ~30s and fails
   with `keydb_search failed: Operation timed out` → `No secret key`.
   Delete `*.lock`, `.#lk*`, `S.*` and `random_seed` before packing.
2. **`gpg --batch --quick-generate-key` without `--passphrase ""`
   produces a passphrase-protected key.** It looks fine while a TTY is
   around (the login container had one), then every non-interactive
   decrypt dies with `public key decryption failed: Not a tty` because
   the agent launches pinentry. `--passphrase ""` at generation time is
   required; `--export-secret-keys` and `--passwd` both refuse to fix it
   after the fact under `--batch` (`No passphrase given`,
   `invalid option "--new-passphrase"`), so the key must be generated
   correctly or regenerated.

With both fixes, a full export → fresh-container import → `pass show`
round trip decrypts non-interactively (verified with a stand-in secret,
no Proton account involved). The real session blob from run 2 predates
fix 2, so open question #2 still needs one more `--section auth` +
`--section portability` pass to be answered against actual Drive.


## What is still open

- **Section B/C/D2** — need a human with a real Proton account. The
  harness runs them in throwaway containers with a throwaway GPG key;
  see `mise poc:proton-drive --section auth` (then `portability`, then
  `upload`).
- **Open Q #3 (session lifetime)** — cannot be answered in one session;
  needs a login, then a re-test days/weeks later.
- **Open Q #5/#6/#7 (quota, fair-use throttling, cost)** — account-side
  facts, plus an upload of a realistically-sized repo slice.

## Recommendation (unchanged direction, sharper risks)

Nothing found here is a no-go. The two gates the parent plan called out
are both passed or survivable:

- headless auth: **passed** — out-of-band URL, no co-located browser;
- runtime: **passed with a cost** — no `scratch`, `alpine` + `libstdc++`,
  ~144 MB image.

Two new items Phase 2 must carry that the plan did not have: the
missing deletion half of the mirror (finding 5) and the corrected CLI
invocation (finding 4).
