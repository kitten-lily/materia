# Story e01s04 — Wrapper entrypoint binary

**type:** feat
**risk:** P1
**context:** infra
**epic:** e01-restic-backup
**source:** https://github.com/kitten-lily/materia/issues/2
**blocks_on:** e01s03 (CI image build — the wrapper source lives in that build context at `images/restic-backup/wrapper/`)

## Context

Scratch has no shell, so a first-party Go binary is the container's
`ENTRYPOINT` and drives the whole backup job with `os/exec` (no shell needed).
It runs: monitoring "start" ping → `restic init` (if needed) → `restic backup`
→ `restic forget --prune` → monitoring "success"/"fail" ping. All configuration
arrives via environment variables (set by the `.container.gotmpl` from e01s05).
SSH is invoked by restic as a subprocess (restic's sftp backend execs `ssh`),
so the wrapper never calls `ssh` directly — but it must ensure the environment
is set so restic's `ssh` invocation works (see e01s05 for the mount/flag wiring).

**Source location:** the wrapper source lives at
`images/restic-backup/wrapper/` — owned by the CI image build (e01s03/#17) so
the build context is self-contained. This story owns the Go *behavior*; e01s03
owns compiling it into the image. #2's Materia component never touches the
wrapper source.

## Requirements

#### ADDED: Wrapper reads all config from environment

The wrapper reads, at minimum:
- `RESTIC_REPOSITORY` — repository target (e.g. `sftp:u630269-sub1@...:./path`)
- `RESTIC_PASSWORD` — repository encryption password (from a podman secret, env type)
- `RESTIC_HOST` / hostname tag — used as `--tag` and `--host` for restic
- `HC_PING_URL` — healthchecks.io-style base URL (no trailing slash)
- `HC_SLUG` — per-server slug appended to the ping URL
- `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY` — retention counts (optional, sane defaults)
- `BACKUP_PATHS` — space-separated host paths to back up (default: the two bind-mounted paths)

No file-based config. All env, so the `.container.gotmpl` controls everything.

#### ADDED: Wrapper pings monitoring on start and on success/fail

HTTP GET to `${HC_PING_URL}/${HC_SLUG}/start` before the job, and to
`${HC_PING_URL}/${HC_SLUG}` (success) or `${HC_PING_URL}/${HC_SLUG}/fail`
(failure) after. Ping failures MUST NOT abort the backup — log and continue,
same discipline as the `materia-update` quadlet's `-` prefix in the .bu.

#### ADDED: Wrapper ensures the repository is initialized

Run `restic cat config`; if it exits non-zero, run `restic init`. This makes
the first run on a fresh Storage Box self-bootstrapping — no manual init step.

#### ADDED: Wrapper runs backup then forget --prune

`restic backup <paths> --tag <hostname> --host <hostname>` then
`restic forget --prune --keep-daily <N> --keep-weekly <N> --keep-monthly <N>`.
The combined exit status (backup | forget) determines the success/fail ping.

#### ADDED: Wrapper is a static Go binary with no shell dependencies

`CGO_ENABLED=0 go build`. Uses only the Go standard library (+ `net/http` for
pings). No cgo, no shell exec — `os/exec` calls `restic` directly. This is what
makes it runnable as the `ENTRYPOINT` of a scratch image.

## Steps

1. Create `images/restic-backup/wrapper/main.go` with a `package main` that
   reads the env vars above (with `os.Getenv` + sane defaults) and defines the
   job as functions: `pingStart`, `ensureRepo`, `runBackup`, `runForget`,
   `pingEnd`. (e01s03 step 5 may have created a minimal stub `main.go` to make
   the image build testable — replace it with the real implementation here.)
   → verify: `gofmt -l images/restic-backup/wrapper/main.go` prints nothing (formatted).

2. Implement `ping(url)` using `net/http` with a short timeout (10s) and
   `--retry`-equivalent (3 attempts, backoff). Ping errors are logged to stderr
   and never returned as fatal. → verify: `grep -c 'net/http' images/restic-backup/wrapper/main.go` ≥ 1.

3. Implement `ensureRepo`: `exec.Command("restic", "cat", "config")` — if
   `Run()` returns non-nil, run `exec.Command("restic", "init")`. Propagate
   env (`cmd.Env = os.Environ()`). → verify: `grep -q 'restic.*init\|restic.*cat.*config' images/restic-backup/wrapper/main.go`.

4. Implement `runBackup`: build `exec.Command("restic", "backup", paths...,
   "--tag", hostname, "--host", hostname)`, wire stdout/stderr to `os.Stdout`/`os.Stderr`,
   return the exit code. → verify: `grep -q '"backup"' images/restic-backup/wrapper/main.go`.

5. Implement `runForget`: `exec.Command("restic", "forget", "--prune",
   "--keep-daily", keepDaily, ...)` with the same wiring. → verify: `grep -q 'forget.*prune' images/restic-backup/wrapper/main.go`.

6. Wire `main()`: pingStart → ensureRepo → runBackup → runForget →
   pingEnd(success | fail based on combined exit). Exit with the combined
   status so systemd sees a non-zero exit on failure (the timer + `Oneshot`
   service manifest flag handle the systemd-side semantics). → verify: `grep -q 'os.Exit' images/restic-backup/wrapper/main.go`.

7. Ensure a `go.mod` (`module wrapper; go 1.23`) exists (e01s03 step 5 may
   have created it; if not, create it here) so the CI image build compiles.
   → verify: `test -f images/restic-backup/wrapper/go.mod`.

8. Local compile check: `cd images/restic-backup/wrapper && CGO_ENABLED=0 go build -o /tmp/wrapper-test . && file /tmp/wrapper-test | grep -q 'statically linked'`. → verify: command exits 0.

9. Re-run the CI image build (or a local `podman build` from e01s03 step 7)
   with the real wrapper in place — confirm `podman run --rm --entrypoint
   /usr/local/bin/wrapper restic-backup-test` runs (it'll fail on missing env,
   but it must not crash on a binary-loading error). → verify: `podman run --rm --entrypoint /usr/local/bin/wrapper restic-backup-test 2>&1 | grep -qv 'not found\|no such file'`.

## Verification Script (Step-by-Step)

1. `cd images/restic-backup/wrapper && go vet ./...` — no vet errors.
2. `CGO_ENABLED=0 go build -o /tmp/wrapper-test .` — builds static.
3. `file /tmp/wrapper-test` — "statically linked".
4. `RESTIC_REPOSITORY=/tmp/testrepo RESTIC_PASSWORD=test HC_PING_URL=http://localhost:9999 HC_SLUG=test BACKUP_PATHS=/tmp /tmp/wrapper-test` — runs against a local restic repo (no ssh), ping failures are logged but non-fatal, exit 0 if backup+forget succeed.
5. Inspect `/tmp/testrepo` — restic initialized and a snapshot present (`restic -r /tmp/testrepo snapshots`).

## Out of scope

- The Containerfile build step (e01s03) — here we only write the source + go.mod.
  e01s03 compiles it into the image.
- The `.container.gotmpl` env wiring (e01s05).
- Real Storage Box SSH connectivity (e01s11).

## Risks

- **Restic sftp backend needs `ssh` in `$PATH`.** In the scratch image `ssh` is
  at `/usr/bin/ssh` (standard location, copied by the Containerfile). Restic
  execs `ssh` by name, so `/usr/bin` must be in `PATH` inside the container.
  The `.container.gotmpl` (e01s05) sets `Environment=PATH=/usr/bin:/usr/local/bin`
  if needed — the wrapper itself does not manage `PATH`.
- **Ping URL shape.** The `materia-update` quadlet uses `${HC_PING_URL}/<slug>/start`
  and `${HC_PING_URL}/<slug>` (or `/fail`). The wrapper MUST use the same shape
  for consistency. Confirmed against `provisioning/templates/hetzner.bu` lines
  128–129.
- **Source lives under `images/restic-backup/wrapper/`** (not `components/`),
  so the CI image build context is self-contained. #2's component only
  references the published image. This means a wrapper change triggers a new
  image build (e01s03) before the component sees it — that's the GitOps flow.
- **No tests.** This is a small, infra-only binary. Verification is the local
  `podman run` in e01s11, not a unit test suite. If the wrapper grows logic,
  revisit.
