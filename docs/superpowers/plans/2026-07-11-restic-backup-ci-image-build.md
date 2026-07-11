# Restic-Backup CI Image Build (#17 / e01s03) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `scratch`-based container image (static `restic` + static `ssh` + a stub `wrapper` entrypoint) in CI and publish it to GHCR with a digest pin, unblocking the `restic-backup` component (#2, epic e01).

**Architecture:** Multi-stage `Dockerfile` — an Alpine `golang` builder stage compiles `restic` and the `wrapper` as static Go binaries and provides (or, if needed, compiles) a static `ssh` client, then a final `FROM scratch` stage copies just the three binaries + CA certs. A GitHub Actions workflow builds the image, re-runs the same static-link gate used locally, and only then pushes to `ghcr.io/kitten-lily/materia/restic-backup`. Renovate tracks the `resticVersion`/`opensshVersion` source pins via `custom.regex` managers; the Go builder base image is already covered by Renovate's native `docker` manager once it's digest-pinned.

**Tech Stack:** Podman (local build/verify), Docker Buildx via `docker/build-push-action` (CI), Go 1.23 (restic + wrapper), Alpine/musl (OpenSSH static build), GitHub Actions, Renovate.

## Global Constraints

- Pinned image digests, no floating tags — the Go builder base image is `FROM <image>@sha256:...`, never a bare tag (AGENTS.md "Pinned image digests").
- Every binary in the final image MUST be statically linked — `file`/`ldd` gate, both locally and in CI, before anything is pushed.
- No shell, no package manager, no dynamic linker in the final image (`FROM scratch`).
- GHCR image path: `ghcr.io/kitten-lily/materia/restic-backup`, tags `latest` + `sha-<short>`.
- Focused semantic commits, Conventional Commits style, subject ≤50 chars (AGENTS.md "Development conventions").
- Repo stays generic — no real domain names/IPs in tracked files (not applicable to this story's files, but keep in mind for AGENTS.md notes).
- Wrapper source lives at `images/restic-backup/wrapper/` — this story owns only a compiling stub; e01s04 owns its behavior.
- amd64-only for now (per spec's Out of scope) — no multi-arch build matrix.

---

### Task 1: Wrapper stub source

**Files:**
- Create: `images/restic-backup/wrapper/go.mod`
- Create: `images/restic-backup/wrapper/main.go`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a `go build`-able `package main` at `images/restic-backup/wrapper/` that Task 4's Dockerfile `COPY`s and compiles with `CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/wrapper .`. e01s04 will replace `main.go`'s body but must keep this module path and package name.

- [ ] **Step 1: Create the Go module**

```
# images/restic-backup/wrapper/go.mod
module github.com/kitten-lily/materia/images/restic-backup/wrapper

go 1.23
```

- [ ] **Step 2: Create the stub entrypoint**

```go
// images/restic-backup/wrapper/main.go
package main

func main() {}
```

- [ ] **Step 3: Verify it's valid Go via a throwaway containerized build**

No local Go toolchain is installed on this workstation (by design — the
build happens in CI/the Dockerfile builder stage, not on developer
machines). Verify syntax with a one-off container instead:

Run: `podman run --rm -v "$PWD/images/restic-backup/wrapper:/src:z" -w /src docker.io/library/golang:1.23-alpine go build -o /dev/null .`
Expected: exits 0, no output.

- [ ] **Step 4: Commit**

```bash
git add images/restic-backup/wrapper/go.mod images/restic-backup/wrapper/main.go
git commit -m "feat(restic-backup): add wrapper binary stub"
```

---

### Task 2: Dockerfile — builder stage, static restic

**Files:**
- Create: `images/restic-backup/Dockerfile`

**Interfaces:**
- Consumes: nothing new.
- Produces: a `builder` stage that leaves `/out/restic` — a statically
  linked binary. Task 3 adds `/out/ssh` to the same stage; Task 4 adds
  `/out/wrapper` and the final `scratch` stage that copies all three.

- [ ] **Step 1: Resolve the current digest for the Go builder base image**

Run: `skopeo inspect docker://docker.io/library/golang:1.23-alpine --format '{{.Digest}}'`
Expected: prints a `sha256:...` digest. Copy it — it's used in the next step.

- [ ] **Step 2: Write the Dockerfile builder stage (restic only)**

```dockerfile
# images/restic-backup/Dockerfile
# syntax=docker/dockerfile:1

ARG GO_IMAGE=docker.io/library/golang:1.23-alpine@sha256:REPLACE_WITH_DIGEST_FROM_STEP_1

FROM ${GO_IMAGE} AS builder
ARG resticVersion=v0.18.0
ARG opensshVersion=9.9p1

RUN apk add --no-cache \
    git \
    build-base \
    autoconf \
    musl-dev \
    zlib-static \
    openssl-libs-static \
    openssh-static \
    ca-certificates

RUN mkdir -p /out

# restic — static Go binary, source-pinned (Renovate: resticVersion)
RUN CGO_ENABLED=0 go install github.com/restic/restic/cmd/restic@${resticVersion} \
    && cp "$(go env GOPATH)/bin/restic" /out/restic
```

- [ ] **Step 3: Replace `REPLACE_WITH_DIGEST_FROM_STEP_1` with the real digest**

Edit the `ARG GO_IMAGE=...` line, substituting the digest printed in Step 1.
→ verify: `grep -qE 'FROM golang:.*@sha256:[0-9a-f]{64}' images/restic-backup/Dockerfile || grep -qE 'ARG GO_IMAGE=.*@sha256:[0-9a-f]{64}' images/restic-backup/Dockerfile`

- [ ] **Step 4: Build just the builder stage and verify restic is static**

Run: `podman build --target builder -t restic-backup-builder --build-arg resticVersion=v0.18.0 images/restic-backup/`
Expected: exits 0.

Run: `podman run --rm --entrypoint /out/restic restic-backup-builder version`
Expected: prints a restic version string (proves the binary runs).

Run: `podman run --rm --entrypoint /bin/sh restic-backup-builder -c "file /out/restic"`
Expected: output contains `statically linked` (or `ldd /out/restic` reports "not a dynamic executable").

- [ ] **Step 5: Commit**

```bash
git add images/restic-backup/Dockerfile
git commit -m "feat(restic-backup): build static restic in image builder stage"
```

---

### Task 3: Dockerfile — builder stage, static openssh client

**Files:**
- Modify: `images/restic-backup/Dockerfile` (append to the `builder` stage)

**Interfaces:**
- Consumes: the `builder` stage's `/out/` dir from Task 2.
- Produces: `/out/ssh` in the `builder` stage — statically linked. If the
  Alpine `openssh-static` package (already installed in Task 2's `apk add`)
  ships a working static `ssh`, this step copies it directly and skips the
  from-source build; the decision must be documented in AGENTS.md either way.

- [ ] **Step 1: Check whether Alpine's `openssh-static` package's `ssh` is already static**

Run: `podman run --rm --entrypoint /bin/sh restic-backup-builder -c "ldd /usr/bin/ssh"`
Expected: either `not a dynamic executable` (package ssh IS static — take
the fast path) or a list of `.so` dependencies (package ssh is dynamic —
fall through to the from-source build).

- [ ] **Step 2a — fast path: if the package `ssh` is static, add this to the Dockerfile**

```dockerfile
# openssh client — Alpine's openssh-static package ships a statically
# linked ssh; see AGENTS.md "openssh static build" for the from-source
# fallback this replaces.
RUN cp /usr/bin/ssh /out/ssh
```

→ verify: `grep -q 'cp /usr/bin/ssh /out/ssh' images/restic-backup/Dockerfile`

- [ ] **Step 2b — fallback path: if the package `ssh` is dynamic, add this instead**

```dockerfile
# openssh client — built from source, statically linked (Renovate: opensshVersion).
# --with-privsep-path=/tmp: privsep only applies to sshd, not the ssh client,
# but configure requires a path that exists — /tmp is a harmless placeholder
# in the builder stage and is never carried into the final scratch image.
RUN wget -O /tmp/openssh.tar.gz \
      "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${opensshVersion}.tar.gz" \
    && tar -xzf /tmp/openssh.tar.gz -C /tmp \
    && cd /tmp/openssh-${opensshVersion} \
    && ./configure LDFLAGS=-static --with-privsep-path=/tmp \
    && make ssh \
    && cp ssh /out/ssh
```

→ verify: `grep -q 'LDFLAGS=-static' images/restic-backup/Dockerfile`

Only add ONE of Step 2a/2b — whichever Step 1 determined.

- [ ] **Step 3: Rebuild the builder stage and verify ssh is static**

Run: `podman build --target builder -t restic-backup-builder --build-arg resticVersion=v0.18.0 --build-arg opensshVersion=9.9p1 images/restic-backup/`
Expected: exits 0. (If the fallback path fails here, see the plan's Risks
note below before debugging further — `--with-privsep-path` is the known
friction point.)

Run: `podman run --rm --entrypoint /out/ssh restic-backup-builder -V`
Expected: prints an OpenSSH version string to stderr.

Run: `podman run --rm --entrypoint /bin/sh restic-backup-builder -c "ldd /out/ssh"`
Expected: `not a dynamic executable`.

- [ ] **Step 4: Document the decision in AGENTS.md**

Add one bullet to AGENTS.md's Gotchas section recording which path (2a or
2b) was taken and why — future Renovate bumps of `opensshVersion` only
matter if the from-source path was used.

- [ ] **Step 5: Commit**

```bash
git add images/restic-backup/Dockerfile AGENTS.md
git commit -m "feat(restic-backup): build static openssh client in image builder stage"
```

---

### Task 4: Dockerfile — wrapper compile + final scratch stage

**Files:**
- Modify: `images/restic-backup/Dockerfile` (append wrapper compile step +
  final `FROM scratch` stage)

**Interfaces:**
- Consumes: `images/restic-backup/wrapper/` from Task 1; `/out/restic` and
  `/out/ssh` from Tasks 2–3.
- Produces: the complete `restic-backup` image — `ENTRYPOINT
  ["/usr/local/bin/wrapper"]`, with `/usr/bin/restic`, `/usr/bin/ssh`, and
  `/etc/ssl/certs/ca-certificates.pem` alongside it. e01s05's
  `.container.gotmpl` pulls this image by digest.

- [ ] **Step 1: Add the wrapper compile step to the builder stage**

```dockerfile
COPY wrapper/ /src/wrapper/
RUN cd /src/wrapper \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/wrapper .
```

- [ ] **Step 2: Add the final scratch stage**

```dockerfile
FROM scratch
COPY --from=builder /out/restic /usr/bin/restic
COPY --from=builder /out/ssh /usr/bin/ssh
COPY --from=builder /out/wrapper /usr/local/bin/wrapper
COPY --from=builder /etc/ssl/certs/ca-certificates.pem /etc/ssl/certs/ca-certificates.pem
ENTRYPOINT ["/usr/local/bin/wrapper"]
```

- [ ] **Step 3: Full local build**

Run: `podman build -t restic-backup-test --build-arg resticVersion=v0.18.0 --build-arg opensshVersion=9.9p1 images/restic-backup/`
Expected: exits 0.

- [ ] **Step 4: Verify restic runs from scratch**

Run: `podman run --rm --entrypoint /usr/bin/restic restic-backup-test version`
Expected: prints restic version string. (Proves a static Go binary runs
with no dynamic linker present — the core scratch-image assumption.)

- [ ] **Step 5: Verify ssh runs from scratch**

Run: `podman run --rm --entrypoint /usr/bin/ssh restic-backup-test -V`
Expected: prints OpenSSH version string. This is the riskiest gate — if it
fails here but passed in Task 3's builder-stage check, the final `COPY`
missed a dependency (shouldn't happen for a truly static binary, but this
is the check that would catch it).

- [ ] **Step 6: Verify image size**

Run: `podman image inspect restic-backup-test --format '{{.Size}}'`
Expected: prints a byte count under 50000000 (50 MB).

- [ ] **Step 7: Commit**

```bash
git add images/restic-backup/Dockerfile
git commit -m "feat(restic-backup): compile wrapper and assemble scratch image"
```

---

### Task 5: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/restic-backup-image.yml`

**Interfaces:**
- Consumes: `images/restic-backup/Dockerfile` and
  `images/restic-backup/wrapper/` from Tasks 1–4.
- Produces: on push to `main` touching `images/restic-backup/**`, pushes
  `ghcr.io/kitten-lily/materia/restic-backup:latest` and `:sha-<short>`,
  gated by the same static-link checks Task 4 ran locally. Emits the digest
  to the job summary for e01s05 to consume.

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/restic-backup-image.yml
name: restic-backup image

on:
  push:
    branches: [main]
    paths:
      - "images/restic-backup/**"
      - ".github/workflows/restic-backup-image.yml"
  workflow_dispatch: {}

permissions:
  contents: read
  packages: write

env:
  IMAGE: ghcr.io/kitten-lily/materia/restic-backup

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build (local, no push)
        uses: docker/build-push-action@v6
        with:
          context: images/restic-backup
          load: true
          push: false
          tags: ${{ env.IMAGE }}:ci-check
          build-args: |
            resticVersion=v0.18.0
            opensshVersion=9.9p1

      - name: Gate — restic is static and runs
        run: docker run --rm --entrypoint /usr/bin/restic ${{ env.IMAGE }}:ci-check version

      - name: Gate — ssh is static and runs
        run: docker run --rm --entrypoint /usr/bin/ssh ${{ env.IMAGE }}:ci-check -V

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute short SHA tag
        id: sha
        run: echo "short=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

      - name: Build and push
        id: push
        uses: docker/build-push-action@v6
        with:
          context: images/restic-backup
          push: true
          tags: |
            ${{ env.IMAGE }}:latest
            ${{ env.IMAGE }}:sha-${{ steps.sha.outputs.short }}
          build-args: |
            resticVersion=v0.18.0
            opensshVersion=9.9p1

      - name: Emit digest to job summary
        run: |
          echo "### restic-backup image digest" >> "$GITHUB_STEP_SUMMARY"
          echo '```' >> "$GITHUB_STEP_SUMMARY"
          echo "${{ env.IMAGE }}@${{ steps.push.outputs.digest }}" >> "$GITHUB_STEP_SUMMARY"
          echo '```' >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: Verify the workflow file is well-formed**

Run: `grep -q 'ghcr.io/kitten-lily/materia/restic-backup' .github/workflows/restic-backup-image.yml && grep -q 'contents: read' .github/workflows/restic-backup-image.yml && grep -q 'packages: write' .github/workflows/restic-backup-image.yml`
Expected: exits 0 (all three greps match).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/restic-backup-image.yml
git commit -m "ci(restic-backup): build and publish image to GHCR"
```

---

### Task 6: Renovate managers for source version pins

**Files:**
- Modify: `renovate.json5:38-52` (append to the existing `customManagers` array)

**Interfaces:**
- Consumes: the `ARG resticVersion=...` / `ARG opensshVersion=...` lines in
  `images/restic-backup/Dockerfile` from Task 2/3.
- Produces: two new `customManagers` entries. The Go builder base image
  needs no new manager — it's already covered by Renovate's native `docker`
  manager once digest-pinned (Task 2, Step 3).

- [ ] **Step 1: Add the two customManagers entries**

Insert into the existing `customManagers: [ ... ]` array in
`renovate.json5`, alongside the existing `badgerVersion` entry:

```json5
    {
      // restic source version pin — compiled from source in the image
      // builder stage (images/restic-backup/Dockerfile), not a prebuilt
      // binary download.
      customType: "regex",
      description: "restic version in restic-backup Dockerfile",
      managerFilePatterns: ["/(^|/)images/restic-backup/Dockerfile$/"],
      matchStrings: [
        "ARG resticVersion=(?<currentValue>v[^\\s]+)",
      ],
      depNameTemplate: "restic/restic",
      datasourceTemplate: "github-tags",
    },
    {
      // OpenSSH portable source version pin — only load-bearing if the
      // from-source static build path was taken (see AGENTS.md); harmless
      // no-op otherwise since Alpine's openssh-static tracks its own
      // Renovate-independent apk index.
      customType: "regex",
      description: "OpenSSH portable version in restic-backup Dockerfile",
      managerFilePatterns: ["/(^|/)images/restic-backup/Dockerfile$/"],
      matchStrings: [
        "ARG opensshVersion=(?<currentValue>[^\\s]+)",
      ],
      depNameTemplate: "openssh/openssh-portable",
      datasourceTemplate: "github-tags",
    },
```

- [ ] **Step 2: Verify renovate.json5 is still valid JSON5 and both managers are present**

Run: `node -e "require('json5').parse(require('fs').readFileSync('renovate.json5','utf8'))" 2>&1 || npx --yes json5 renovate.json5 >/dev/null`
Expected: no parse error. (If neither `json5` nor `npx` is available, at
minimum run the grep check below — it's the same check the spec's
Verification Script uses.)

Run: `grep -q 'resticVersion' renovate.json5 && grep -q 'opensshVersion' renovate.json5`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add renovate.json5
git commit -m "chore(renovate): track restic and openssh source version pins"
```

---

### Task 7: Push, verify published image, close out tracking

**Files:**
- Modify: `specs/epics/e01-restic-backup/epic.yaml` (flip e01s03 status)

**Interfaces:**
- Consumes: the pushed workflow run from Task 5.
- Produces: a recorded image digest for e01s05 to pin in
  `.container.gotmpl`; `epic.yaml` no longer shows the epic as blocked on
  #17.

- [ ] **Step 1: Push to main and watch the workflow run**

```bash
git push origin main
gh run watch --exit-status
```

Expected: the `restic-backup image` workflow run completes successfully
(exit 0). If the static-link gate step fails, stop — do not proceed until
it's green (Always Green convention).

- [ ] **Step 2: Read the digest from the job summary**

```bash
gh run view --log | grep -A2 'restic-backup image digest'
```

Or open the run's Summary tab in the GitHub UI. Copy the
`ghcr.io/kitten-lily/materia/restic-backup@sha256:...` value.

- [ ] **Step 3: Confirm the image is pullable by digest**

Run: `podman pull ghcr.io/kitten-lily/materia/restic-backup@sha256:<digest-from-step-2>`
Expected: exits 0. If it fails with a permission/auth error, the GHCR
package defaulted to private — make it public in the package settings
(recommended: the image contains no secrets) rather than wiring a pull
token, per the spec's Risks note.

- [ ] **Step 4: Record the digest for e01s05**

Add a one-line note with the digest to
`specs/epics/e01-restic-backup/e01s05-quadlet-resources.md`'s Context
section (or wherever e01s05 expects it) so the next story doesn't have to
re-derive it.

- [ ] **Step 5: Update epic tracking**

In `specs/epics/e01-restic-backup/epic.yaml`:
- Change the `e01s03` story's `status: planned` → `status: done`.
- Remove or update the epic-level `status: blocked` / `blocks_on:
  https://github.com/kitten-lily/materia/issues/17` comment now that #17
  has landed a publishable digest (leave `blocks_on` as historical context
  in a code comment if useful, but the `status` field must no longer read
  `blocked`).

→ verify: `grep -A2 'id: e01s03' specs/epics/e01-restic-backup/epic.yaml | grep -q 'status: done'`

- [ ] **Step 6: Commit**

```bash
git add specs/epics/e01-restic-backup/epic.yaml specs/epics/e01-restic-backup/e01s05-quadlet-resources.md
git commit -m "docs(specs): close out e01s03, record image digest for e01s05"
```

---

## Notes carried from the spec's Risks section

- **Static OpenSSH build (P0)** — Task 3 is the highest-risk task in this
  plan. If `--with-privsep-path=/tmp` isn't enough and `make ssh` still
  fails, the next fallback is patching `configure` directly — not covered
  step-by-step here because the exact failure mode won't be known until
  Task 3, Step 3 is actually run. Full prior research (including why
  switching to rustic doesn't avoid this build) is in issue #17's comments.
- **`go install` reproducibility** — Task 2 pins `resticVersion` as an
  `ARG`; the Go builder base image itself is digest-pinned (Task 2, Step
  1–3), so the same source version always compiles against the same
  toolchain.
- **GHCR visibility** — handled reactively in Task 7, Step 3 rather than
  guessed at up front, since the default depends on the GitHub org's
  package settings at push time.
