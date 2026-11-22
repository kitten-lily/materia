# Buildbarn

Read this guide when changing cache auth, TLS, CAS sizing, or metrics.

- **Buildbarn's JWT and x509 auth policies use *different* proto field
  names for the same concept — don't copy one's field name onto the
  other.** The x509/mTLS `AuthenticationPolicy`
  (`TLSClientCertificateAuthenticationPolicy` in `grpc.proto`) calls its
  boolean-validation field `validation_jmespath_expression` (camelCase
  `validationJmespathExpression`). The JWT `AuthenticationPolicy`
  (`AuthorizationHeaderParserConfiguration` in `jwt.proto`) calls the
  *same concept* **`claims_validation_jmespath_expression`** (camelCase
  **`claimsValidationJmespathExpression`**) — a `claims_` prefix the
  x509 one lacks. `bb-storage` hard-fails on the wrong name at startup:
  `proto: (line N:N): unknown field "validationJmespathExpression"` (a
  protobuf unmarshal error, not a jsonnet parse error — the jsonnet
  itself is valid). The buildbarn component's `common.libsonnet`
  originally carried this exact bug (field name copied from krytis's
  tested mTLS design, which uses the x509 policy), crashing on first bow
  deploy. Confirmed against
  `github.com/buildbarn/bb-storage/pkg/proto/configuration/jwt/jwt.proto`
  + `grpc.proto`. The other JWT fields (`jwksFile` ← `jwks_file`,
  `metadataExtractionJmespathExpression` ←
  `metadata_extraction_jmespath_expression`) and the Authorizer field
  (`jmespathExpression` ← `jmespath_expression` in `auth.proto`) are
  identical across both policy types and safe to share. No CI catches
  this — the buildbarn binary parses jsonnet at runtime, and this repo
  has no jsonnet evaluator in its toolchain; the only verification path
  is a real container start.
- **Buildbarn's JWT validator only accepts asymmetric keys (Ed25519 /
  ECDSA / RSA) — not HS256/symmetric `oct` JWKS keys.**
  `bb-storage/pkg/jwt/configuration.go`'s
  `NewSignatureValidatorFromJSONWebKeySet` type switch handles only
  `*ecdsa.PublicKey`, `ed25519.PublicKey`, `*rsa.PublicKey` — there is
  no `[]byte`/symmetric case. The gate before that switch,
  go-jose v3's `JSONWebKey.Valid()`, has the same gap: it has
  `case ed25519.PublicKey:` (checks `len(key) == 32`) but no
  `case []byte:` — so `oct` JWKS keys fall to `default: return false`
  (go-jose issue #314). An HS256 JWKS (`kty: "oct"`) crashes
  `bb-storage` on startup with `Invalid JSON Web Key at index 0` —
  a *different* crash from the field-name one above (this one is at
  JWKS parsing, past config unmarshal). Confirmed against
  `github.com/buildbarn/bb-storage` (go-jose v3.0.5) + go-jose v3.0.5
  source. The buildbarn component originally used HS256 ("one shared
  secret, matches `beszel-agent`'s `beszelToken` pattern") — that
  design is fundamentally incompatible with the software and was
  switched to EdDSA (Ed25519) after live deployment proved it. The
  JWKS for Ed25519 is one `{kty: "OKP", crv: "Ed25519", x:
  <base64url of 32 raw pubkey bytes>, alg: "EdDSA"}` entry (RFC 8037);
  the private key is stored separately (`jwtPrivateKeyPem` in the
  vault) and `mise buildbarn:mint-token` signs with
  `openssl pkeyutl -sign -rawin` (Ed25519 is one-shot, not
  hash-then-sign).
- **Rotating Buildbarn's server cert is a two-repo change, and the order is
  fixed.** Clients dial the Tailscale Service name
  `bst-cache.<tailnet>.ts.net` (#163 phase 4) and verify the server
  against krytis's pinned copy (`quadlet/buildbarn/certs/bow-server.crt`).
  So the cert's SAN must be exactly that name, and a new cert breaks every
  krytis cache step until krytis carries it. Procedure: open the krytis PR
  (cert + any URL change) first; then in materia `sops unset
  attributes/bow.yml '["components"]["buildbarn"]["serverKeyPem"]'`,
  `mise buildbarn:server-cert-init --hostname bst-cache.<tailnet>.ts.net`,
  push, run materia on bow; check that `podman secret inspect --showsecret
  materia-serverKeyPem` matches the new cert (it did not on 2026-10-24, see
  the stale-secret gotcha), and that `openssl s_client -verify_hostname`
  from krytis-runner passes; then merge the krytis PR. `certs/server.crt` is
  in both services' `RestartedBy`, so the restart is automatic. krytis's
  PR CI (`build-changed`) skips building when `project.conf` changes, so it
  is no proof: run `scripts/bow-artifact-check.py --probe` with a real
  token, or a `cache-warm` dispatch.
- **Buildbarn's local CAS backend has a per-blob size ceiling completely
  independent of `maximumMessageSizeBytes` — don't assume raising the
  gRPC message-size limit alone fixes a large-blob push failure.**
  `contentAddressableStorage.backend.local` in `storage.jsonnet` divides
  `blocksOnBlockDevice.sizeBytes` into `oldBlocks + currentBlocks +
  newBlocks + spareBlocks` fixed-size blocks, and every blob must fit
  inside a single block — confirmed against
  [Buildbarn's own block-sizing writeup](https://meroton.github.io/blog/buildbarn-block-sizes/).
  The max storable blob is `blocksOnBlockDevice.sizeBytes / totalBlocks`,
  a number the original 100G/38-block sizing plan
  (`specs/plans/issue-28-bst-cache-krytis.md`, open question #6) never
  computed — it only reasoned about total CAS capacity. BUG-006: the
  100G/38-block layout (`8/24/3/3`) gave a ~2.63 GiB per-blob ceiling,
  which rejected krytis's assembled OCI image blob (confirmed 5.89 GiB)
  with gRPC `INVALID_ARGUMENT` on `UploadBlob`. Raising
  `maximumMessageSizeBytes` from 2 GiB to 8 GiB (a real but *separate*
  gRPC-transport-level limit) did not fix it — identical error on retry.
  BUG-006 first worked around it by cutting the layout to `2/5/2/1` over
  150G (15 GiB/block). That fixed the ceiling but broke something else:
  Buildbarn's docs (`blobstore.proto`, local backend) recommend 8 old /
  24 current blocks and warn that too few "old" blocks turn the store
  into a FIFO instead of LRU-like. Under 2 old blocks, krytis's
  toolchain (pushed once, never read back from bow) was evicted while
  bb-asset still indexed it (#137, krytis#1094). Since #137 the CAS
  blocks file is 600G on bow's root SSD (`/var/lib/buildbarn/`, outside
  materia's managed data dir) in `8/24/3/3`, about 15.8 GiB/block. Grow
  the file instead of starving the old group. When sizing any local
  CAS/AC/FSAC backend, compute `sizeBytes / totalBlocks` and compare
  against the largest blob you actually expect: total capacity alone
  doesn't bound the largest single object the cache can hold.
  Changing the size or block counts reshapes the ring buffer, so wipe and
  let it repopulate. **Wipe the CAS and bb-asset's index together**
  (plus AC/FSAC). Wiping only `storage-cas/` (as BUG-006's resize did)
  leaves the index naming artifacts the CAS no longer holds, and clients
  that check the index (BuildStream's `bst artifact show`) then report
  them `available`. A sparse blocks file on a shared disk can hit ENOSPC
  later, so `fallocate` it before the first start. See BUG-006 and
  `specs/plans/issue-137-buildbarn-cas-on-root-ssd.md`.
- **Buildbarn metric names follow the pinned image, not today's docs.**
  bb-storage `677f49d418` (2026-09-29) renamed the key-location-map
  metrics from `buildbarn_blobstore_hashing_key_location_map_*` to
  `buildbarn_lossymap_hash_map_*`, and Buildbarn's current docs only show
  the new name. bow's pinned `bb-storage@sha256:155fa806…` exports the
  **old** name, so a grep for the documented name on `:9981` returns
  nothing, which looks exactly like "all counters are 0". Before trusting
  an empty grep, list what the endpoint actually exports
  (`grep -oE '^buildbarn_[a-z_]+' | sort -u`). Re-check every metric name
  in this file after a bb-storage image bump.

## Resource map

```text
  buildbarn/                     # BuildStream cache server for krytis (standalone, bow-only, issue #28); clients reach it as Tailscale Service svc:bst-cache (#163)
    MANIFEST.toml                # component manifest — Secrets (jwtJwks, serverKeyPem), Services
    bb-storage.container.gotmpl   # CAS + ActionCache + FSAC, joins newt-net, bind mounts from LVM data disk
    bb-asset.container.gotmpl     # remote-asset index, joins newt-net, reaches bb-storage by container name
    config/common.libsonnet       # shared JWT auth policy + authorizers (push/pull role claim)
    config/storage.jsonnet        # bb-storage config — 150G CAS quota / 10-block layout, see BUG-006
    config/asset.jsonnet          # bb-asset config — 'error' fetcher (pure cache, never fetches on its own)
    certs/server.crt              # self-signed server TLS cert, SAN bst-cache.<tailnet>.ts.net (public; key is a materia Secret; krytis pins a copy)
```

For manual `Secret=` mount options and checking the live secret after rotation, see [Materia behaviour](materia-behaviour.md).
