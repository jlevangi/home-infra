#!/bin/sh
# Weekly restore test: load the newest dump of each database into a throwaway
# server and assert it has user tables. Proves the dumps are restorable, not
# just present. Runs inside a disposable postgres/mariadb container whose server
# is started in the background (127.0.0.1, data on emptyDir). A kubectl-image
# container in the same pod pings Healthchecks from /result (db images lack curl).
# MongoDB and SurrealDB dumps are only structure-checked by the nightly job.
# Table counts are compared with CREATE TABLE lines in the dump: 0 tables fails;
# fewer than expected is logged (extension types like pgvecto.rs/PostGIS are not
# in the plain test image).
# ponytail: restores into one server major version; older-major dumps restore fine,
# a source newer than the test image would need a newer test image.
set -u
SRC=${SRC:-/dumps}
ENGINE=$1   # postgres | mariadb
log() { echo "$(date -u +%H:%M:%S) $*"; }
: > /tmp/ok; : > /tmp/failed

case $ENGINE in
  postgres) q() { psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -tA "$@"; }
            until pg_isready -h 127.0.0.1 -U postgres -q; do sleep 2; done ;;
  mariadb)  q() { mariadb -h 127.0.0.1 -uroot -N "$@"; }
            until mariadb-admin -h 127.0.0.1 -uroot ping --silent; do sleep 2; done ;;
esac

for nsdir in "$SRC"/*/; do
  ns=$(basename "$nsdir")
  f=$(ls -1 "$nsdir"*."$ENGINE".gz 2>/dev/null | sort | tail -1)
  [ -n "$f" ] || continue
  log "restore $ns $(basename "$f")"
  case $ENGINE in
    postgres)
      user_dbs="select datname from pg_database where datname not in ('postgres','template0','template1')"
      for d in $(q -c "$user_dbs"); do q -c "drop database \"$d\" with (force)" >/dev/null; done
      # pg_dumpall output recreates roles too; existing-role errors are expected noise
      zcat "$f" | psql -h 127.0.0.1 -U postgres -q -o /dev/null postgres > /tmp/err 2>&1
      n=0; for d in $(q -c "$user_dbs"); do
        n=$(( n + $(q -d "$d" -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')") )); done ;;
    mariadb)
      sys="'mysql','information_schema','performance_schema','sys'"
      for d in $(q -e "select schema_name from information_schema.schemata where schema_name not in ($sys)"); do q -e "drop database \`$d\`"; done
      zcat "$f" | mariadb -h 127.0.0.1 -uroot > /tmp/err 2>&1
      n=$(q -e "select count(*) from information_schema.tables where table_schema not in ($sys)") ;;
  esac
  want=$(zcat "$f" | grep -c '^CREATE TABLE ')
  if [ "${n:-0}" -ge 1 ]; then
    [ "$n" -ge "$want" ] && log "ok   $ns: $n/$want tables" || log "PART $ns: $n/$want tables (missing extensions?)"
    echo "$ns:$n/$want" >> /tmp/ok
  else log "FAIL $ns: ${n:-0}/$want tables; $(tail -c 300 /tmp/err)"; echo "$ns" >> /tmp/failed; fi
done

msg="restore-test $ENGINE: $(wc -l < /tmp/ok) ok"
[ -s /tmp/ok ] || echo "(nothing restored)" >> /tmp/failed
[ -s /tmp/failed ] && msg="$msg, FAILED: $(tr '\n' ' ' < /tmp/failed)"
log "$msg"; echo "$msg" > /result/msg
[ -s /tmp/failed ] && exit 1 || exit 0
