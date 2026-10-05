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
        // Stays on NVMe (/data/storage-cas); only the blocks file below moved
        // to the root SSD (#137). Scaled with the blocks file (x4). Verify
        // after a full warm that every *too_many* counter on :9981 is 0:
        // buildbarn_blobstore_hashing_key_location_map_* on this pinned image
        // (renamed buildbarn_lossymap_hash_map_* upstream on 2026-09-29).
        // Nonzero means the map is displacing entries early.
        keyLocationMapOnBlockDevice: {
          file: { path: '/data/storage-cas/key_location_map', sizeBytes: 1600 * 1024 * 1024 },
        },
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        // The per-blob ceiling this backend can store is
        // blocksOnBlockDevice.sizeBytes / (oldBlocks+currentBlocks+newBlocks+spareBlocks)
        // — independent of maximumMessageSizeBytes (a separate,
        // gRPC-transport-level limit). It must stay well above krytis's
        // assembled OCI image blob (5.89 GiB, specs/bugs/BUG-006).
        //
        // 600G on the root SSD in Buildbarn's recommended 8/24/3 (+3 spare)
        // layout: 38 blocks of ~15.8 GiB, so the ceiling is ~15.8 GiB (2.7x
        // over that blob). BUG-006 had cut this to 2/5/2/1 at 150G to raise the
        // ceiling; Buildbarn's docs warn that too few "old" blocks turn the
        // store into a FIFO rather than LRU-like, and krytis's toolchain was
        // evicted under exactly that layout (#137, krytis#1094).
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 3,
        blocksOnBlockDevice: {
          source: { file: { path: '/data/storage-cas-blocks/blocks', sizeBytes: 600 * 1024 * 1024 * 1024 } },
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
