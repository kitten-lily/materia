# Issue #28: BuildStream cache server for krytis

## Status: planning complete, ready to write the component

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
2. **Resolved: two raw TCP resources, one per Buildbarn service, and both
   can be declared in a blueprint (not manual dashboard clicking).**
   Confirmed against Pangolin's blueprint schema — `public-resources`
   supports `mode: tcp` with `proxy-port` (the public port on the Pangolin
   VPS) and `targets: [{hostname, port, method}]`, same shape as HTTP
   resources. Concretely:
   ```yaml
   public-resources:
     bst-cache-index:
       name: BST Cache Index
       mode: tcp
       proxy-port: 7981
       targets:
         - hostname: bb-asset
           port: 7981
           method: tcp
     bst-cache-storage:
       name: BST Cache Storage
       mode: tcp
       proxy-port: 7982
       targets:
         - hostname: bb-storage
           port: 7982
           method: tcp
   ```
   This slots into newt's existing `blueprint.yaml.gotmpl`
   (currently only has a `sites:` section) or a second blueprint file —
   either way it's the same `PROVISIONING_BLUEPRINT_FILE` one-time-bootstrap
   mechanism newt already uses (**not** continuously reconciled; "dashboard
   is the source of truth after first boot" per the existing newt component
   docs — consistent with how sites already work here).

   **What blueprints don't cover, confirmed from Pangolin's own raw-TCP
   docs**: "Proxied Resources require extra configuration... firewall
   rules, Docker port mappings, and Traefik entry points... require a
   server restart." Concretely, on `flutterina` (the pangolin/edge host,
   not bow):
   - `components/pangolin/pangolin.pod` needs two new `PublishPort` lines
     (one per `proxy-port`, matching the raw-TCP doc's `gerbil: ports:`
     example — Gerbil is in the shared pod, so this is a `pangolin.pod`
     change, not a new pod).
   - `components/pangolin/traefik/traefik_config.yml.gotmpl` needs two new
     named `entryPoints` (`tcp-7981: address: ":7981/tcp"`, same for 7982)
     — this is the one place a new component genuinely has to touch an
     existing component's static config, unlike every HTTP-resource
     component so far which only needed a `newt-net` join.
   - `flags: allow_raw_resources: true` (self-hosted-only feature) —
     **already set**, confirmed at
     `components/pangolin/config/config.yml.gotmpl:56`. Nothing to do here.
3. **Resolved: raw TCP resources use the exact same Newt/`newt-net` target
   mechanism as HTTP resources.** Confirmed directly in Pangolin's docs:
   "TCP and UDP resources use targets like HTTP/HTTPS resources... Assign
   targets to different sites." No different backend-reachability
   mechanism — `bb-storage`/`bb-asset` just need `Network=newt-net` like
   every other tunneled component here, and Newt (already running on bow
   via `[Roles.tunneled]`) carries the traffic exactly as it does for
   jellyfin/navidrome/etc.
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
6. **Resolved: CAS quota = 100G.** Grounded in one real data point: a
   partial local test push (~30 freedesktop-sdk bootstrap elements,
   stopped well before completion) already used 1.5G in `bb-storage`'s
   CAS. Combined with the full dependency graph being ~150+ elements
   (`mise validate` on `oci/krytis/image.bst`) and krytis targeting a
   single architecture (`x86_64`, with an `x86_64_v3` on/off variant — at
   most ~2x, not a multi-arch multiplier), a full single-variant
   population is plausibly 10–30G, with much smaller growth per
   subsequent build since CAS dedupes shared blobs (toolchain, base
   runtime) across builds. **bow has 401G free on `/var/lib/materia-data`
   right now** (user-confirmed) — 100G leaves ~300G for the media
   libraries (jellyfin/grimmory/audiobookshelf) that already live on the
   same disk, while giving 3–10x headroom over the estimated working set
   for growth and multiple historical build generations before Buildbarn's
   own LRU eviction kicks in.

   Only the CAS "blocks" backend needs this size — confirmed from the
   krytis quadlet's own config (`bb-asset`'s `assetCache` backend only
   holds URI→digest mapping metadata; the actual tarball/blob bytes for
   *both* artifacts and sources are forwarded to and stored in
   `bb-storage`'s CAS via `contentAddressableStorage: { grpc: { client:
   { address: 'localhost:7982' } } }`). Concrete sizes for
   `config/storage.jsonnet` on bow (scaled up from krytis's local-test
   values, which were picked without real headroom data):
   - CAS `blocksOnBlockDevice.sizeBytes`: `100 * 1024^3` (100G) — was 64G
     locally.
   - ActionCache blocks: 2G (headroom over the local test's 512M in case
     action-cache entries proliferate with build variation — these are
     small metadata records, not raw content, so this is generous already).
   - FileSystemAccessCache blocks: 100M (was 20M locally — tiny either way).
   - `bb-asset`'s own `assetCache.blobAccess` local backend: 1G (URI→digest
     mapping metadata only, was 512M locally).
7. **Resolved: two `mise` tasks, hand-rolled JWT via `openssl`/`jq`/`xxd`
   — no new tool dependency.** Mirrors `hz:storagebox:install-key`'s exact
   pattern (`sops --set` with `jq -Rn --arg v ... '$v'` JSON-encoding, not
   manual `sops edit` paste — same corruption risk `BUG-003` already
   documents for multi-line secrets, avoided the same way here even though
   these are single-line).

   - **`.mise/tasks/buildbarn/secret-init`** (`--server-name`, defaults
     `bow`) — idempotent (checks `components.buildbarn.jwtSecretHex`
     before regenerating, same guard shape as krytis's own
     `buildbarn:certs-init`). Generates `openssl rand -hex 32`, writes it
     to the vault as `components.buildbarn.jwtSecretHex`. Also derives and
     writes `components.buildbarn.jwtJwks` — the JWKS JSON Buildbarn's
     `jwt` policy needs (`{keys: [{kty: "oct", k: <base64url of the RAW
     key bytes>, alg: "HS256"}]}`). Stored as **hex**, not base64, in the
     vault — unambiguous re-read for signing (`openssl dgst -macopt
     hexkey:...`), converted to base64url only for the JWKS `k` field
     (RFC 7518 requires base64url of raw bytes there, not the hex string).
   - **`.mise/tasks/buildbarn/mint-token`** (`--server-name`, `--role
     push|pull`) — reads the hex secret back via `sops -d | yq`, builds a
     JWT by hand: base64url the header/payload, sign with `openssl dgst
     -sha256 -mac hmac -macopt hexkey:$secret`, base64url the signature,
     join with `.`. Prints to stdout, **does not write the token back to
     the vault** — matches the earlier decision that tokens are
     regenerable derived artifacts, not independently-managed secrets.
     No `exp` claim (long-lived by design); `role: "push"|"pull"` is the
     only claim, read server-side via the same
     `metadata_extraction_jmespath_expression` → `Authorizer` pattern
     already used for the mTLS design (just `payload.role` instead of a
     cert SAN).

   Verified independently: minted a token with this exact construction and
   confirmed the HMAC-SHA256 signature byte-for-byte against Python's
   `hmac` module using the same hex-decoded key — not just "looks like a
   JWT," the signature itself is provably correct. One real bug caught
   doing this: `jq -cn ... | _b64url` piped directly baked jq's trailing
   newline into the payload segment (still valid JSON when decoded, since
   parsers ignore trailing whitespace, but not a canonical/clean token) —
   fixed by capturing jq's output through a `$(...)` command substitution
   first (which strips the trailing newline) before base64url-encoding it,
   rather than piping directly.

All seven open questions are now resolved: exposure mechanism (raw TCP
resource, blueprint-declared), auth (JWT/HS256, tooling written —
`.mise/tasks/buildbarn/{secret-init,mint-token}`), image (pinned by
digest, no build step), and disk sizing (100G CAS quota, grounded in a
real measurement + bow's actual free space). Nothing left blocks writing
the `buildbarn` component itself: the quadlet units
(`quadlet/buildbarn/*.container`), `MANIFEST.toml`, the `pangolin.pod` /
`traefik_config.yml.gotmpl` additions, and the blueprint's
`public-resources` entries.

The JWT switch was still worth making even though it didn't unlock
HTTP-resource exposure as hoped (blocked upstream by
`fosrl/pangolin#115`) — it drops the CA/client-cert machinery regardless
of which exposure mechanism ends up in front of it.
