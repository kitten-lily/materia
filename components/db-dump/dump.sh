#!/bin/bash
# Logical dump of one application database into /dumps (#194).
#
# Runs inside the official mariadb/postgres image (same pin as the server),
# from a db-dump-<name>.container quadlet. Writes, per database:
#   <name>.counts.pre   exact per-table row counts before the dump
#   <name>.sql          the dump (application database only)
#   <name>.counts.post  row counts after the dump
#   <name>.done         UTC completion time, written last
# Everything is written as .tmp and renamed only on success, so a failed or
# killed run leaves the previous set untouched. A restore is valid when
# <name>.done is fresh and every restored table count lies in [pre, post].
set -euo pipefail
: "${DB_KIND:?}" "${DB_HOST:?}" "${DB_NAME:?}" "${DB_USER:?}"

out=/dumps/$DB_NAME
umask 077
chmod 0700 /dumps
# A run killed with SIGKILL can't clean up after itself; the next one does.
rm -f "$out".*.tmp
trap 'rm -f "$out".*.tmp' EXIT

maria() { mariadb -h "$DB_HOST" -u"$DB_USER" --connect-timeout=10 -N "$@"; }
pg() { psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -At "$@"; }

# "<schema>.<table><TAB><count>", one line per table, sorted.
counts() {
  case $DB_KIND in
    mariadb)
      maria -e "SELECT CONCAT('SELECT ''', table_schema, '.', table_name, ''', COUNT(*) FROM \`', table_schema, '\`.\`', table_name, '\`;') FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema = '$DB_NAME'" |
        maria ;;
    postgres)
      pg -c "SELECT format('SELECT %L || chr(9) || count(*) FROM %I.%I;', schemaname || '.' || relname, schemaname, relname) FROM pg_stat_user_tables" |
        pg ;;
    *) echo "unknown DB_KIND: $DB_KIND" >&2; exit 2 ;;
  esac | LC_ALL=C sort
}

dump() {
  case $DB_KIND in
    mariadb)
      # mariadb-dump has no --connect-timeout; the pre-dump counts above already
      # connected with one, so the server was reachable a moment ago.
      mariadb-dump -h "$DB_HOST" -u"$DB_USER" --databases "$DB_NAME" \
        --single-transaction --routines --events --triggers ;;
    postgres)
      pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" ;;
  esac
}

counts > "$out.counts.pre.tmp"
dump > "$out.sql.tmp"
counts > "$out.counts.post.tmp"
[[ -s $out.sql.tmp ]] || { echo "empty dump" >&2; exit 1; }

mv "$out.counts.pre.tmp" "$out.counts.pre"
mv "$out.sql.tmp" "$out.sql"
mv "$out.counts.post.tmp" "$out.counts.post"
date -u +%FT%TZ > "$out.done.tmp"
mv "$out.done.tmp" "$out.done"
echo "dumped $DB_NAME: $(wc -c < "$out.sql") bytes, $(wc -l < "$out.counts.pre") tables"
