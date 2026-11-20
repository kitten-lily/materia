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
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
# fetch URL [curl args...]: body into $tmp, prints the HTTP status, or 000
# when no response arrived (DNS, timeout, refused). Never exits on its own,
# so every failure below gets its own message (#204). Still fails closed.
fetch() {
  local url=$1 code; shift
  code=$(curl -sS -L --retry 3 --retry-all-errors --max-time 30 -o "$tmp" -w '%{http_code}' "$@" "$url") || code=000
  echo "$code"
}
api() { fetch "https://api.github.com/repos/$repo/$1" "${auth[@]}" -H 'Accept: application/vnd.github+json'; }
lookup_failed() {  # what code
  if [[ $2 == 000 ]]; then echo "::error::$1 failed (no HTTP response)"; else echo "::error::$1 failed (HTTP $2)"; fi
  exit 1
}

# Drafts answer 404 here, which is what we want: unpublished is not installable.
code=$(api "releases/tags/$tag")
case $code in
  200) rel=$(cat "$tmp") ;;
  404) echo "::error::$tag has no published release in $repo (an image tag alone is not a release)"; exit 1 ;;
  *) lookup_failed "release lookup for $tag" "$code" ;;
esac
[[ $(jq -r .draft <<<"$rel") == false && $(jq -r .tag_name <<<"$rel") == "$tag" ]] ||
  { echo "::error::$tag: release is a draft or tagged differently"; exit 1; }
url=$(jq -r '.assets[] | select(.name == "server-image.json") | .browser_download_url' <<<"$rel")
[[ -n $url ]] || { echo "::error::$tag: release has no server-image.json"; exit 1; }
code=$(fetch "$url")
[[ $code == 200 ]] || lookup_failed "$tag: server-image.json download" "$code"
manifest=$(cat "$tmp")
want=$(jq -r .indexDigest <<<"$manifest")
[[ $(jq -r .tag <<<"$manifest") == "$tag" ]] || { echo "::error::server-image.json names another tag"; exit 1; }
if [[ $want != "$digest" ]]; then
  echo "::error::pinned digest $digest does not match $tag's release manifest indexDigest $want"; exit 1
fi
echo "ok: $tag is a published release and the digest matches its manifest"
