# Story e01s09 — Renovate: cover restic-backup image digest

**type:** chore
**risk:** P2
**context:** infra
**epic:** e01-restic-backup
**source:** https://github.com/kitten-lily/materia/issues/2
**blocks_on:** e01s05 (the `.container.gotmpl` must exist to verify against)

## Context

The image's `resticVersion`/`opensshVersion` source pins are owned by #17's
Dockerfile `customManagers` (already present in `renovate.json5`, and
confirmed live — `origin/renovate/restic-restic-0.x` exists in the repo's
remote branches, meaning Renovate has already opened at least one PR from
the `resticVersion` custom regex manager). This story only needed to confirm
the **digest pin** in `restic-backup.container.gotmpl`
(`Image=ghcr.io/kitten-lily/materia/restic-backup@sha256:...`) is covered.

## Finding: no config change needed

`renovate.json5`'s native `quadlet` manager is already extended repo-wide:

```json5
quadlet: {
  managerFilePatterns: ["/.+\\.container\\.gotmpl$/"],
},
```

This regex is unscoped to any component directory — it matches any
`*.container.gotmpl` file anywhere in the repo. Verified:

```
components/restic-backup/restic-backup.container.gotmpl -> matches: true
components/pangolin/app.container.gotmpl                -> matches: true
components/pangolin/traefik.container.gotmpl             -> matches: true
components/restic-backup/restic-backup.timer.gotmpl      -> matches: false (correct — not a .container file)
```

Also confirmed no other `packageRules` entry accidentally excludes or
misclassifies the new image:

- The digest-only automerge rule (`matchUpdateTypes: ["digest"]`) has no
  `matchPackageNames` filter — applies repo-wide, including
  `ghcr.io/kitten-lily/materia/restic-backup`.
- The `"pangolin stack"` grouping rule matches `/fosrl//` only —
  `ghcr.io/kitten-lily/materia/restic-backup` doesn't match, so it won't be
  incorrectly bundled into pangolin/gerbil's group.
- The `ee-` regex versioning rule targets `docker.io/fosrl/pangolin` by
  exact package name — doesn't apply here.

## Steps

1. Verify the `quadlet.managerFilePatterns` regex matches
   `components/restic-backup/restic-backup.container.gotmpl`. → verify: JS
   regex test, see Finding above — `true`.
2. Verify no `packageRules` entry misroutes or excludes the new image. →
   verify: manual review of `matchPackageNames`/`matchUpdateTypes` filters
   in `renovate.json5` — none apply/exclude incorrectly.
3. No file changes required.

## Out of scope

- AGENTS.md documentation — e01s10.
- Local verification — e01s11.

## Risks

None — this story is verification-only; it made no config changes, so there
is no new risk surface. The existing Renovate config already generalizes
correctly to new components following the established `.container.gotmpl`
convention.
