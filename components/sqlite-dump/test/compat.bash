#!/usr/bin/env bash
# sqlite-dump compatibility check (#195): dump.cjs needs Node and
# better-sqlite3 from the Pangolin image it runs on. Renovate automerges
# Pangolin bumps without waiting for checks, so this runs in CI after a bump
# (sqlite-dump-compat.yml) and catches an image that changed either.
# Builds a WAL fixture, runs `dump` and `check`, and verifies the .done hashes.
# Usage: compat.bash <dump.cjs> <image>   (exit 0 = compatible)
set -euo pipefail
script=$(realpath "$1"); image=$2
t=$(mktemp -d); trap 'podman unshare rm -rf "$t" 2>/dev/null || rm -rf "$t"' EXIT
mkdir -p "$t/src" "$t/dumps"
run() { podman run --rm -e NODE_PATH=/app/node_modules -v "$t/src:/src:z" -v "$t/dumps:/dumps:z" \
  -v "$script:/dump.cjs:ro,z" --entrypoint node "$image" "$@"; }

run -e "const D=require('better-sqlite3');const db=new D('/src/app.db');db.pragma('journal_mode = WAL');
db.exec('CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT); CREATE TABLE b(id INTEGER PRIMARY KEY)');
const i=db.prepare('INSERT INTO a(v) VALUES (?)');for(let n=0;n<100;n++)i.run('x'+n);db.exec('INSERT INTO b VALUES (1),(2)');"

out=$(run /dump.cjs dump compat /src/app.db)
[[ $out == 'dumped compat: '*' bytes, 2 tables' ]] || { echo "FAIL dump: $out"; exit 1; }
counts=$(cat "$t/dumps/compat.counts" 2>/dev/null || podman unshare cat "$t/dumps/compat.counts")
[[ $counts == $'a\t100\nb\t2' ]] || { echo "FAIL counts: $counts"; exit 1; }
chk=$(run /dump.cjs check /dumps/compat.sqlite /dumps/compat.counts)
[[ $chk == 'ok 2 tables' ]] || { echo "FAIL check: $chk"; exit 1; }
run -e "const fs=require('fs'),c=require('crypto');const l=fs.readFileSync('/dumps/compat.done','utf8').split('\n');
for (const x of l.slice(1).filter(Boolean)){const [h,f]=x.split('  ');
if(c.createHash('sha256').update(fs.readFileSync('/dumps/'+f)).digest('hex')!==h){console.error('hash mismatch: '+f);process.exit(1)}}"
echo "ok: dump.cjs works on $image"
