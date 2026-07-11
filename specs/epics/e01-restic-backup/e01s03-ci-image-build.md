# Story e01s03 — CI: build & publish restic-backup image to GHCR

**type:** feat
**risk:** P0
**context:** infra
**epic:** e01-restic-backup
**github issue:** https://github.com/kitten-lily/materia/issues/17
**blocks:** #2 (the restic-backup component) and every downstream story in this epic

## Context

The `restic-backup` Materia component (#2) needs a container image. The
original #2 plan proposed a `.build` quadlet compiling `restic` + a
statically-linked OpenSSH client on every host. That repeats a genuinely hard
static-link build on each server and gives no digest pin for GitOps. This
story moves the build into CI: a multi-stage Dockerfile produces a `scratch`
image (static `restic` + static `ssh` + a first-party `wrapper` binary +
`ca-certificates.pem`), a GitHub Actions workflow builds and pushes it to
GHCR, and Renovate bumps the source version pins. The downstream component
(#2) then pulls the image with a pinned digest — the same convention as
pangolin/traefik.

**This story is the implementation of issue #17.** It owns the Dockerfile, the
workflow, the Renovate managers for `resticVersion`/`opensshVersion`, and the
wrapper source location. The wrapper's *behavior* (ping → init → backup →
forget → ping) is owned by e01s04; this story only compiles it into the image.

## Requirements

#### ADDED: Dockerfile produces a scratch image with three static binaries

`images/restic-backup/Dockerfile` is a multi-stage build ending in
`FROM scratch`. The final stage `COPY`s exactly: `/usr/bin/restic`,
`/usr/bin/ssh` (statically linked), `/usr/local/bin/wrapper` (statically
linked), and `/etc/ssl/certs/ca-certificates.pem`. No shell, no package
manager, no dynamic linker. Every binary MUST be statically linked (`file`
reports "statically linked" / `ldd` reports not a dynamic executable).

#### ADDED: restic built from a pinned source version

`restic` is compiled via
`CGO_ENABLED=0 go install github.com/restic/restic/cmd/restic@$resticVersion`
where `resticVersion` is a `ARG`/`ENV` in the Dockerfile. `CGO_ENABLED=0` is
required, not optional: Alpine's musl toolchain can silently produce a
dynamically-linked binary if any transitive dependency wants cgo, and
`FROM scratch` has no dynamic linker to run it. The pin is the source of
truth for Renovate; no prebuilt binary download.

#### ADDED: openssh client statically linked against musl

The `ssh` client is compiled from the OpenSSH portable source at
`$opensshVersion`, `./configure` with static linking flags (`LDFLAGS=-static`,
Alpine's `zlib-static`/`openssl-libs-static`/`musl-dev`). The resulting binary
MUST be statically linked. This is the riskiest build step — see Risks.

#### ADDED: wrapper binary compiled static, is the image ENTRYPOINT

The wrapper source lives at `images/restic-backup/wrapper/` (so this build
context is self-contained — #2's component only references the image). Built
with `CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/wrapper`. The
Dockerfile sets `ENTRYPOINT ["/usr/local/bin/wrapper"]`.

#### ADDED: ca-certificates included for future TLS backends

`/etc/ssl/certs/ca-certificates.pem` is copied into the scratch image. Not
needed for the sftp backend today, but required for any future S3/B2/rest-server
backend that uses TLS.

#### ADDED: GitHub Actions workflow builds and pushes to GHCR

`.github/workflows/restic-backup-image.yml` triggers on push to `main`
touching `images/restic-backup/**` or the workflow file, plus
`workflow_dispatch`. It builds with `docker/build-push-action` (decided over
raw `podman build`/`podman push` — the action handles buildx, GHCR auth, and
layer caching without custom scripting). Job permissions are least-privilege
and explicit: `contents: read`, `packages: write` — no implicit defaults.
Before anything is pushed, the workflow loads the built image locally
(`load: true`, `push: false` on a first build pass) and re-runs the same
static-link gate as the local check (`--entrypoint /usr/bin/restic ... version`,
`--entrypoint /usr/bin/ssh ... -V`); the job fails before GHCR is touched if
either check fails, so a non-static binary can never reach the registry. Only
then does it push to `ghcr.io/kitten-lily/materia/restic-backup` with tags
`latest` and `sha-<short>`. It emits the image digest (workflow output / job
summary) so #2 can pin `@sha256:...` in the `.container.gotmpl`.

#### ADDED: Renovate covers resticVersion and opensshVersion

`renovate.json5` gains `custom.regex` managers (github-tags datasource) for
both pins in the Dockerfile. The Go builder image tag (`golang:*-alpine`) is
already covered by Renovate's native docker manager.

## Steps

1. Create `images/restic-backup/Dockerfile` with a builder stage pinned by
   digest — `FROM golang:<goVersion>-alpine@sha256:<digest>` — matching this
   repo's git-pinned-digest convention (AGENTS.md "Pinned image digests"),
   not a floating tag. Renovate's existing native docker manager updates the
   digest pin automatically once one exists — no new manager needed for this
   one. Final stage is `FROM scratch`. Use `ARG resticVersion`, `ARG
   opensshVersion`. → verify: `grep -c 'FROM scratch' images/restic-backup/Dockerfile` returns 1 and `grep -qE 'FROM golang:.*@sha256:' images/restic-backup/Dockerfile`.

2. In the builder stage, install the static-build toolchain:
   `apk add --no-cache git openssh-static zlib-static openssl-libs-static musl-dev build-base autoconf`.
   → verify: `grep -q 'zlib-static' images/restic-backup/Dockerfile`.

3. In the builder stage, build restic via
   `CGO_ENABLED=0 go install github.com/restic/restic/cmd/restic@$resticVersion`
   and place the binary at `/out/restic`. Do not drop `CGO_ENABLED=0` — see
   Requirements above for why it's load-bearing, not stylistic. → verify:
   `grep -q 'CGO_ENABLED=0 go install github.com/restic/restic' images/restic-backup/Dockerfile`.

4. In the builder stage, download + extract the OpenSSH portable tarball at
   `$opensshVersion`, `./configure` with static linking flags
   (`LDFLAGS=-static`, `--with-privsep-path=/tmp`), `make`, and copy the `ssh`
   binary to `/out/ssh`. **Check Alpine's `openssh-static` package first** —
   if it ships a working static `ssh`, skip the from-source build and use the
   package binary (document the decision in AGENTS.md). This is the step most
   likely to need iteration — see Risks. → verify: `grep -qE 'LDFLAGS.*static|openssh-static' images/restic-backup/Dockerfile`.

5. Create `images/restic-backup/wrapper/` with `main.go` + `go.mod` (behavior
   owned by e01s04 — here we only need a minimal `package main` that compiles,
   so the image build is testable end-to-end before e01s04 lands). In the
   builder stage: `COPY wrapper/ ./wrapper/` then
   `cd wrapper && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/wrapper .`
   → verify: `grep -q 'CGO_ENABLED=0 go build' images/restic-backup/Dockerfile`.

6. In the final `FROM scratch` stage, `COPY` the three binaries from `/out/`
   plus `ca-certificates.pem` from the builder, and set
   `ENTRYPOINT ["/usr/local/bin/wrapper"]`. → verify: `grep -q 'ENTRYPOINT.*wrapper' images/restic-backup/Dockerfile`.

7. Local build check:
   `podman build -t restic-backup-test --build-arg resticVersion=v0.18.0 --build-arg opensshVersion=9.9p1 images/restic-backup/`
   and confirm every binary is statically linked:
   `podman run --rm --entrypoint /usr/bin/restic restic-backup-test version`
   (restic version proves a Go static binary runs in scratch) and
   `podman run --rm --entrypoint /usr/bin/ssh restic-backup-test -V`
   (OpenSSH version proves the static ssh build — the riskiest step).
   → verify: both commands exit 0 and print version strings. This is the
   local dry-run of the same gate step 8's workflow enforces in CI — do this
   one first since local iteration is faster than pushing to see a CI failure.

8. Create `.github/workflows/restic-backup-image.yml` — trigger on push to
   `main` touching `images/restic-backup/**` or the workflow, plus
   `workflow_dispatch`. Permissions block: `contents: read`, `packages:
   write`, nothing implicit. Build with `docker/build-push-action`, first
   with `load: true`/`push: false` to get the image into the local daemon,
   then run step 7's two static-link checks against it as a job step — fail
   the job here if either check fails. Only on success, push to
   `ghcr.io/kitten-lily/materia/restic-backup` with tags `latest` +
   `sha-<short>`. Emit the digest to the job summary so #2 can pin it. →
   verify: `grep -q 'ghcr.io/kitten-lily/materia/restic-backup' .github/workflows/restic-backup-image.yml && grep -q 'contents: read' .github/workflows/restic-backup-image.yml`.

9. Extend `renovate.json5` `customManagers` with two `custom.regex` entries:
   `resticVersion` (datasource `github-tags`, package `restic/restic`) and
   `opensshVersion` (datasource `github-tags`, package
   `openssh/openssh-portable`) — both matching `ARG <name>=...` in the
   Dockerfile. → verify: `grep -q 'resticVersion' renovate.json5 && grep -q 'opensshVersion' renovate.json5`.

10. Push, let the workflow run, confirm the image is pullable:
    `podman pull ghcr.io/kitten-lily/materia/restic-backup@sha256:<digest>`
    using the digest from the workflow run. Record the digest (it's consumed
    by e01s05). → verify: `podman pull` exits 0.

## Verification Script (Step-by-Step)

1. `podman build -t restic-backup-test --build-arg resticVersion=v0.18.0 --build-arg opensshVersion=9.9p1 images/restic-backup/` — build succeeds.
2. `podman run --rm --entrypoint /usr/bin/restic restic-backup-test version` — prints restic version.
3. `podman run --rm --entrypoint /usr/bin/ssh restic-backup-test -V` — prints OpenSSH version.
4. `podman image inspect restic-backup-test --format '{{.Size}}'` — image < 50 MB.
5. After the first workflow run: `podman pull ghcr.io/kitten-lily/materia/restic-backup@sha256:<digest>` — pullable.
6. `grep -q 'resticVersion' renovate.json5 && grep -q 'opensshVersion' renovate.json5` — Renovate covers both pins.

## Out of scope

- Wrapper binary behavior (e01s04) — here we only compile a minimal `main.go`.
- The Materia component wiring (e01s05 onward).
- Real Storage Box connectivity (e01s11).
- Multi-arch builds (start amd64-only; add arm64 when a host needs it).

## Risks

- **Static OpenSSH build (P0).** OpenSSH's portable build system is not
  designed for static linking out of the box. Likely friction:
  `--with-privsep-path` needs a runtime path that exists in the scratch image
  (it won't — scratch has no `/var/empty`); the privsep path is only used by
  `sshd`, not `ssh`, so the `ssh` client build may tolerate a dummy
  `--with-privsep-path=/tmp`. Mitigation: if `ssh` build fails on privsep,
  patch `configure` or pass `--with-privsep-path=/tmp`. Detect early: step 7's
  `ssh -V` in scratch is the gate. **Fallback:** Alpine's `openssh-static`
  package may already provide a static `ssh` — check first (step 4); if so,
  skip the from-source build and document the decision in AGENTS.md. The
  from-source requirement is about *capability*, not dogma.
- **rustic does not avoid this build.** Considered switching to
  [rustic](https://github.com/rustic-rs/rustic) (Rust restic alternative) on
  the theory that a pure-Rust tool might have a pure-Rust SSH client. It does
  not: rustic's SFTP backend goes through OpenDAL → the `openssh` crate →
  which spawns `/usr/bin/ssh` as a subprocess (the `openssh` crate is a
  binary wrapper, not a pure-Rust SSH impl despite the name). Both restic
  and rustic `exec` the system `ssh` for SFTP; switching would trade the Go
  toolchain for a Rust one but would not remove the static-`ssh`-in-scratch
  requirement. Decision: stick with restic. The only real ways to eliminate
  the static-OpenSSH build are (a) the `openssh-static` package fallback above,
  or (b) a custom wrapper using `russh` + `russh-sftp` directly — far out of
  scope. Full research and sources in #17 comment
  https://github.com/kitten-lily/materia/issues/17#issuecomment-4945068715.
- **restic `go install` reproducibility.** `go install <module>@<version>` is
  reproducible for a given Go toolchain version. Pin the Go builder image tag
  (e.g. `golang:1.23-alpine`) so the build is stable and Renovate can bump it.
- **GHCR package visibility.** The package is created on first push; default
  visibility may be private. The component host (flutterina) pulls via podman
  — if the package is private, the host needs a podman login or a pull token.
  Decide: make the package public (simplest, the image has no secrets) or wire
  a pull secret. Recommend public — the image contains only public binaries.
- **Wrapper source location.** This story places it at
  `images/restic-backup/wrapper/` so the build context is self-contained.
  e01s04 edits that same path; #2's component never touches the wrapper source.
