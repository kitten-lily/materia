# Issue #28: BuildStream cache server for krytis

## Status: unblocked — resuming from paused spike

## Problem

`starlit-os/krytis` (BuildStream-based OS image project, same shape as
`projectbluefin/dakota`) currently points its `project.conf` `artifacts`/
`source-caches` at two external gRPC CAS servers it doesn't own
(`gbm.gnome.org:11003`, `cache.projectbluefin.io:11001`). Issue #28 asks for
a krytis-owned equivalent.

## Why this was paused, and why it's unblocked now

The original spike (see comment on #28) tried `bst-artifact-server`, the
BuildStream-native CLI cache server. Findings at the time:

- `pip install BuildStream` (2.7.0) ships prebuilt `manylinux_2_28` wheels
  with no static-build pain, but the wheel only registers `bst` as a console
  script — `bst-artifact-server` documented in `man/bst-artifact-server.1`
  (port, `--server-key`, `--server-cert`, `--client-certs`, `--enable-push`,
  `--quota`) **no longer exists as an installable entry point**. The man page
  is stale, dated 2020 (BuildStream 1.x era).
- The actual server logic (`buildstream._cas.casserver.create_server()`) is
  fully implemented and does everything the man page describes, but it's an
  underscore-prefixed internal module, only exercised by BuildStream's own
  test suite — no public/stable API contract.
- Standing up a cache server that way means writing and maintaining a
  wrapper around an unpublished internal module, with no upstream
  compatibility guarantee across BuildStream releases. Paused rather than
  commit to that maintenance risk.

**Unblock:** BuildStream's own docs state it works against *any* compliant
implementation of the CAS + remote-asset protocols, not just its own CLI.
Krytis has since stood up, deployed (locally, rootless), and verified
end-to-end **[Buildbarn](https://github.com/buildbarn)** (`bb-storage` +
`bb-remote-asset`) as the cache server instead — an actively-maintained
third-party implementation, no custom wrapper, no private-API dependency.
See `~/Projects/StarlitOS/krytis` PRs #341 (quadlet infra), #342 (source
cache wiring), #343 (artifact cache wiring) for the working design and
every bug found getting there.

## What's already proven (in krytis, not this repo)

- Podman Quadlet units (`bb-storage.container`, `bb-asset.container`,
  `.volume` units) — rootless, `Network=host` (rootless bridge networking
  needs nft/iptables NAT that isn't guaranteed available — see krytis's
  `docs/skills/ci-runner.md`).
- `bb-storage` serves CAS + ActionCache; `bb-asset` serves the remote-asset
  index. **Both `source-caches:` and `artifacts:` need a `type: index` /
  `type: storage` split across the two services** — a single unsplit entry
  fails immediately (`unknown service ...ContentAddressableStorage` or
  `Configured remote does not implement the Remote Asset Fetch service`,
  depending which one you point a single entry at).
- mTLS: one CA signs a server cert plus per-role client certs
  (`ci-push` / `pull`), authorization enforced per-operation in Buildbarn's
  own config (`putAuthorizer`/`pushAuthorizer` gated by client-cert URI SAN)
  rather than at the TLS handshake layer.
- `bb-remote-asset`'s HTTP fetcher backend can't serve `FetchDirectory`
  (BuildStream pushes/fetches multi-file sources as CAS Directory trees, not
  blobs) — must configure `fetcher: { 'error': {...} }` (NOT_FOUND) for a
  pure cache that never reaches out to fetch on its own.
- Full round trip verified: wipe local BuildStream cache, `bst source push`
  / `bst artifact push`, wipe again, `bst source fetch` / `bst artifact
  pull` — confirmed pulling *only* from the krytis-owned remote, zero
  upstream requests.

## Decisions (this session, materia side)

- **Storage:** unchanged from the original spike — local disk on bow's LVM
  data disk (bind mount under `/var/lib/materia-data/`, same pattern as
  grimmory's `Books` bind), not a podman named volume on root storage, not
  the Storage Box. Buildbarn's CAS does high-volume small-blob
  random-access I/O under CI load; the Storage Box (SFTP/CIFS-only) and
  root-fs-backed named volumes are both a poor fit for the same reason
  identified in the original spike.
- **Host:** bow, unchanged — still explicitly a *temporary* placement.
  Don't over-invest in bow-specific wiring that would block a later move to
  a dedicated server (multi-server model, `mise server:new`).
- **Runner topology:** krytis's quadlet was designed assuming Buildbarn
  co-locates with the self-hosted GitHub Actions runner (same box,
  `Network=host`, mutually-reachable via `localhost`). **On bow, that
  assumption does not hold** — the runner today lives on the dev
  workstation the krytis work happened on, not on bow. Treat Buildbarn on
  bow as remote from wherever CI/dev clients actually run: real TLS certs
  with the actual reachable hostname/IP in the SAN (not the throwaway
  `melog`-only cert from krytis's local testing), network exposure design
  needed (see below).

  Note: there's a **separate, uncommitted investigation** in this repo
  (`specs/plans/investigation-github-runner-bow.md` /
  `issue-github-runner-bow.md`) about moving the krytis self-hosted runner
  itself onto bow, rootless-isolated via a dedicated `ci-runner` user. If
  that lands, Buildbarn and the runner could end up co-located after all —
  but that's a distinct, not-yet-decided piece of work. Don't let this
  component's design assume it; if it happens, co-location becomes a
  latency optimization, not a requirement, since the exposure path below
  works regardless of where the client sits.

- **Auth: switched from mTLS to JWT bearer token — but exposure stays raw
  TCP.** Buildbarn's `AuthenticationPolicy` supports a `jwt` variant
  ("allow incoming requests in case they present an 'Authorization' header
  containing a JWT bearer token", validated against a JWKS). Originally
  proposed to also drop raw-TCP passthrough for a normal Pangolin HTTP
  resource (Traefik terminates TLS publicly, forwards plaintext gRPC via
  `h2c://backend:port` — confirmed Traefik itself supports this cleanly).
  **That part doesn't work**: Pangolin's own resource `target.method` field
  only supports `http`/`https` — h2c backend support is an open, unresolved
  upstream feature request (`fosrl/pangolin#115`, maintainer response is
  just "will take a look"). Hand-writing a static `dynamic_config.yml.gotmpl`
  override doesn't route around this either: the actual tunnel routing (which
  CGNAT IP a target resolves to) is generated dynamically by Pangolin's own
  control plane from its target registration, not something we can hardcode
  reliably in a static file. So **raw TCP resource remains the only working
  exposure path** for this component, independent of the auth method.

  The auth simplification still holds on its own, though — JWT bearer token
  over **server-only** TLS (Buildbarn still terminates its own TLS for
  confidentiality through the tunnel, but no client certificate anymore):
  - **No client-cert generation/rotation/distribution.** Still need one
    server cert (Buildbarn's own, SAN = wherever it's actually reachable —
    same caveat as before, no friendly hostname from a raw TCP resource),
    but the CA + per-role client cert/key pairs the mTLS design needed are
    gone entirely. Simpler ops for the one artifact (`ci-push` credential)
    that has to leave this repo's control into krytis's GitHub Actions
    secrets — a token string is easier to rotate/revoke than a cert.
  - **Algorithm: HS256, one shared secret** (user decision) — no keypair,
    matches this repo's existing single-secret pattern
    (`beszel-agent`'s `beszelToken`). The secret becomes a JWKS with one
    `kty: "oct"` entry (`k: base64url(secret)`) fed to Buildbarn's
    `jwks_inline`/`jwks_file` config.
  - **Push/pull role split via a JWT claim, not a cert SAN** (user
    decision: two long-lived tokens, not one shared token). Mint two JWTs
    from the same HS256 secret — one with `role: "push"`, one with
    `role: "pull"` in the payload — and reuse the *exact same*
    `metadata_extraction_jmespath_expression` → `Authorizer` pattern
    already written for krytis's mTLS design
    (`quadlet/buildbarn/config/common.libsonnet`), just reading
    `payload.role` instead of a cert's URI SAN. Minimal rework: swap the
    `tlsClientCertificate` policy block for a `jwt` block, keep
    `pushOnlyAuthorizer`'s shape (`contains(...)` →
    `authenticationMetadata.public.role == 'push'`).

- **Secrets:** one HS256 shared secret in `attributes/bow.yml`
  (SOPS-encrypted), following the same pattern as `restic-backup`'s
  `resticPassword` or `beszel-agent`'s `beszelToken`. The two minted JWTs
  (`push`/`pull`) are derived artifacts, not independently-managed
  secrets — regenerable from the shared secret at any time, so only the
  secret itself needs vault storage; the `push` token is what actually
  leaves this repo's control (goes into krytis's GitHub Actions secrets,
  same as the original mTLS plan's `ci-push` client key — just a token
  string now instead of a cert+key pair).

- **krytis-side follow-up (not this repo):** once bow is live, krytis's
  `project.conf`/CI-side `buildstream.conf` need to switch from the
  `auth: {server-cert, client-cert, client-key}` shape (merged in
  krytis PRs #341–#343) to `auth: {access-token: <path>}` — BuildStream's
  user-config docs confirm `access-token` is precisely "path to a token for
  optional HTTP bearer authentication," sent as the `Authorization` header
  Buildbarn's `jwt` policy expects. Flagging now so it isn't a surprise
  later; not doing that swap as part of this investigation since krytis's
  local mTLS design is still valid and tested for same-machine deployment
  (dev workstation), independent of whether bow ever becomes the real
  target.

## Open questions for plan-work

1. **Resolved (dead end): `h2c://` backend scheme.** Traefik itself
   supports it cleanly (confirmed against v2.10–v3.5 docs —
   `loadBalancer.servers.url: h2c://bb-storage:7982` instead of `http://`,
   no other special config), but **Pangolin's resource system doesn't** —
   `target.method` only supports `http`/`https`; h2c backend support is an
   open, unresolved upstream feature request (`fosrl/pangolin#115`). A
   hand-written `dynamic_config.yml.gotmpl` override doesn't route around
   this either, since the actual tunnel-IP routing for a target is
   generated dynamically by Pangolin's own control plane, not something
   safe to hardcode in a static file. **Conclusion: raw TCP resource is
   the exposure mechanism**, full stop, until upstream Pangolin adds h2c
   support — not a design preference, a hard current constraint.
2. **Two raw TCP resources, one per Buildbarn service.** Confirmed
   Buildbarn needs two reachable ports (`bb-asset` index, `bb-storage`
   storage) matching `project.conf`'s `type: index`/`type: storage` split
   (krytis PRs #342/#343) — back to the original raw-TCP framing: no
   friendly hostname per resource, clients connect to the Pangolin VPS's
   IP and two assigned ports directly. Still need to confirm whether raw
   TCP resources are strictly 1:1 with a backend port, and what port
   numbers get assigned/exposed externally vs. the container-internal ones.
3. **Raw TCP resource + Newt interaction** — confirm Newt (already running
   on bow via `[Roles.tunneled]`) is what carries a raw TCP resource's
   traffic to the `bb-storage`/`bb-asset` containers on `newt-net` (same
   container-name reachability pattern as every other tunneled component
   here), or whether raw TCP resources have a different
   backend-reachability mechanism.
4. **Server cert SAN, again.** Since raw TCP resources genuinely have no
   hostname (client dials the Pangolin VPS IP + port directly), Buildbarn's
   server cert SAN needs that IP, not a domain name — same caveat the
   original mTLS design had, unaffected by the JWT auth switch since
   Buildbarn still terminates its own TLS either way.
5. **Container image** — no official minimus/upstream image for either
   `bb-storage` or `bb-remote-asset` referenced anywhere in this repo yet.
   Krytis's quadlet pins `ghcr.io/buildbarn/bb-storage`/`bb-remote-asset` by
   digest directly (no build step needed, unlike the original
   `bst-artifact-server` spike which would have required a custom
   `images/bst-cache/Dockerfile`). Renovate's `quadlet` manager should
   track these once the component exists, same as every other pinned image.
6. **Disk sizing on bow** — still open from the original spike. Server
   needs to hold every architecture's built artifacts krytis cares about;
   larger than a client-side `cache: quota: 50G` setting.
7. **JWT minting tooling** — does generating the `push`/`pull` tokens from
   the HS256 secret get a `mise` task (like `hz:storagebox:install-key`,
   which already writes secrets straight into a host's vault via `sops
   --set`), or a documented one-time manual step (e.g. `step` CLI or a
   short script) here. Simpler than the CA tooling question the mTLS
   design had — no SAN/hostname parameter needed, since the token doesn't
   encode where it's used, only who's allowed to use it.

Next step: resolve #2 and #3 (raw TCP resource port assignment + Newt
reachability) — the same pair of questions the very first version of this
plan had, before the JWT/h2c detour. Everything else (storage, host, auth
mechanism, secrets, image, disk sizing, JWT tooling) carries over cleanly
from either the original spike or krytis's existing design. The JWT switch
was still worth making even though it didn't unlock HTTP-resource exposure
as hoped — it drops the CA/client-cert machinery regardless of which
exposure mechanism ends up in front of it.
