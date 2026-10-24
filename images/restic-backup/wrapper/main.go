package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
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

// runJob runs the backup job (unlock -> ensureRepo -> backup -> forget) and
// returns the combined exit code. Separated from main so pingEnd always runs
// after it, regardless of the exit path (os.Exit skips defers).
func runJob(c config) int {
	if code := removeStaleLocks(); code != 0 && code != exitRepoMissing {
		log.Printf("restic unlock failed: exit %d", code)
		return code
	}
	if code := ensureRepo(); code != 0 {
		log.Printf("ensureRepo failed: exit %d", code)
		return code
	}
	backupExit := runBackup(c)
	forgetExit := runForget(c)
	if backupExit == 0 && forgetExit == 0 {
		return 0
	}
	log.Printf("backup exit %d, forget exit %d", backupExit, forgetExit)
	return backupExit | forgetExit
}

// restic exit codes (restic >= 0.17, "Scripting" docs).
const (
	exitRepoMissing = 10
	exitLockFailed  = 11
)

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

// runRestic runs restic with args and returns its exit code (1 if it could
// not be started at all).
func runRestic(args ...string) int {
	if err := resticCmd(args...).Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		log.Printf("restic %s: %v", args[0], err)
		return 1
	}
	return 0
}

// removeStaleLocks runs `restic unlock`, which (without --remove-all) only
// deletes locks whose owner is gone: live restic processes refresh their lock
// every 5 minutes, so a lock untouched for 30 minutes is stale. A run killed
// mid-operation (systemd TimeoutStartSec) leaves its lock behind, and restic
// never skips a stale lock on its own, so without this every later run fails
// (BUG-012). Safe here: each host has its own repository and one timer, so no
// live job can be holding a lock from another container. Exit 10 on a fresh
// Storage Box is expected; ensureRepo initializes it next.
func removeStaleLocks() int {
	return runRestic("unlock")
}

// ensureRepo runs `restic cat config` and initializes the repository only
// when restic reports it does not exist (exit 10). This keeps the first run on
// a fresh Storage Box self-bootstrapping, without turning a lock, password or
// network failure into a misleading `restic init` error (BUG-012).
func ensureRepo() int {
	switch code := runRestic("cat", "config"); code {
	case 0:
		return 0
	case exitRepoMissing:
		log.Printf("repository does not exist, initializing")
		return runRestic("init")
	case exitLockFailed:
		log.Printf("restic cat config: repository is locked (exit %d)", code)
		return code
	default:
		log.Printf("restic cat config failed: exit %d", code)
		return code
	}
}

// runBackup runs `restic backup <paths> --tag <hostname> --host <hostname>`
// and returns the restic exit code.
func runBackup(c config) int {
	args := append([]string{"backup"}, c.backupPaths...)
	args = append(args, "--tag", c.hostname, "--host", c.hostname)
	return runRestic(args...)
}

// runForget runs `restic forget --prune --keep-daily N --keep-weekly N
// --keep-monthly N` and returns the restic exit code.
func runForget(c config) int {
	return runRestic(
		"forget", "--prune",
		"--keep-daily", strconv.Itoa(c.keepDaily),
		"--keep-weekly", strconv.Itoa(c.keepWeekly),
		"--keep-monthly", strconv.Itoa(c.keepMonthly),
	)
}
