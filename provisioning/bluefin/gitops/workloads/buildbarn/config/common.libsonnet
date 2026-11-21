// Shared pilot config. TLS terminates in each Buildbarn container.
// The buildbarn Secret supplies the certificate, private key, and an
// EdDSA JWKS containing an OKP/Ed25519 public key.
{
  maximumMessageSizeBytes: 256 * 1024 * 1024,

  jwtAuthenticationPolicy: {
    jwt: {
      jwksFile: '/secrets/jwt-jwks.json',
      // JWT validation uses the claims_ prefix in the protobuf field.
      claimsValidationJmespathExpression: { expression: '`true`' },
      // Required: the default (unset) is UNKNOWN (proto3 zero value),
      // which NewSetFromConfiguration rejects with "Unknown cache
      // replacement policy". jwt.proto's own doc says "It is advised
      // that this is set to LEAST_RECENTLY_USED."
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
      maximumCacheSize: 8,
      // Copy the JWT role claim into the metadata used by the authorizer.
      metadataExtractionJmespathExpression: { expression: '{public: {role: payload.role}}' },
    },
  },

  // Grant writes only to callers with role "push".
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
