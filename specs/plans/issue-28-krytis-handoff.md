# Issue #28 handoff: krytis-side BuildStream wiring

> For the `starlit-os/krytis` session. The Buildbarn cache server on
> `bow` is live and tunnel-reachable; this doc covers what krytis needs
> to do to use it. See `specs/plans/issue-28-bst-cache-krytis.md` in the
> materia repo for the full server-side design + history.

## What's running on bow (the cache server)

Two Buildbarn containers on `bow`, both on the `newt-net` podman network,
exposed publicly through the Pangolin edge on `flutterina` as raw TCP
resources:

| Service | Container | Public port | BuildStream role |
|---|---|---|---|
| `bb-asset` (remote-asset index) | `bb-asset` | **7981** | `source-caches` (`type: index`) |
| `bb-storage` (CAS + ActionCache + FSAC) | `bb-storage` | **7982** | `artifacts` (`type: storage`) |

**Public hostname:** `bst-cache.<baseDomain>` — both ports on the same
hostname (raw TCP resources have no per-resource domain; the hostname is
just for the TLS SAN + DNS resolution to the Pangolin VPS). The actual
`<baseDomain>` value is in `attributes/vault.yml` `globals.baseDomain` in
the materia repo (SOPS-encrypted); ask the user or read it from a
decrypted vault if you need the literal string. Wildcard DNS to
flutterina already covers it — no new DNS record was created.

**Tunnel path confirmed working** (2026-07-22): TCP connect to the
Pangolin VPS public IP on 7981 + 7982 succeeds end-to-end through the
Newt tunnel to the containers on bow.

## Auth model (changed from krytis's merged mTLS design)

krytis PRs #341–#343 merged a working **mTLS** design (CA + per-role
client certs) tested against a local Buildbarn on the dev workstation.
**The bow deployment uses JWT bearer tokens instead of mTLS.** This was
forced by a buildbarn constraint discovery (see materia repo
`AGENTS.md` gotchas + the plan), not a preference. You need to switch
the krytis client config from the mTLS shape to the JWT shape.

### What changed and why

- **Algorithm: EdDSA (Ed25519), not HS256.** Buildbarn's JWT validator
  (`bb-storage/pkg/jwt/configuration.go` + go-jose v3) only accepts
  asymmetric public keys. HS256/symmetric (`oct` JWKS) is rejected at
  two layers and crashes the server. Ed25519 is what's deployed.
- **No CA, no client certs.** One Ed25519 keypair lives in the materia
  vault (`jwtPrivateKeyPem`). Tokens are minted from it by a mise task.
- **Authorization is a JWT `role` claim**, not a cert URI SAN. Two
  long-lived tokens exist: `role: "push"` and `role: "pull"`. The
  server's `putAuthorizer`/`pushAuthorizer` checks
  `authenticationMetadata.public.role == 'push'`; reads accept either.
- **TLS is still server-only.** Buildbarn terminates its own TLS for
  confidentiality through the tunnel. The server cert is self-signed
  (no CA) — krytis needs `auth.server-cert` pointing at a copy of it,
  same as the mTLS design did, just without any client cert/key.

### The tokens

Minted on a workstation with the materia repo + mise toolchain + age key
access (the vault is SOPS-encrypted):

```bash
mise buildbarn:mint-token --server-name bow --role push   # → krytis GitHub Actions secrets
mise buildbarn:mint-token --server-name bow --role pull   # → dev machines (Proton Pass)
```

- **No `exp` claim** — long-lived by design.
- **`role` is the only claim** (`{role: "push", iat: <epoch>}`).
- Tokens are **derived artifacts**, not independently-managed secrets —
  re-mintable from the vault key at any time. The `push` token is what
  goes into krytis's GitHub Actions secrets (e.g.
  `BUILDBARN_PUSH_TOKEN`); the `pull` token is distributed out-of-band
  to dev machines.
- **Algorithm header:** `{"alg":"EdDSA","typ":"JWT"}`. If you verify
  tokens client-side for debugging, use Ed25519, not HMAC.

### The server cert

`components/buildbarn/certs/server.crt` in the materia repo — **public,
non-secret, committed to git.** Copy it into the krytis repo (or
reference it as a build input) for `auth.server-cert`. Self-signed, CN =
`bst-cache.<baseDomain>`, SAN = `DNS:bst-cache.<baseDomain>`, 825-day
validity.

## Config changes needed in krytis

### `project.conf` — point at the bow endpoints

The `source-caches:` and `artifacts:` entries need to point at the bow
public endpoints. **Both sections need the index/storage split** across
the two services — a single unsplit entry fails immediately
(`unknown service ...ContentAddressableStorage` or `Configured remote
does not implement the Remote Asset Fetch service`, depending which one
you point a single entry at). This was already proven in krytis's local
testing (PRs #341–#343); only the host:port changes:

- `source-caches:` → `bst-cache.<baseDomain>:7981` (bb-asset, the index)
- `artifacts:` → `bst-cache.<baseDomain>:7982` (bb-storage, the CAS/AC)
- `auth.server-cert` → copy of `components/buildbarn/certs/server.crt`
  from the materia repo

### `buildstream.conf` (user config, CI + local) — switch to access-token

Replace the mTLS client-credential shape:

```yaml
# OLD (mTLS, from PRs #341–#343) — remove this:
auth:
  server-cert: /path/to/server.crt
  client-cert: /path/to/ci-push.crt
  client-key:  /path/to/ci-push.key
```

with the JWT bearer-token shape:

```yaml
# NEW (JWT/EdDSA against bow):
auth:
  server-cert: /path/to/server.crt      # copy of materia's components/buildbarn/certs/server.crt
  access-token: /path/to/token          # file containing the minted JWT string
```

BuildStream's user-config docs confirm `access-token` is "path to a
token for optional HTTP bearer authentication" — it's sent as the
`Authorization: Bearer <token>` header, which is exactly what
Buildbarn's `jwt` `AuthenticationPolicy` validates against the JWKS.

- **CI:** the `push` token (GitHub Actions secret
  `BUILDBARN_PUSH_TOKEN`) written to a file at workflow start, path
  passed as `access-token`.
- **Dev machines:** the `pull` token, stored wherever you keep local
  secrets, path passed as `access-token`.

`server-cert` stays in `auth` (same place as before) — only the
client-cert/client-key pair is replaced by `access-token`.

## Verification round trip

Same procedure krytis used to validate the local mTLS design against its
own Buildbarn (PRs #341–#343), just against the remote:

1. Wipe local BuildStream cache.
2. `bst source push` + `bst artifact push` (with the `push` token).
3. Wipe local cache again.
4. `bst source fetch` + `bst artifact pull` (with the `pull` token).
5. Confirm pulling **only** from `bst-cache.<baseDomain>`, zero
   upstream requests to `gbm.gnome.org:11003` /
   `cache.projectbluefin.io:11001` (the external CAS servers krytis
   currently points at).

If push fails with `PERMISSION_DENIED`, the token's `role` claim isn't
`"push"` (you minted/installed the pull token by mistake). If it fails
with `UNAUTHENTICATED`, the `access-token` path is wrong or the file is
empty. If TLS fails, `server-cert` doesn't match the cert bow is serving
(re-copy from the materia repo).

## Server-side config reference (materia repo, read-only context)

If you need to cross-check anything against the server config:

- `components/buildbarn/config/common.libsonnet` — the JWT auth policy
  (`jwt: { jwksFile, claimsValidationJmespathExpression,
  cacheReplacementPolicy: LEAST_RECENTLY_USED, maximumCacheSize: 8,
  metadataExtractionJmespathExpression: {public: {role: payload.role}} }`)
  + the push/any authorizers.
- `components/buildbarn/config/storage.jsonnet` — bb-storage: CAS
  (100G quota), ActionCache (2G), FSAC (100M), gRPC on :7982, TLS
  server-only, diagnostics on :9981.
- `components/buildbarn/config/asset.jsonnet` — bb-asset: remote-asset
  index, `fetcher: { error: { code: 5 } }` (pure cache, never fetches
  upstream), gRPC on :7981, reaches bb-storage's CAS at
  `bb-storage:7982` by container name on `newt-net`.
- `components/buildbarn/blueprint-resources.yaml` — the two raw TCP
  Pangolin resources (site: bow, no `method` field on tcp targets).

## What NOT to change in krytis

- The `type: index` / `type: storage` split is mandatory — don't
  collapse the two entries into one. Both `source-caches` and
  `artifacts` need it (confirmed in krytis's own local testing).
- Don't re-enable the `gbm.gnome.org` / `cache.projectbluefin.io`
  entries as a fallback without an explicit decision — the whole point
  of issue #28 is a krytis-owned cache. A fallback would silently
  re-introduce the external dependency.
- Don't try to use HS256 tokens or symmetric secrets — buildbarn
  rejects them (see materia `AGENTS.md` gotcha). The tokens minted by
  `mise buildbarn:mint-token` are EdDSA; use those as-is.

## Open / future

- **bow is a temporary host.** The cache lives on bow's LVM data disk
  now, but the materia plan flags this as temporary — it may move to a
  dedicated server once real usage/load is known. The hostname
  `bst-cache.<baseDomain>` is stable (it's a Pangolin resource, not
  tied to bow's identity), so a host move would be transparent to
  krytis as long as the DNS/resource target updates on the materia
  side. No action needed in krytis if/when that happens.
- **Self-hosted runner on bow?** There's a separate uncommitted
  investigation in the materia repo
  (`specs/plans/investigation-github-runner-bow.md`) about moving
  krytis's self-hosted runner onto bow. If that lands, Buildbarn and
  the runner would be co-located — a latency optimization, not a
  requirement. The current remote setup works regardless of where CI
  runs.
