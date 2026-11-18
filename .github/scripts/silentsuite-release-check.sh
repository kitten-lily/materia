#!/usr/bin/env bash
# Fails unless the SilentSuite server image pinned in the given quadlet is a
# PUBLISHED GitHub release whose server-image.json indexDigest equals the
# pinned digest (#192). GHCR tags appear before their release is published
# (v0.5.21-beta did), and Renovate only sees GHCR, so this is the merge gate.
# Usage: silentsuite-release-check.sh components/silentsuite/silentsuite.container.gotmpl
set -euo pipefail
repo=silent-suite/silentsuite
image=ghcr.io/silent-suite/silentsuite-server

line=$(grep -m1 "^Image=$image:" "$1") || { echo "::error::no Image=$image:... line in $1"; exit 1; }
ref=${line#Image="$image":}
tag=${ref%@*}
digest=${ref#*@}
[[ $ref == *@sha256:* && $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::$image must be pinned tag@sha256:<digest>, got '$ref'"; exit 1; }
echo "pinned: $tag @ $digest"

auth=()
[[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
api() { curl -fsS --retry 3 --max-time 30 "${auth[@]}" -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$repo/$1"; }

# Drafts answer 404 here, which is what we want: unpublished is not installable.
if ! rel=$(api "releases/tags/$tag"); then
  echo "::error::$tag has no published release in $repo (an image tag alone is not a release)"; exit 1
fi
[[ $(jq -r .draft <<<"$rel") == false && $(jq -r .tag_name <<<"$rel") == "$tag" ]] ||
  { echo "::error::$tag: release is a draft or tagged differently"; exit 1; }
url=$(jq -r '.assets[] | select(.name == "server-image.json") | .browser_download_url' <<<"$rel")
[[ -n $url ]] || { echo "::error::$tag: release has no server-image.json"; exit 1; }
manifest=$(curl -fsSL --retry 3 --max-time 30 "$url")
want=$(jq -r .indexDigest <<<"$manifest")
[[ $(jq -r .tag <<<"$manifest") == "$tag" ]] || { echo "::error::server-image.json names another tag"; exit 1; }
if [[ $want != "$digest" ]]; then
  echo "::error::pinned digest $digest does not match $tag's release manifest indexDigest $want"; exit 1
fi
echo "ok: $tag is a published release and the digest matches its manifest"
