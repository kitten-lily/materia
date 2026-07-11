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
	_ = loadConfig()
}
