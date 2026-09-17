# Local proof-of-concept test plan — Issue #103: Proton Drive CLI

**issue:** https://github.com/kitten-lily/materia/issues/103
**parent plan:** `specs/plans/issue-103-proton-drive-backup.md` (Phase 0 —
Research spike, Phase 1 — Proof of concept)
**scope:** answer the 7 open questions in the parent plan with concrete,
runnable commands, on a workstation — never a production host
(flutterina/bow), never real backup data.

## Split: what runs unattended vs. what needs a human with a real Proton account

Proton Drive auth is a real third-party identity — sign-in must be done
by a human with their own Proton account and a real browser session.
**Section A (runtime/musl compatibility, open question #4) needs no
Proton account and can run standalone.** **Sections B–E (auth, session
portability, POC upload) need a human at the keyboard** for the
`auth login` step; everything else in those sections is copy-pasteable
once that one step is done.

---

## Section A — Runtime/libc compatibility (open question #4)

**New finding, not in the parent plan:** the official download matrix
(`proton.me/download/drive/cli/index.html`, checked this session) ships
a **musl-linked Linux build** (`linux/x64-musl`, `linux/arm64-musl`) in
addition to the standard glibc `linux/x64`/`linux/x64-baseline` builds.
The SDK README's "Download the CLI" section doesn't mention this
variant — only the AVX2 baseline distinction — so it's easy to miss.
This directly de-risks open question #4: a musl build fits this repo's
existing minimal-base convention (`restic-backup`'s `scratch` image,
all Minimus images) far better than a glibc build would, *if* it's
statically linked (or link-compatible with a minimal musl-libc image
like `alpine`). Still needs the empirical check below — Bun-compiled
"musl" builds aren't guaranteed to be fully static.

```bash
mkdir -p /tmp/proton-drive-poc && cd /tmp/proton-drive-poc

# Pin to whatever release proton.me/download/drive/cli currently lists —
# checked this session: 0.8.0 (2026-08-13). Re-check the version/checksum
# table before running; do not assume 0.8.0 is still current.
VERSION=0.8.0
curl -fsSL -o proton-drive-linux-x64-musl \
  "https://proton.me/download/drive/cli/${VERSION}/linux-x64-musl/proton-drive"
curl -fsSL -o proton-drive-linux-x64 \
  "https://proton.me/download/drive/cli/${VERSION}/linux-x64/proton-drive"

# Verify against the SHA-512 checksums published on the download page
# (copy the exact values for the version you fetched — do not reuse
# ones from an older investigation).
sha512sum proton-drive-linux-x64-musl proton-drive-linux-x64
chmod +x proton-drive-linux-x64-musl proton-drive-linux-x64

# Inspect the ELF — is the musl build statically linked or does it need
# a dynamic loader?
file proton-drive-linux-x64-musl
file proton-drive-linux-x64
```

**Test 1 — true `scratch` (matches `restic-backup`'s Dockerfile exactly):**

```bash
cat > Dockerfile.scratch <<'EOF'
FROM scratch
COPY proton-drive-linux-x64-musl /proton-drive
ENTRYPOINT ["/proton-drive"]
EOF
podman build -t proton-drive-poc-scratch -f Dockerfile.scratch .
podman run --rm proton-drive-poc-scratch version
podman run --rm proton-drive-poc-scratch help
```

**Test 2 — fallback, minimal musl base (only if Test 1 fails):**

```bash
podman run --rm -v ./proton-drive-linux-x64-musl:/proton-drive:ro,Z \
  docker.io/library/alpine:3.22 /proton-drive version
```

**Pass/fail:**
- Test 1 succeeds → musl build is fully static, drop straight into a
  `scratch` sibling image exactly like `restic-backup`'s, zero base-image
  compromise. Best outcome.
- Test 1 fails (`exec format error` / "no such file or directory" — the
  classic missing-dynamic-loader symptom under `scratch`) but Test 2
  succeeds → needs a minimal libc base (`alpine`), still far lighter than
  a glibc distro image, acceptable fallback per the parent plan's risk
  note on runtime incompatibility.
- Both fail → capture the exact error, re-check whether `libsecret`/
  `dbus` (mentioned as runtime deps by third-party install guides,
  **not** the official README, for the default `keychain` credential
  store) are hard-linked even when `PROTON_DRIVE_CREDENTIALS_STORE=pass`
  is set — test by running `version`/`help` only (no credential-store
  code path touched) vs. `auth login` (does touch it) separately to
  isolate which command actually needs those libraries. If confirmed
  hard-linked regardless of credential store, this is a real blocker
  for a `scratch`/minimal-alpine container and forces the "heavier base
  image" fallback the parent plan's risks section already flags.

**Also record:** binary size (`ls -la`) — the CLI's known baseline is
~118MB embedded-Bun; confirm this repo's image-size expectations (every
other component here is small, static, single-purpose) still make sense
before committing to Phase 2.

---

## Section B — Headless auth completion (open questions #1, #2, #3)

**Requires a human with a real Proton account.** Do not attempt this
with a shared/test account unless you have one you're comfortable
authenticating a throwaway CLI session against — `auth login` binds a
real Proton session.

**First**, disambiguate a naming collision already in this repo:
`mise.toml`'s `pass-cli` tool is **Proton Pass** (`protonpass/pass-cli`,
used by `fnox` for secret injection) — an unrelated product. The
`PROTON_DRIVE_CREDENTIALS_STORE=pass` option needs the **unrelated**
[password-store](https://www.passwordstore.org/) (`pass` command, GPG-backed
flat-file store) — not installed on this workstation, not a mise-pinned
tool today. Install it separately for this test (e.g. system package
manager: `pacman -S pass` / `apt install pass`) — do not confuse it with
`pass-cli`.

```bash
cd /tmp/proton-drive-poc

# One-time: throwaway GPG key + pass store, scoped to this test only —
# never reuse a real personal/production GPG key for a POC.
gpg --batch --quick-generate-key 'proton-drive-poc <poc@invalid.test>' default default never
GPG_KEY_ID=$(gpg --list-secret-keys --with-colons 'proton-drive-poc' | awk -F: '/^sec/{print $5; exit}')
pass init "$GPG_KEY_ID"

export PROTON_DRIVE_CREDENTIALS_STORE=pass
```

**Test 1 — is there a local browser to try launching?** Run once as-is:

```bash
./proton-drive-linux-x64 auth login
```

Observe: does it print a URL and a short code and then poll (the
`gh auth login`/`docker login` device-authorization pattern — this is
the outcome that makes the whole "cron job on a headless VPS" design
viable), or does it immediately try to spawn a local browser
(`xdg-open`/`$BROWSER`) and hang/fail without one?

**Test 2 — force a true headless environment** (this workstation likely
has a GUI/browser available, which would mask a real headless failure).
Repeat inside a podman container with no `DISPLAY`, no browser binary,
network egress only:

```bash
podman run -it --rm \
  -e PROTON_DRIVE_CREDENTIALS_STORE=pass \
  -e HOME=/root \
  -v ./proton-drive-linux-x64:/usr/local/bin/proton-drive:ro,Z \
  docker.io/library/alpine:3.22 sh -c '
    apk add --no-cache gnupg pass >/dev/null &&
    gpg --batch --quick-generate-key "proton-drive-poc <poc@invalid.test>" default default never &&
    GPG_KEY_ID=$(gpg --list-secret-keys --with-colons "proton-drive-poc" | awk -F: "/^sec/{print \$5; exit}") &&
    pass init "$GPG_KEY_ID" &&
    proton-drive auth login
  '
```

**Pass/fail (this is the parent plan's hard go/no-go gate):**
- Prints an out-of-band URL/code completable from any device, polls to
  completion → headless automation is viable. Proceed with Phase 1.
- Requires a co-located browser with no out-of-band fallback → the
  bootstrap-elsewhere-then-copy-`pass`-store workaround (parent plan's
  "Open questions" #2) becomes mandatory, not optional. Test that
  workaround explicitly before proceeding — see Section C.
- Errors outright with no usable path in a true headless shell → report
  back to issue #103, this may be a hard no-go per the parent plan's
  go/no-go gate.

**Also observe (open question #3):**

```bash
# After a successful login, inspect session lifetime signals — do NOT
# assume; read whatever the CLI actually reports.
./proton-drive-linux-x64 auth login --help 2>&1 | grep -iE 'expir|refresh|session'
./proton-drive-linux-x64 --json filesystem list /my-files 2>&1
# Wait/re-test after a meaningful interval (hours, not the same session)
# to see whether a second command silently refreshes or demands
# re-auth. Cannot be fully answered same-day — note as a follow-up if so.
```

---

## Section C — Session portability (open question #2, only if Section B's Test 1 requires a co-located browser)

```bash
# On the machine where auth login succeeded (has a browser):
pass show ch.proton.drive/drive-sdk-cli/auth-session > /tmp/proton-drive-poc/session-export.gpg-armor 2>&1 \
  || pass find proton-drive  # confirm exact pass entry path/name first if the above 404s

ls -la ~/.password-store/ch.proton.drive/ 2>&1  # confirm on-disk layout

# On a second, throwaway environment simulating a headless server (a
# fresh podman container is enough — do NOT test this against a real
# production host):
podman run -it --rm \
  -v ~/.password-store:/root/.password-store:ro,Z \
  -v ./proton-drive-linux-x64:/usr/local/bin/proton-drive:ro,Z \
  -e PROTON_DRIVE_CREDENTIALS_STORE=pass \
  -e HOME=/root \
  docker.io/library/alpine:3.22 sh -c '
    apk add --no-cache gnupg pass >/dev/null &&
    proton-drive filesystem list /my-files
  '
```

**Pass/fail:** the second, session-copied environment can list `/my-files`
without a fresh `auth login` → session material is portable as a
GPG-encrypted blob (confirms the "bootstrap on a workstation, ship the
`pass` store to the server as a new secret kind" fallback design in the
parent plan is viable). Fails → session is bound to something beyond
the `pass` entry itself (device fingerprint, keyring-adjacent state) —
report back, this changes the whole credential-provisioning design.

---

## Section D — Proof of concept: `restic copy` + `filesystem upload` (Phase 1)

Only after Section B (or B+C) confirms a working, non-interactive-enough
auth path. Needs `restic` on the test workstation (not currently
installed here or pinned in `mise.toml` — install via system package
manager for this throwaway test; not a repo change).

```bash
mkdir -p /tmp/proton-drive-poc/{src,repo-a,repo-b}
echo "poc file $(date -u)" > /tmp/proton-drive-poc/src/file1.txt

export RESTIC_PASSWORD=poc-test-password-not-real

# repo-a simulates the existing Storage Box repo; repo-b simulates the
# new local Proton-side repo the parent plan's design calls for.
restic -r /tmp/proton-drive-poc/repo-a init
restic -r /tmp/proton-drive-poc/repo-a backup /tmp/proton-drive-poc/src

restic -r /tmp/proton-drive-poc/repo-b init
restic -r /tmp/proton-drive-poc/repo-a copy \
  --repo2 /tmp/proton-drive-poc/repo-b --password-file2 <(printf '%s' "$RESTIC_PASSWORD")

# Upload the immutable pack data first (skip = free incremental once
# packs are content-addressed and already present)...
./proton-drive-linux-x64 filesystem upload \
  /tmp/proton-drive-poc/repo-b/data /my-files/proton-drive-poc/data \
  --conflict-strategy skip --verbose
# ...then the small mutable control paths, always overwritten.
for p in config keys snapshots index; do
  ./proton-drive-linux-x64 filesystem upload \
    "/tmp/proton-drive-poc/repo-b/$p" "/my-files/proton-drive-poc/$p" \
    --conflict-strategy overwrite --verbose
done

./proton-drive-linux-x64 filesystem list /my-files/proton-drive-poc/data --json
```

**Verify the free-incremental claim (the design's core assumption):**

```bash
# No new snapshot — re-run the same upload, confirm zero files transferred.
./proton-drive-linux-x64 filesystem upload \
  /tmp/proton-drive-poc/repo-b/data /my-files/proton-drive-poc/data \
  --conflict-strategy skip --verbose
# Then add a second snapshot and re-run, confirm only the new pack
# files upload.
echo "second poc file $(date -u)" > /tmp/proton-drive-poc/src/file2.txt
restic -r /tmp/proton-drive-poc/repo-a backup /tmp/proton-drive-poc/src
restic -r /tmp/proton-drive-poc/repo-a copy \
  --repo2 /tmp/proton-drive-poc/repo-b --password-file2 <(printf '%s' "$RESTIC_PASSWORD")
./proton-drive-linux-x64 filesystem upload \
  /tmp/proton-drive-poc/repo-b/data /my-files/proton-drive-poc/data \
  --conflict-strategy skip --verbose
```

**Pass/fail:** first re-run (no new data) uploads 0 files; second re-run
(one new snapshot) uploads only the new pack file(s), not a re-upload of
everything — confirms `--conflict-strategy skip` gives the free
incremental behavior the whole design leans on.

---

## Section E — Cleanup (every section)

```bash
# Drive-side: remove the POC path so it doesn't linger in the real account.
./proton-drive-linux-x64 filesystem delete /my-files/proton-drive-poc --recursive 2>&1 \
  || echo "check: does 'delete' need --permanent, or does it go to trash first? verify with filesystem list before assuming clean"
./proton-drive-linux-x64 auth logout

# Local:
rm -rf /tmp/proton-drive-poc
pass rm -rf ch.proton.drive 2>&1  # only the throwaway POC pass store entries
gpg --batch --yes --delete-secret-and-public-key "proton-drive-poc <poc@invalid.test>" 2>&1
podman rmi proton-drive-poc-scratch 2>&1
```

**Do not skip the Drive-side cleanup** — unlike the podman/systemd tests
in #26/#32/#38, this POC touches a real external account with real
(if small) storage usage.

---

## Reporting back

Post to issue #103: pass/fail for each section, the exact `file` output
from Section A (static vs. dynamic musl binary), the exact behavior
observed in Section B Test 2 (out-of-band URL vs. hard browser
requirement — this is the load-bearing finding), and whether Section D's
free-incremental re-upload check passed. This is enough to either green-light
Phase 2 (build `components/proton-backup/`) or close out #103 as a
no-go with a documented reason.
