# Test plan handoff: issue #26 + #32 (run on a real podman host)

Neither of these can be validated on this machine — no podman installed
here. Run this whole doc on a system with podman (rootful, matching how
materia deploys these), then report results back so the two GitHub issues
can be closed/updated.

Nothing here touches this repo's git history or the live `flutterina`/`bow`
hosts — it's disposable local containers, `sudo podman rm -f` when done.

---

## Issue #26 — Try `User=1000` for beszel hub + agent

**Goal:** does the upstream `henrygd/beszel`/`henrygd/beszel-agent` image
work correctly as UID 1000 (rootless-in-container), or does it need root?
If it works → adopt `User=1000`/`Group=1000` in the quadlets. If it doesn't
→ close #26 as "stays on root", no further work.

### Hub test

```bash
# Pinned digest from components/beszel-hub/beszel-hub.container.gotmpl
IMAGE="docker.io/henrygd/beszel:0.18.7@sha256:a849ad80814b6a1a3be665304dcace5d4854b3bed7bde4dd1227e8ce1b82d477"

sudo podman volume create beszel-hub-test-data
# The repo's real .volume quadlet has no User=/Group= (root-owned by
# default). To test as 1000, chown the volume path first:
sudo podman unshare chown -R 1000:1000 \
  "$(sudo podman volume inspect beszel-hub-test-data --format '{{.Mountpoint}}')"

sudo podman run -d --name beszel-hub-test \
  --user 1000:1000 \
  -p 18090:8090 \
  -v beszel-hub-test-data:/beszel_data:z \
  -e APP_URL=http://localhost:18090 \
  "$IMAGE"

sleep 5
sudo podman logs beszel-hub-test
sudo podman inspect beszel-hub-test --format '{{.State.Status}} exitcode={{.State.ExitCode}}'
curl -sSf http://localhost:18090/api/health && echo " -> hub responded OK"
```

**Pass/fail:** container status `running`, no repeated crash-loop in logs,
`/api/health` responds. If it exits or logs permission errors (binding port
8090, writing `/beszel_data`), that's a fail — capture the exact log line.

### Agent test

The real deployment uses `Network=host` + a **read-only** bind of
`/run/podman/podman.sock`. UID 1000 needs read access to that socket for
podman stats to work at all (relevant to #32 too — see below).

```bash
IMAGE="docker.io/henrygd/beszel-agent:0.18.7@sha256:8874e2c53f9de5e063a6a80d6b617e20fa593ac5dc4eb4c6ce1f912f510f38f8"

# Check who owns the socket and its perms first — this determines whether
# UID 1000 can even open it:
ls -la /run/podman/podman.sock
stat -c '%U %G %a' /run/podman/podman.sock

sudo podman run -d --name beszel-agent-test \
  --user 1000:1000 \
  --network host \
  -v /run/podman/podman.sock:/run/podman/podman.sock:ro \
  -e KEY="ssh-ed25519 AAAAtest-placeholder-not-a-real-key" \
  -e HUB_URL="http://localhost:18090" \
  -e SYSTEM_NAME="podman-test-host" \
  "$IMAGE"

sleep 5
sudo podman logs beszel-agent-test
sudo podman inspect beszel-agent-test --format '{{.State.Status}} exitcode={{.State.ExitCode}}'
```

**Pass/fail:** container stays running (agent will complain about the fake
KEY/no real hub pairing — that's expected and fine, we're only checking it
doesn't crash on *permissions*). A permission-denied on the podman socket,
or on any internal path, is the fail signal that closes #26.

### Cleanup

```bash
sudo podman rm -f beszel-hub-test beszel-agent-test
sudo podman volume rm beszel-hub-test-data
```

### Reporting back

State plainly: "hub: pass/fail + log excerpt", "agent: pass/fail + log
excerpt". If both pass, note whether both were tested together or in
isolation (interactions between the two containers under UID 1000 aren't
expected but worth flagging if seen).

---

## Issue #32 — Does the podman socket mount actually give beszel container stats?

**Goal:** with a *real* hub+agent pairing (not the placeholder KEY above),
confirm whether the agent surfaces per-container podman stats in the hub
UI at all — issue #32 reports it currently doesn't, despite the socket
mount existing since #23.

This needs an actual hub/agent pairing (KEY/TOKEN exchange happens through
the hub's web UI), so it's more setup than #26:

```bash
IMAGE_HUB="docker.io/henrygd/beszel:0.18.7@sha256:a849ad80814b6a1a3be665304dcace5d4854b3bed7bde4dd1227e8ce1b82d477"
IMAGE_AGENT="docker.io/henrygd/beszel-agent:0.18.7@sha256:8874e2c53f9de5e063a6a80d6b617e20fa593ac5dc4eb4c6ce1f912f510f38f8"

sudo podman volume create beszel-hub-test-data

sudo podman run -d --name beszel-hub-test \
  -p 18090:8090 \
  -v beszel-hub-test-data:/beszel_data:z \
  -e APP_URL=http://localhost:18090 \
  "$IMAGE_HUB"
```

1. Browse to `http://<test-host>:18090`, create the admin account.
2. **Settings > Add System** — this generates the real `KEY` and a pairing
   `TOKEN` for a new system. Copy both.
3. Also start a couple of throwaway containers on this host first so
   there's something for the agent to report on:
   ```bash
   sudo podman run -d --name dummy-nginx docker.io/library/nginx:alpine
   sudo podman run -d --name dummy-redis docker.io/library/redis:alpine
   ```
4. Run the agent with the **real** KEY (root, matching production —
   #26's UID-1000 question is orthogonal here):
   ```bash
   sudo podman run -d --name beszel-agent-test \
     --network host \
     -v /run/podman/podman.sock:/run/podman/podman.sock:ro \
     -e KEY="<paste real KEY from step 2>" \
     -e TOKEN="<paste real TOKEN from step 2>" \
     -e HUB_URL="http://localhost:18090" \
     -e SYSTEM_NAME="podman-test-host" \
     "$IMAGE_AGENT"
   ```
5. In the hub UI, open the newly-registered system. Check whether:
   - Host-level CPU/mem/disk/network graphs appear (expected — this
     already works per #23).
   - **A "Docker"/"Containers" panel or per-container breakdown appears
     at all.** This is the actual question #32 is asking.
6. Capture agent logs regardless of outcome:
   ```bash
   sudo podman logs beszel-agent-test | grep -iE 'docker|podman|container|socket|error'
   ```

### Diagnosing *why*, if it doesn't work

Per #32's own framing, narrow down which of these it is:

- **Socket API mismatch** — check whether beszel-agent probes for the
  Docker socket at a hardcoded path (`/var/run/docker.sock`) vs. the
  podman path it's actually given here. Try also bind-mounting at
  `/var/run/docker.sock` (podman's socket is Docker-API-compatible) in
  case the agent only checks that exact path:
  ```bash
  -v /run/podman/podman.sock:/var/run/docker.sock:ro
  ```
- **Version gap** — check the beszel-agent 0.18.7 changelog/release notes
  and current upstream `main` for when/if podman or Docker-socket
  container-stats support was added, and whether it's newer than 0.18.7.
- **Missing config flag** — check beszel-agent's env var docs
  (`henrygd/beszel` README / docs site) for anything like
  `DOCKER_HOST`, `ENABLE_DOCKER`, or similar that might be required in
  addition to the socket mount.

### Cleanup

```bash
sudo podman rm -f beszel-hub-test beszel-agent-test dummy-nginx dummy-redis
sudo podman volume rm beszel-hub-test-data
```

### Reporting back

State: does the hub show any container-level panel (yes/no), which of the
three hypotheses above (socket path, version, config flag) it looks like
based on logs, and paste the relevant `podman logs` lines. That's enough
to either write the fix (update image digest, add the missing mount/env,
whatever it turns out to be) or close #32 as "not supported upstream" back
on this system.
