local common = import 'common.libsonnet';

{
  contentAddressableStorage: {
    // newt-net container-name reachability, not localhost — unlike
    // krytis's rootless local test (Network=host, same netns as
    // bb-storage), this deployment joins the newt-net bridge network like
    // every other tunneled component here.
    grpc: { client: { address: 'bb-storage:7982' } },
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
          source: { file: { path: '/data/asset-cache/blocks', sizeBytes: 1024 * 1024 * 1024 } },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/data/asset-cache/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
  },
  // bb-remote-asset's HTTP fetcher backend cannot serve FetchDirectory
  // ("HTTP Fetching of directories is not supported") - BuildStream's
  // source cache pushes/fetches multi-file sources as CAS Directory trees,
  // not single blobs, so 'http: {}' breaks every push with PERMISSION_DENIED.
  // This is meant to be a pure cache anyway - krytis's own bst invocations
  // do the real upstream fetch and push the result here; bb-asset should
  // never reach out on its own. 'error' with NOT_FOUND (5) makes a cache
  // miss behave like an empty cache instead of attempting (and failing) a
  // live fetch. 'error' must be quoted in jsonnet - it collides with a
  // reserved keyword.
  fetcher: { 'error': { code: 5, message: 'krytis Buildbarn is a pure cache; no server-side fetcher is configured' } },
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
