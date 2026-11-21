local common = import 'common.libsonnet';

{
  grpcServers: [{
    listenAddresses: [':7982'],
    tls: {
      serverKeyPair: {
        files: {
          certificatePath: '/certs/server.crt',
          privateKeyPath: '/secrets/server.key',
          // Required even for a cert that won't be rotated — Files.refresh_interval
          // being unset (nil Duration) is a hard error, not a "never refresh" default.
          refreshInterval: '3600s',
        },
      },
    },
    authenticationPolicy: common.jwtAuthenticationPolicy,
  }],
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.globalWithDiagnostics(':9981'),

  contentAddressableStorage: {
    backend: {
      'local': {
        // Check buildbarn_blobstore_hashing_key_location_map_*too_many*
        // counters on :9981 for map pressure on this pinned image.
        keyLocationMapOnBlockDevice: {
          file: { path: '/data/storage-cas/key_location_map', sizeBytes: 16 * 1024 * 1024 },
        },
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        // 4 GiB / (8 + 24 + 3 + 3) gives a ~108 MiB per-blob ceiling.
        // The 256 MiB gRPC message limit applies separately.
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 3,
        blocksOnBlockDevice: {
          source: { file: { path: '/data/storage-cas/blocks', sizeBytes: 4 * 1024 * 1024 * 1024 } },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/data/storage-cas/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
    getAuthorizer: common.anyAuthenticatedAuthorizer,
    putAuthorizer: common.pushOnlyAuthorizer,
    findMissingAuthorizer: common.anyAuthenticatedAuthorizer,
  },

  actionCache: {
    backend: {
      'local': {
        keyLocationMapOnBlockDevice: {
          file: { path: '/data/storage-ac/key_location_map', sizeBytes: 1024 * 1024 },
        },
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 1,
        blocksOnBlockDevice: {
          source: { file: { path: '/data/storage-ac/blocks', sizeBytes: 64 * 1024 * 1024 } },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/data/storage-ac/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
    getAuthorizer: common.anyAuthenticatedAuthorizer,
    putAuthorizer: common.pushOnlyAuthorizer,
  },

  fileSystemAccessCache: {
    backend: {
      'local': {
        keyLocationMapOnBlockDevice: {
          file: { path: '/data/storage-fsac/key_location_map', sizeBytes: 1024 * 1024 },
        },
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 1,
        blocksOnBlockDevice: {
          source: { file: { path: '/data/storage-fsac/blocks', sizeBytes: 16 * 1024 * 1024 } },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/data/storage-fsac/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
    getAuthorizer: common.anyAuthenticatedAuthorizer,
    putAuthorizer: common.pushOnlyAuthorizer,
  },
}
