# Wrapper Entrypoint Binary (e01s04) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stub `main.go` at `images/restic-backup/wrapper/` with the real backup-job driver: a static Go binary that pings monitoring, bootstraps the restic repo if needed, runs `restic backup` + `restic forget --prune`, and pings success/failure — all configured via environment variables.

**Architecture:** Single-file `package main` Go program, stdlib only (`os`, `os/exec`, `net/http`, `fmt`, `log`, `strings`, `time`, `strconv`). No cgo, no shell — `os/exec` calls the `restic` binary directly (restic itself execs `ssh` for the sftp backend, but the wrapper never touches `ssh`). The wrapper is the `ENTRYPOINT` of the scratch image built by e01s03/#17 (already published); this story only changes the source, then a follow-up image rebuild picks it up via the existing CI workflow.

**Tech Stack:** Go 1.23 (stdlib only, `CGO_ENABLED=0`), Podman (local compile + run verification via a containerized golang since no local Go toolchain), restic (for the end-to-end local-repo verification, run inside a container since restic isn't installed on the workstation).

## Global Constraints

- Static Go binary, stdlib only — `CGO_ENABLED=0 go build`, no cgo, no `os/exec` of a shell. `os/exec` calls `restic` directly. This is what makes it runnable as the `ENTRYPOINT` of a `FROM scratch` image with no shell.
- Source lives at `images/restic-backup/wrapper/` — owned by the CI image build context (e01s03/#17), NOT under `components/`. A wrapper change triggers a new image build before the component sees it; that's the GitOps flow.
- No tests — this is a small infra-only binary. Verification is the local `podman run` in e01s11, not a unit test suite. Do NOT add a test file; the spec's "No tests" risk is explicit.
- Ping URL shape MUST match `provisioning/templates/hetzner.bu` lines 128-129: `${HC_PING_URL}/${HC_SLUG}/start` (start), `${HC_PING_URL}/${HC_SLUG}` (success), `${HC_PING_URL}/${HC_SLUG}/fail` (failure). `HC_PING_URL` has no trailing slash; `HC_SLUG` is appended directly.
- Ping failures MUST NOT abort the backup — log to stderr and continue. Same discipline as the materia-update quadlet's `-` prefix.
- No local Go toolchain on the workstation by design — compile checks use a throwaway `podman run` against `golang:1.23-alpine` (the same base image the Dockerfile uses), not a local `go build`.
- No local `restic` either — the end-to-end local-repo verification runs restic inside a container.
- Focused semantic commits, Conventional Commits style, subject ≤50 chars (AGENTS.md "Development conventions").

---

### Task 1: Env config + ping function

**Files:**
- Modify: `images/restic-backup/wrapper/main.go` (replace the stub)
- Keep: `images/restic-backup/wrapper/go.mod` (already exists from e01s03 Task 1, unchanged — module `github.com/kitten-lily/materia/images/restic-backup/wrapper`, go 1.23)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a `config` struct populated from env vars, and a `ping(url string)` function that later tasks call as `pingStart()`, `pingEnd(success bool)`. Task 2 and Task 3 call `ping`; Task 3 calls `config`.

- [ ] **Step 1: Replace the stub with the package header, config struct, and env reader**

```go
// images/restic-backup/wrapper/main.go
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// config holds all wrapper configuration, read from environment variables.
// No file-based config — the .container.gotmpl (e01s05) controls everything.
type config struct {
	repository  string   // RESTIC_REPOSITORY — e.g. sftp:u630269-sub1@host:./path
	password    string   // RESTIC_PASSWORD — repo encryption password (from podman secret, env type)
	hostname    string   // RESTIC_HOST / hostname — used as --tag and --host
	hcPingURL   string   // HC_PING_URL — base URL, no trailing slash
	hcSlug      string   // HC_SLUG — per-server slug
	keepDaily   int      // KEEP_DAILY (default 7)
	keepWeekly  int      // KEEP_WEEKLY (default 4)
	keepMonthly int      // KEEP_MONTHLY (default 6)
	backupPaths []string // BACKUP_PATHS — space-separated host paths to back up
}

func loadConfig() config {
	c := config{
		repository:  os.Getenv("RESTIC_REPOSITORY"),
		password:    os.Getenv("RESTIC_PASSWORD"),
		hostname:    os.Getenv("RESTIC_HOST"),
		hcPingURL:   strings.TrimRight(os.Getenv("HC_PING_URL"), "/"),
		hcSlug:      os.Getenv("HC_SLUG"),
		keepDaily:   envInt("KEEP_DAILY", 7),
		keepWeekly:  envInt("KEEP_WEEKLY", 4),
		keepMonthly: envInt("KEEP_MONTHLY", 6),
		backupPaths: envPaths("BACKUP_PATHS"),
	}
	if c.hostname == "" {
		c.hostname, _ = os.Hostname()
	}
	return c
}

// envInt reads an env var as an int, returning def on missing/invalid.
func envInt(key string, def int) int {
	s := os.Getenv(key)
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}

// envPaths splits a space-separated env var into a slice.
func envPaths(key string) []string {
	s := os.Getenv(key)
	if s == "" {
		return nil
	}
	return strings.Fields(s)
}
```

- [ ] **Step 2: Add the ping function with retry/backoff**

Append to `main.go`:

```go
// ping sends an HTTP GET to url. It retries up to 3 times with exponential
// backoff (1s, 2s, 4s). Ping failures are logged to stderr and NEVER returned
// as fatal — same discipline as the materia-update quadlet's "-" prefix
// (provisioning/templates/hetzner.bu lines 128-129): a monitoring outage must
// not block a backup.
func ping(url string) {
	const maxAttempts = 3
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		client := &http.Client{Timeout: 10 * time.Second}
		resp, err := client.Get(url)
		if err != nil {
			lastErr = err
		} else {
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				return
			}
			lastErr = fmt.Errorf("ping %s: HTTP %d", url, resp.StatusCode)
		}
		if attempt < maxAttempts {
			time.Sleep(time.Duration(1<<(attempt-1)) * time.Second)
		}
	}
	log.Printf("ping (non-fatal): %s: %v", url, lastErr)
}

// pingStart sends the /start ping before the backup job.
func pingStart(c config) {
	if c.hcPingURL == "" || c.hcSlug == "" {
		return
	}
	ping(c.hcPingURL + "/" + c.hcSlug + "/start")
}

// pingEnd sends the success or fail ping after the backup job.
func pingEnd(c config, success bool) {
	if c.hcPingURL == "" || c.hcSlug == "" {
		return
	}
	url := c.hcPingURL + "/" + c.hcSlug
	if !success {
		url += "/fail"
	}
	ping(url)
}
```

- [ ] **Step 3: Add a temporary main() so the file compiles**

Append a placeholder `main` (Task 3 replaces it with the real wiring):

```go
func main() {
	_ = loadConfig()
}
```

- [ ] **Step 4: Verify gofmt and vet via a containerized build**

Run: `podman run --rm -v "$PWD/images/restic-backup/wrapper:/src:z" -w /src docker.io/library/golang:1.23-alpine sh -c 'gofmt -l . && go vet ./... && go build -o /dev/null .'`
Expected: `gofmt -l` prints nothing (already formatted), `go vet` reports no issues, `go build` exits 0.

- [ ] **Step 5: Commit**

```bash
git add images/restic-backup/wrapper/main.go
git commit -m "feat(wrapper): add env config and monitoring ping"
```

---

### Task 2: Restic command runners (ensureRepo, runBackup, runForget)

**Files:**
- Modify: `images/restic-backup/wrapper/main.go` (append the three runner functions)

**Interfaces:**
- Consumes: `config` struct from Task 1.
- Produces: `ensureRepo(c config) error`, `runBackup(c config) int` (exit code), `runForget(c config) int` (exit code). Task 3's `main()` calls all three.

- [ ] **Step 1: Add a shared restic-command helper**

Append to `main.go` (in the imports, add `"os/exec"`; then the helper):

```go
// resticCmd builds an exec.Command for restic with the wrapper's env
// (so RESTIC_REPOSITORY, RESTIC_PASSWORD, etc. propagate) and stdout/stderr
// wired to the wrapper's own stdout/stderr so restic's output is visible
// in journalctl.
func resticCmd(args ...string) *exec.Cmd {
	cmd := exec.Command("restic", args...)
	cmd.Env = os.Environ()
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd
}
```

(Also add `"os/exec"` to the import block from Task 1.)

- [ ] **Step 2: Add ensureRepo**

```go
// ensureRepo runs `restic cat config`; if it exits non-zero, runs `restic init`.
// This makes the first run on a fresh Storage Box self-bootstrapping — no
// manual init step.
func ensureRepo(c config) error {
	if err := resticCmd("cat", "config").Run(); err != nil {
		log.Printf("restic cat config failed (%v), initializing repository", err)
		return resticCmd("init").Run()
	}
	return nil
}
```

- [ ] **Step 3: Add runBackup**

```go
// runBackup runs `restic backup <paths> --tag <hostname> --host <hostname>`
// and returns the restic exit code.
func runBackup(c config) int {
	args := append([]string{"backup"}, c.backupPaths...)
	args = append(args, "--tag", c.hostname, "--host", c.hostname)
	cmd := resticCmd(args...)
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		return 1
	}
	return 0
}
```

- [ ] **Step 4: Add runForget**

```go
// runForget runs `restic forget --prune --keep-daily N --keep-weekly N
// --keep-monthly N` and returns the restic exit code.
func runForget(c config) int {
	cmd := resticCmd(
		"forget", "--prune",
		"--keep-daily", strconv.Itoa(c.keepDaily),
		"--keep-weekly", strconv.Itoa(c.keepWeekly),
		"--keep-monthly", strconv.Itoa(c.keepMonthly),
	)
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		return 1
	}
	return 0
}
```

- [ ] **Step 5: Verify it still compiles and vets clean**

Run: `podman run --rm -v "$PWD/images/restic-backup/wrapper:/src:z" -w /src docker.io/library/golang:1.23-alpine sh -c 'gofmt -l . && go vet ./... && go build -o /dev/null .'`
Expected: no gofmt output, no vet errors, build exits 0.

- [ ] **Step 6: Commit**

```bash
git add images/restic-backup/wrapper/main.go
git commit -m "feat(wrapper): add restic init, backup, forget runners"
```

---

### Task 3: main() wiring + local verification

**Files:**
- Modify: `images/restic-backup/wrapper/main.go` (replace the temporary `main` from Task 1 with the real job wiring)

**Interfaces:**
- Consumes: `loadConfig`, `pingStart`, `pingEnd` (Task 1); `ensureRepo`, `runBackup`, `runForget` (Task 2).
- Produces: the complete wrapper binary. A follow-up CI image rebuild (via the existing `restic-backup-image` workflow, triggered by pushing this change to `main`) picks up the new wrapper into the published image.

- [ ] **Step 1: Replace the temporary main() with the real job wiring**

Replace the placeholder `func main() { _ = loadConfig() }` from Task 1 with the code below. Note: `os.Exit` does NOT run deferred functions, so we extract the job into `runJob` and call `pingEnd` explicitly before `os.Exit` — do NOT use a `defer` for `pingEnd` (a naive `defer func(){ pingEnd(c, success) }()` would be silently skipped on the `os.Exit` path).

```go
func main() {
	c := loadConfig()

	if c.repository == "" {
		log.Fatal("RESTIC_REPOSITORY is required")
	}
	if c.password == "" {
		log.Fatal("RESTIC_PASSWORD is required")
	}
	if len(c.backupPaths) == 0 {
		log.Fatal("BACKUP_PATHS is required")
	}

	pingStart(c)

	exitCode := runJob(c)
	pingEnd(c, exitCode == 0)
	os.Exit(exitCode)
}

// runJob runs the backup job (ensureRepo -> backup -> forget) and returns
// the combined exit code. Separated from main so pingEnd always runs after
// it, regardless of the exit path (os.Exit skips defers).
func runJob(c config) int {
	if err := ensureRepo(c); err != nil {
		log.Printf("ensureRepo failed: %v", err)
		return 1
	}
	backupExit := runBackup(c)
	forgetExit := runForget(c)
	if backupExit == 0 && forgetExit == 0 {
		return 0
	}
	log.Printf("backup exit %d, forget exit %d", backupExit, forgetExit)
	return backupExit | forgetExit
}
```

- [ ] **Step 2: Verify gofmt, vet, and static build**

Run: `podman run --rm -v "$PWD/images/restic-backup/wrapper:/src:z" -w /src docker.io/library/golang:1.23-alpine sh -c 'gofmt -l . && go vet ./... && CGO_ENABLED=0 go build -o /out/wrapper . && file /out/wrapper'`
Expected: no gofmt output, no vet errors, build exits 0, `file` output contains `statically linked`.

- [ ] **Step 3: End-to-end local verification against a real restic repo**

This is the spec's Verification Script step 4-5, adapted for no-local-restic. Run the wrapper inside a container that has both `restic` and the compiled `wrapper` binary, against a throwaway local filesystem repo (no SSH needed):

```bash
# Build the wrapper binary into a temp dir (reuse the compile from step 2's container)
podman run --rm -v "$PWD/images/restic-backup/wrapper:/src:z" -v "$PWD/.worktrees/restic-backup-ci-image-build/.superpowers/sdd/wrapper-out:/out:z" -w /src docker.io/library/golang:1.23-alpine sh -c 'CGO_ENABLED=0 go build -o /out/wrapper .'

# Run the wrapper against a local restic repo, with restic available via the published image's restic binary.
# Use the golang image + install restic into it for the test (restic isn't in golang:alpine by default).
podman run --rm \
  -v "$PWD/.worktrees/restic-backup-ci-image-build/.superpowers/sdd/wrapper-out/wrapper:/usr/local/bin/wrapper:z" \
  -v "$PWD/.worktrees/restic-backup-ci-image-build/.superpowers/sdd/testrepo:/testrepo:z" \
  -v "$PWD/.worktrees/restic-backup-ci-image-build/.superpowers/sdd/testdata:/data:z" \
  -e RESTIC_REPOSITORY=/testrepo/repo \
  -e RESTIC_PASSWORD=test \
  -e HC_PING_URL=http://localhost:9999 \
  -e HC_SLUG=test \
  -e BACKUP_PATHS=/data \
  docker.io/library/golang:1.23-alpine sh -c 'CGO_ENABLED=0 go install github.com/restic/restic/cmd/restic@v0.18.0 && /usr/local/bin/wrapper'

# Verify a snapshot exists in the test repo:
podman run --rm \
  -v "$PWD/.worktrees/restic-backup-ci-image-build/.superpowers/sdd/testrepo:/testrepo:z" \
  -e RESTIC_REPOSITORY=/testrepo/repo \
  -e RESTIC_PASSWORD=test \
  docker.io/library/golang:1.23-alpine sh -c 'CGO_ENABLED=0 go install github.com/restic/restic/cmd/restic@v0.18.0 && restic snapshots'
```

Expected: the wrapper run logs ping failures (localhost:9999 isn't serving — those are non-fatal, proving the "ping failures don't abort" requirement), runs `restic init` + `restic backup` + `restic forget --prune` successfully, and exits 0. The snapshots command lists at least one snapshot.

Clean up the test artifacts afterward:
```bash
rm -rf "$PWD/.worktrees/restic-backup-ci-image-build/.superpowers/sdd/wrapper-out" \
       "$PWD/.worktrees/restic-backup-ci-image-build/.superpowers/sdd/testrepo" \
       "$PWD/.worktrees/restic-backup-ci-image-build/.superpowers/sdd/testdata"
```

- [ ] **Step 4: Confirm the full CI image still builds with the real wrapper**

Run: `podman build -t restic-backup-test --build-arg resticVersion=v0.18.0 --build-arg opensshVersion=9.9p1 images/restic-backup/`
Expected: exits 0 (the Dockerfile's `COPY wrapper/` + `go build` step now compiles the real wrapper, not the stub).

Run: `podman run --rm --entrypoint /usr/local/bin/wrapper restic-backup-test 2>&1 | head -5`
Expected: the wrapper runs and exits non-zero with a "RESTIC_REPOSITORY is required" or similar message (no env set) — NOT a "not found" / "no such file" / binary-loading error. This proves the real wrapper is the image's entrypoint and loads correctly in scratch.

- [ ] **Step 5: Commit**

```bash
git add images/restic-backup/wrapper/main.go
git commit -m "feat(wrapper): wire backup job and verify end-to-end"
```

---

## Notes carried from the spec's Risks section

- **`ssh` in PATH inside the container** — the wrapper doesn't manage `PATH`; e01s05's `.container.gotmpl` sets `Environment=PATH=/usr/bin:/usr/local/bin` if needed so restic's sftp backend can exec `ssh`. Not this story's concern.
- **No tests** — the spec's Risks section explicitly says verification is the local `podman run` in e01s11, not a unit test suite. Do not add a `*_test.go` file; the per-task reviewer would (correctly) flag speculative test scaffolding as out-of-scope over-building.
- **Wrapper change triggers a new image build** — this story changes the source at `images/restic-backup/wrapper/`; the published GHCR image still has the old stub until a push to `main` re-runs the `restic-backup-image` workflow. Whether to push that rebuild is a separate decision (the plan for e01s05 / the epic close-out handles it); this story's scope is the source + local verification only.
