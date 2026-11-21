local common = import 'common.libsonnet';

{
  contentAddressableStorage: {
    // Both containers share the pod's network namespace.
    grpc: { client: { address: 'localhost:7982' } },
  },
  assetCache: {
    blobAccess: {
      'local': {
        keyLocationMapOnBlockDevice: {
          file: { path: '/data/asset-cache/key_location_map', sizeBytes: 1024 * 1024 },
        },
        keyLocationMapMaximumGetAttempts: 8,
        keyLocationMapMaximumPutAttempts: 32,
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 1,
        blocksOnBlockDevice: {
          source: { file: { path: '/data/asset-cache/blocks', sizeBytes: 64 * 1024 * 1024 } },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/data/asset-cache/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
  },
  // Return NOT_FOUND on a miss. BuildStream fetches from upstream and
  // pushes results here, including multi-file sources as CAS directories.
  fetcher: { 'error': { code: 5, message: 'Bluefin pilot Buildbarn has no server-side fetcher' } },
  global: common.globalWithDiagnostics(':9982'),
  grpcServers: [{
    listenAddresses: [':7981'],
    tls: {
      serverKeyPair: {
        files: {
          certificatePath: '/certs/server.crt',
          privateKeyPath: '/secrets/server.key',
          refreshInterval: '3600s',
        },
      },
    },
    authenticationPolicy: common.jwtAuthenticationPolicy,
  }],
  allowUpdatesForInstances: [''],
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  fetchAuthorizer: common.anyAuthenticatedAuthorizer,
  pushAuthorizer: common.pushOnlyAuthorizer,
}
