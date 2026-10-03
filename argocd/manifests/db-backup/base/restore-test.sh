#!/bin/sh
# Weekly restore test. For every labelled database (same label as db-dump.sh):
#   1. create namespace restore-test-<ns>
#   2. start a throwaway DB pod from the SOURCE workload's own image, so
#      versions and extensions (pgvecto.rs, PostGIS, supabase) match
#   3. mount the dump folder from the NAS read-only into it and restore from
#      the file (streaming large dumps over `kubectl exec -i` can hang at EOF)
#   4. require the restored table count to match the dump; mongodb must
#      restore >0 documents with 0 failed
#   5. delete the namespace
# New databases need no change here: label the workload and it gets tested.
# The pod lives only as long as its namespace; data stays in its own container.
set -u
SRC=${SRC:-/dumps}
HC=${HC_URL:-}
SEL=backup.levangie.dev/restore-test=true
ping() { [ -n "$HC" ] && curl -fsS --max-time 20 --retry 3 "$HC$1" -o /dev/null --data-binary "${2:-}"; return 0; }
log() { echo "$(date -u +%H:%M:%S) $*"; }
: > /tmp/ok; : > /tmp/failed

ping /start
kubectl delete ns -l "$SEL" --wait=true >/dev/null 2>&1   # leftovers from a killed run
trap 'kubectl delete ns -l "$SEL" --wait=false >/dev/null 2>&1' EXIT

targets=$(kubectl get deployments,statefulsets -A -l backup.levangie.dev/engine \
  -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.labels.backup\.levangie\.dev/engine} {.spec.replicas} {.spec.template.spec.containers[0].image}{"\n"}{end}')

test_one() {  # ns engine image dumpfile -> prints "restored/expected"; non-zero = fail
  ns=$1 engine=$2 image=$3 f=$4 t=restore-test-$1
  case $engine in
    postgres)  env='[{"name":"POSTGRES_PASSWORD","value":"restore-test"},{"name":"POSTGRES_HOST_AUTH_METHOD","value":"trust"}]'; args='' ;;
    mariadb)   env='[{"name":"MARIADB_ALLOW_EMPTY_ROOT_PASSWORD","value":"1"}]'; args='' ;;
    mongodb)   env='[{"name":"ALLOW_EMPTY_PASSWORD","value":"yes"}]'; args='' ;;
    surrealdb) env='[]'; args='"args":["start","--user","root","--pass","root","memory"],' ;;
  esac
  kubectl create ns "$t" >/dev/null && kubectl label ns "$t" "$SEL" >/dev/null || return 1
  kubectl -n "$t" apply -f - >/dev/null <<EOF || return 1
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"db"},
 "spec":{"restartPolicy":"Never","automountServiceAccountToken":false,
  "volumes":[{"name":"dump","nfs":{"server":"172.20.20.5","path":"/volume1/k3s-storage/db-dumps/$ns","readOnly":true}}],
  "containers":[{"name":"db","image":"$image",$args"env":$env,
   "volumeMounts":[{"name":"dump","mountPath":"/dump","readOnly":true}],
   "resources":{"requests":{"cpu":"250m","memory":"512Mi"},"limits":{"memory":"4Gi"}}}]}}
EOF
  kubectl -n "$t" wait --for=condition=Ready pod/db --timeout=600s >/dev/null || return 1
  x() { kubectl -n "$t" exec db -- sh -c "$1"; }
  d=/dump/$(basename "$f")
  # wait for the server (not the entrypoint's init-time temp server) to accept TCP
  case $engine in
    postgres)  ready='pg_isready -q -h 127.0.0.1 -U postgres' ;;
    mariadb)   ready='mariadb-admin -h 127.0.0.1 -uroot ping --silent' ;;
    mongodb)   ready='mongosh --quiet --eval 1' ;;
    surrealdb) ip=$(kubectl -n "$t" get pod db -o jsonpath='{.status.podIP}')
               ready=''; s="curl -fsS --max-time 600 -u root:root -H surreal-ns:rt -H surreal-db:rt -H Accept:application/json http://$ip:8000" ;;
  esac
  for i in $(seq 120); do
    if [ -n "$ready" ]; then x "$ready" >/dev/null 2>&1 && break; else $s/health >/dev/null 2>&1 && break; fi
    sleep 5
  done
  case $engine in
    postgres)
      x "zcat $d | psql -q -o /dev/null -h 127.0.0.1 -U postgres postgres" >/dev/null 2>/tmp/err
      n=$(x 'for d in $(psql -h 127.0.0.1 -U postgres -tAc "select datname from pg_database where not datistemplate"); do
               psql -h 127.0.0.1 -U postgres -d "$d" -tAc "select count(*) from pg_tables where schemaname not in ('"'pg_catalog','information_schema'"')"; done' | awk '{s+=$1} END {print s+0}')
      want=$(zcat "$f" | grep -c '^CREATE TABLE ') ;;
    mariadb)
      x "zcat $d | mariadb -h 127.0.0.1 -uroot" 2>/tmp/err
      n=$(x "mariadb -h 127.0.0.1 -uroot -N -e \"select count(*) from information_schema.tables where table_schema not in ('mysql','information_schema','performance_schema','sys')\"")
      want=$(zcat "$f" | grep -c '^CREATE TABLE ') ;;
    mongodb)
      x "zcat $d | mongorestore --archive" 2>/tmp/err
      n=$(sed -n 's/.* \([0-9]*\) document(s) restored successfully.*/\1/p' /tmp/err | tail -1)
      bad=$(sed -n 's/.* \([0-9]*\) document(s) failed to restore.*/\1/p' /tmp/err | tail -1)
      want=$(( ${n:-0} + ${bad:-1} )) ;;
    surrealdb)
      zcat "$f" | $s/import --data-binary @- -o /dev/null 2>/tmp/err
      n=$($s/sql -d 'INFO FOR DB;' 2>>/tmp/err | jq '.[0].result.tables | length')
      want=$(zcat "$f" | grep -c '^DEFINE TABLE ') ;;
  esac
  echo "${n:-0}/$want"
  [ "${n:-0}" -ge 1 ] && [ "${n:-0}" -ge "$want" ]
}

# fd 3: kubectl inside the loop must not eat the target list on stdin
while read -r ns engine replicas image <&3; do
  [ -n "$ns" ] || continue
  [ "${replicas:-1}" = 0 ] && { log "skip $ns (scaled to 0)"; continue; }
  # SurrealDB is labelled on the app pod (dump runs there); test with the DB's image
  [ "$engine" = surrealdb ] && image=$(kubectl -n "$ns" get deploy -o jsonpath='{..containers[*].image}' | tr ' ' '\n' | grep -m1 surrealdb)
  f=$(ls -1 "$SRC/$ns/"*."$engine".gz 2>/dev/null | sort | tail -1)
  [ -n "$f" ] || { log "FAIL $ns: no dump found"; echo "$ns" >> /tmp/failed; continue; }
  log "test $ns ($engine, $(basename "$f"), ${image##*/})"
  if r=$(test_one "$ns" "$engine" "$image" "$f"); then log "ok   $ns: $r"; echo "$ns" >> /tmp/ok
  else log "FAIL $ns: ${r:-setup failed} $(tail -c 300 /tmp/err 2>/dev/null)"; echo "$ns" >> /tmp/failed; fi
  kubectl delete ns "restore-test-$ns" --wait=true >/dev/null 2>&1
  : > /tmp/err
done 3<<EOF
$targets
EOF

msg="restore-test: $(wc -l < /tmp/ok) ok"
[ -s /tmp/failed ] && { msg="$msg, FAILED: $(tr '\n' ' ' < /tmp/failed)"; log "$msg"; ping /fail "$msg"; exit 1; }
log "$msg"; ping "" "$msg"
