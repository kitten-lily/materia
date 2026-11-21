#!/bin/sh
# Bluefin pilot (#179) Phase 3 step 0: lay out and fill the pilot data LV, or
# verify it. Design: specs/plans/bluefin-server-pilot-phase3.md.
#
#   pilot-data-fixtures.sh create <fs-uuid>   one-off: directories + fixtures
#   pilot-data-fixtures.sh verify <fs-uuid>   checksums against the manifest
#
# Both refuse unless /var/lib/pilot-data is the expected filesystem, so a
# missing mount can never send writes to the root disk.
set -eu
M=/var/lib/pilot-data
SUMS=$M/.pilot-fixtures.sha256
FILES="video/Movies/Pilot?Movie?(2026)/Pilot?Movie?(2026).mkv
video/TVShows/Pilot?Show/Season?01/Pilot?Show?S01E01.mkv
video/Downloads/random-256M.bin video/Downloads/hardlink-src.mkv
video/Movies/hardlink-dst.mkv"
mode=${1:?create or verify}
want=${2:?filesystem UUID}

have=$(findmnt -no UUID --mountpoint "$M" 2>/dev/null || true)
[ "$have" = "$want" ] || { echo "refusing: $M is '${have:-not mounted}', expected $want" >&2; exit 1; }

case "$mode" in
create)
	[ ! -s "$SUMS" ] || { echo "refusing: fixtures already exist ($SUMS)" >&2; exit 1; }
	mkdir -p "$M/video/Movies/Pilot Movie (2026)" "$M/video/TVShows/Pilot Show/Season 01" \
		"$M/video/Downloads" "$M/postgres" "$M/buildbarn" "$M/dumps" \
		"$M/jellyfin-config" "$M/mediamanager-images"
	# Rerun-safe: files written by an interrupted run are overwritten.
	rm -f "$M/video/Movies/hardlink-dst.mkv"
	head -c 33554432 /dev/urandom > "$M/video/Movies/Pilot Movie (2026)/Pilot Movie (2026).mkv"
	head -c 16777216 /dev/urandom > "$M/video/TVShows/Pilot Show/Season 01/Pilot Show S01E01.mkv"
	head -c 268435456 /dev/urandom > "$M/video/Downloads/random-256M.bin"
	# A hardlink pair across library directories, as MediaManager makes them.
	head -c 1048576 /dev/urandom > "$M/video/Downloads/hardlink-src.mkv"
	ln "$M/video/Downloads/hardlink-src.mkv" "$M/video/Movies/hardlink-dst.mkv"
	# UID 1000 owns what MediaManager writes (production gotcha); postgres's
	# entrypoint chowns its own directory; Jellyfin runs as root.
	chown -R 1000:1000 "$M/video" "$M/mediamanager-images" "$M/dumps"
	# Bluefin has neither find nor xargs: the fixture list is explicit.
	# shellcheck disable=SC2086 # FILES is a list of glob patterns, split on purpose
	(cd "$M" && sha256sum $FILES) > "$SUMS"
	cat "$SUMS"
	;;
verify)
	(cd "$M" && sha256sum -c --quiet "$SUMS") && echo "fixtures ok ($(wc -l < "$SUMS") files)"
	src=$(stat -c %i "$M/video/Downloads/hardlink-src.mkv"); dst=$(stat -c %i "$M/video/Movies/hardlink-dst.mkv")
	[ "$src" = "$dst" ] && echo "hardlink pair ok (inode $src)"
	;;
*) echo "usage: $0 create|verify <fs-uuid>" >&2; exit 2 ;;
esac
