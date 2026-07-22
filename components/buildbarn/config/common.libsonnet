// Shared config fragments for storage.jsonnet / asset.jsonnet.
//
// Auth: JWT bearer token (HS256, one shared secret), not mTLS — see
// specs/plans/issue-28-bst-cache-krytis.md for the full "why" (mTLS was
// krytis's original local-test design; switched here because it drops the
// CA/client-cert distribution entirely, at the cost of not unlocking
// HTTP-resource exposure the way it was hoped to — Pangolin's raw TCP
// resource is still what's in front of this, blocked upstream on h2c
// support, fosrl/pangolin#115).
//
// Buildbarn still terminates its own TLS (server-only — no client cert
// required) for confidentiality through the Newt/Pangolin tunnel; the
// JWKS below is what verifies the bearer token's signature. Note that for
// HS256 (symmetric), the JWKS "k" field IS effectively the shared secret
// in a different encoding — there is no actual public/private key split
// here, same as the underlying secret used to mint tokens
// (mise buildbarn:mint-token). This is an accepted tradeoff of the
// single-shared-secret design, not an oversight.
//
// jwt-jwks.json / server.key are materia Secrets (see MANIFEST.toml),
// mounted at deploy time — nothing sensitive is committed to this repo.

{
  maximumMessageSizeBytes: 2 * 1024 * 1024 * 1024,

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
