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
        keyLocationMapOnBlockDevice: {
          file: { path: '/data/storage-cas/key_location_map', sizeBytes: 400 * 1024 * 1024 },
        },
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        // The per-blob ceiling this backend can store is
        // blocksOnBlockDevice.sizeBytes / (oldBlocks+currentBlocks+newBlocks+spareBlocks)
        // — independent of maximumMessageSizeBytes (a separate,
        // gRPC-transport-level limit). The original 100G/38-block layout
        // (8/24/3/3) gave a ~2.63 GiB ceiling, which rejected krytis's
        // assembled OCI image blob (5.89 GiB) with INVALID_ARGUMENT —
        // see specs/bugs/BUG-006. 150G/10 blocks (2/5/2/1) gives a
        // 15 GiB ceiling (2.5x margin over that blob), sized against
        // bow's data disk headroom (357G free of 5.5T, 94% utilized) at
        // fix time — an explicit +50G-over-original tradeoff for finer
        // granularity than the minimal-disk-cost alternative.
        oldBlocks: 2,
        currentBlocks: 5,
        newBlocks: 2,
        blocksOnBlockDevice: {
          source: { file: { path: '/data/storage-cas/blocks', sizeBytes: 150 * 1024 * 1024 * 1024 } },
          spareBlocks: 1,
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
          source: { file: { path: '/data/storage-ac/blocks', sizeBytes: 2 * 1024 * 1024 * 1024 } },
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
          source: { file: { path: '/data/storage-fsac/blocks', sizeBytes: 100 * 1024 * 1024 } },
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
