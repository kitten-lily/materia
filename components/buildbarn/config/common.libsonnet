// Shared config fragments for storage.jsonnet / asset.jsonnet.
//
// Auth: JWT bearer token (EdDSA / Ed25519), not mTLS — see
// specs/plans/issue-28-bst-cache-krytis.md for the full "why" (mTLS was
// krytis's original local-test design; switched here because it drops the
// CA/client-cert distribution entirely, at the cost of not unlocking
// HTTP-resource exposure the way it was hoped to — Pangolin's raw TCP
// resource is still what's in front of this, blocked upstream on h2c
// support, fosrl/pangolin#115).
//
// Originally HS256 (symmetric, one shared secret), but buildbarn's JWT
// validator only accepts asymmetric keys — go-jose v3's Valid() returns
// false for `oct` keys (no `case []byte:`, go-jose #314) AND
// bb-storage's type switch has no symmetric case. An HS256 JWKS crashes
// bb-storage with "Invalid JSON Web Key at index 0". Switched to Ed25519
// after live deployment proved this. The JWKS is one OKP/Ed25519 public
// key (RFC 8037); the private key lives in the vault (jwtPrivateKeyPem)
// and mise buildbarn:mint-token signs with `openssl pkeyutl -sign -rawin`.
//
// Buildbarn still terminates its own TLS (server-only — no client cert
// required) for confidentiality through the Newt/Pangolin tunnel; the
// JWKS below is what verifies the bearer token's signature.
//
// jwt-jwks.json / server.key are materia Secrets (see MANIFEST.toml),
// mounted at deploy time — nothing sensitive is committed to this repo.

{
  // 8 GiB — CAS storage is provisioned generously (100G, see
  // storage.jsonnet), so the message-size ceiling costs nothing to raise
  // well past the largest observed artifact rather than tuning it
  // precisely. The prior 2 GiB limit rejected krytis's assembled OCI
  // image (oci/krytis/image.bst) with gRPC INVALID_ARGUMENT on
  // UploadBlob — see specs/bugs/BUG-006.
  maximumMessageSizeBytes: 8 * 1024 * 1024 * 1024,

  jwtAuthenticationPolicy: {
    jwt: {
      jwksFile: '/secrets/jwt-jwks.json',
      // NOTE: the JWT policy's validation field is
      // `claims_validation_jmespath_expression` (camelCase
      // `claimsValidationJmespathExpression`) — NOT `validationJmespathExpression`
      // like the x509/mTLS policy (TLSClientCertificateAuthenticationPolicy)
      // uses. The two policies use different field names for the same concept;
      // the JWT one has a `claims_` prefix the x509 one doesn't. Confirmed
      // against buildbarn/bb-storage/pkg/proto/configuration/jwt/jwt.proto —
      // the live bb-storage crash ("unknown field validationJmespathExpression"
      // at line 144) was exactly this mismatch, predicted as a risk in
      // specs/plans/issue-28-bst-cache-krytis.md.
      claimsValidationJmespathExpression: { expression: '`true`' },
      // Required: the default (unset) is UNKNOWN (proto3 zero value),
      // which NewSetFromConfiguration rejects with "Unknown cache
      // replacement policy". jwt.proto's own doc says "It is advised
      // that this is set to LEAST_RECENTLY_USED."
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
      // Token-validation cache size (in-memory, per validated token).
      // Small fleet, two long-lived tokens → a tiny cache is plenty.
      maximumCacheSize: 8,
      // Extracts the token payload's "role" claim into
      // AuthenticationMetadata.public so the Authorizer below can read it
      // back as authenticationMetadata.public.role — same mechanism
      // krytis's original mTLS design used for a cert's URI SAN, just
      // reading a JWT claim instead.
      metadataExtractionJmespathExpression: { expression: '{public: {role: payload.role}}' },
    },
  },

  // Authorizer permitting only tokens minted with role: "push"
  // (mise buildbarn:mint-token --role push). Applies to every
  // put/update-style RPC (CAS Put, ActionCache UpdateActionResult, remote
  // asset PushBlob).
  pushOnlyAuthorizer: {
    jmespathExpression: {
      expression: |||
        authenticationMetadata.public.role == 'push'
      |||,
    },
  },

  // Any client presenting a valid token (push or pull role) may read.
  anyAuthenticatedAuthorizer: { allow: {} },

  globalWithDiagnostics(listenAddress): {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [listenAddress],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: false,
      enableActiveSpans: true,
    },
  },
}
