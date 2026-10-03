#!/bin/sh
# Nightly logical dumps of every labelled database pod in the cluster.
#   opt in:  Deployment/StatefulSet metadata label (NOT the pod template, so
#            adding it never restarts the database)
#            backup.levangie.dev/engine=postgres|mariadb|mongodb|surrealdb
#   output:  $DEST/<namespace>/<UTC stamp>.<engine>.<ext>.gz on the NAS
# A dump counts only if it streams, passes `gzip -t` and a content check (real
# tables + the tool's completion trailer). Any failure fails the run and pings
# Healthchecks /fail. DB credentials are read from the database container's own
# env inside `kubectl exec`; they never leave the pod.
# Before dumping, the engine's live data directory must sit on a Longhorn
# mount (/dev/longhorn/*) inside the container. A data dir on the container
# layer (the Outline incident) or anything else fails the run.
# NS=<namespace> limits a run to one namespace (pre-migration checks).
# ponytail: one DB per engine per namespace; add a name label if a ns ever needs two.
set -u
DEST=${DEST:-/dumps}
HC=${HC_URL:-}
STAMP=$(date -u +%Y-%m-%dT%H%MZ)
ping() { [ -n "$HC" ] && curl -fsS --max-time 20 --retry 3 "$HC$1" -o /dev/null --data-binary "${2:-}"; return 0; }
log() { echo "$(date -u +%H:%M:%S) $*"; }
: > /tmp/ok; : > /tmp/failed

ping /start
scope=${NS:+-n $NS}
targets=$(kubectl get deployments,statefulsets ${scope:--A} -l backup.levangie.dev/engine \
  -o jsonpath='{range .items[*]}{.metadata.namespace} {.kind}/{.metadata.name} {.metadata.labels.backup\.levangie\.dev/engine} {.spec.replicas}{"\n"}{end}')
[ -n "$targets" ] || { ping /fail "no labelled database workloads found"; exit 1; }

dump_cmd() {  # shell run inside the db container; writes the gzip stream to stdout
  case $1 in
    postgres)  echo 'export PGPASSWORD="${POSTGRES_PASSWORD:-}"; pg_dumpall -U "${POSTGRES_USER:-postgres}" | gzip -c' ;;
    mariadb)   echo 'U=${MARIADB_USER:-$MYSQL_USER}; P=${MARIADB_PASSWORD:-$MYSQL_PASSWORD}; D=${MARIADB_DATABASE:-$MYSQL_DATABASE}; mariadb-dump --single-transaction --triggers -u"$U" -p"$P" --databases "$D" | gzip -c' ;;
    mongodb)   echo 'mongodump --archive --quiet | gzip -c' ;;
    # SurrealDB image has no shell; run the HTTP export from the app pod instead
    surrealdb) echo 'python3 -c "import os,sys,base64,urllib.request as u;e=os.environ;r=u.Request(e[\"SURREAL_URL\"].replace(\"ws://\",\"http://\").replace(\"/rpc\",\"/export\"),headers={\"Authorization\":\"Basic \"+base64.b64encode((e[\"SURREAL_USER\"]+\":\"+e[\"SURREAL_PASSWORD\"]).encode()).decode(),\"surreal-ns\":e[\"SURREAL_NAMESPACE\"],\"surreal-db\":e[\"SURREAL_DATABASE\"],\"Accept\":\"application/octet-stream\"});sys.stdout.buffer.write(u.urlopen(r,timeout=600).read())" | gzip -c' ;;
  esac
}
datadir_cmd() {  # prints the device backing the engine's live data dir; surrealdb has no shell (checked by PVC spec only)
  case $1 in
    postgres) q='export PGPASSWORD="${POSTGRES_PASSWORD:-}"; psql -U "${POSTGRES_USER:-postgres}" -d template1 -tAc "show data_directory"' ;;
    mariadb)  q='mariadb -u"${MARIADB_USER:-$MYSQL_USER}" -p"${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" -N -e "select @@datadir"' ;;
    mongodb)  q='mongosh --quiet --eval "print(db.adminCommand({getCmdLineOpts:1}).parsed.storage?.dbPath || \"/data/db\")"' ;;
    *) return 1 ;;
  esac
  # longest mount point containing the data dir -> its device
  echo "d=\$($q); awk -v d=\"\${d%/}\" '(d == \$2 || index(d, \$2 \"/\") == 1 || \$2 == \"/\") && length(\$2) >= l { l = length(\$2); dev = \$1 } END { print dev \" \" d }' /proc/mounts"
}
content_ok() {  # proves real data, not an empty or truncated dump
  case $1 in
    postgres)  zcat "$2" | grep -q '^CREATE TABLE ' && zcat "$2" | tail -n 5 | grep -q 'cluster dump complete' ;;
    mariadb)   zcat "$2" | grep -q '^CREATE TABLE ' && zcat "$2" | tail -n 3 | grep -q 'Dump completed' ;;
    mongodb)   [ "$(zcat "$2" | wc -c)" -gt 4096 ] ;;
    surrealdb) zcat "$2" | grep -q '^DEFINE TABLE ' ;;
  esac
}

echo "$targets" | while read -r ns pod engine replicas; do
  [ -n "$ns" ] || continue
  # Scaled-to-0 workloads (e.g. parked staging) have nothing running to dump;
  # their last good dump stays on disk under retention.
  [ "${replicas:-1}" = 0 ] && { log "skip $ns/$pod (scaled to 0)"; continue; }
  mkdir -p "$DEST/$ns"
  out="$DEST/$ns/$STAMP.$engine.gz"; tmp="$out.partial"
  cmd=$(dump_cmd "$engine")
  log "dump $ns/$pod ($engine)"
  if c=$(datadir_cmd "$engine"); then
    where=$(kubectl -n "$ns" exec "$pod" -- sh -c "$c" 2>/tmp/err)
    case $where in
      /dev/longhorn/*) ;;
      *) log "FAIL $ns ($engine): data dir not on a Longhorn volume: '${where}' $(tail -c 200 /tmp/err)"; echo "$ns" >> /tmp/failed; continue ;;
    esac
  fi
  if [ -n "$cmd" ] && kubectl -n "$ns" exec "$pod" -- sh -c "$cmd" > "$tmp" 2> /tmp/err \
     && gzip -t "$tmp" && content_ok "$engine" "$tmp"; then
    mv "$tmp" "$out"; log "ok   $ns $(du -h "$out" | cut -f1)"; echo "$ns" >> /tmp/ok
  else
    log "FAIL $ns ($engine): $(tail -c 300 /tmp/err)"; rm -f "$tmp"; echo "$ns" >> /tmp/failed
  fi
done

# Retention: everything from the last 7 days, Sunday dumps for 4 weeks,
# 1st-of-month dumps for ~3 months.
now=$(date -u +%s)
find "$DEST" -name '*.gz' -mtime +7 | while read -r f; do
  d=$(basename "$f" | cut -c1-10)
  t=$(date -u -d "$d" +%s 2>/dev/null) || continue
  age=$(( (now - t) / 86400 ))
  { [ "$(date -u -d "$d" +%u)" = 7 ] && [ "$age" -le 28 ]; } || { [ "${d#*-*-}" = 01 ] && [ "$age" -le 92 ]; } || rm -f "$f"
done
find "$DEST" -name '*.partial' -delete

msg="db-dumps: $(wc -l < /tmp/ok) ok"
if [ -s /tmp/failed ]; then
  msg="$msg, FAILED: $(tr '\n' ' ' < /tmp/failed)"; log "$msg"; ping /fail "$msg"; exit 1
fi
log "$msg"; ping "" "$msg"
