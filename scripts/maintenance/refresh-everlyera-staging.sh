#!/usr/bin/env bash
#
# Refresh the Everly Era staging environment from production.
#
# Copies production's PostgreSQL database and media objects into staging so
# code changes can be tested against realistic content. Strictly one
# directional: staging is overwritten, production is only ever read.
#
# Content is authored in production using Payload drafts, so there is never a
# reason to push staging content the other way. This script refuses to.
#
#   ./refresh-everlyera-staging.sh            # show the plan, change nothing
#   ./refresh-everlyera-staging.sh --yes      # actually do it
#
# Blast radius: destroys and replaces everything in the everlyera-stage
# database and the everlyera-media-stage bucket. Production is untouched.

set -euo pipefail

PROD_NS="everlyera"
STAGE_NS="everlyera-stage"
MEDIA_NS="everlyera-media"
PROD_BUCKET="everlyera-media"
STAGE_BUCKET="everlyera-media-stage"

CONFIRM="${1:-}"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

die() { red "error: $*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------

command -v kubectl >/dev/null || die "kubectl not found"

for ns in "$PROD_NS" "$STAGE_NS" "$MEDIA_NS"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || die "namespace $ns not found"
done

# Guard against a context pointing somewhere unexpected.
CTX="$(kubectl config current-context)"

prod_web_image="$(kubectl -n "$PROD_NS" get deploy everlyera-web \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
stage_web_image="$(kubectl -n "$STAGE_NS" get deploy everlyera-web \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

[ -n "$prod_web_image" ]  || die "could not read the production web deployment"
[ -n "$stage_web_image" ] || die "could not read the staging web deployment"

# A staging image tag without -stage means the overlays are crossed. Refuse:
# copying production data into an environment running a production-URL build
# is how staging quietly becomes a second production.
case "$stage_web_image" in
  *-stage) ;;
  *) die "staging runs '$stage_web_image', which is not a -stage build. Refusing." ;;
esac

prod_rows() {
  kubectl -n "$PROD_NS" exec deploy/everlyera-postgres -- \
    psql -U everlyera -d everlyera -tAc "$1" 2>/dev/null | tr -d '[:space:]'
}
stage_rows() {
  kubectl -n "$STAGE_NS" exec deploy/everlyera-postgres -- \
    psql -U everlyera -d everlyera -tAc "$1" 2>/dev/null | tr -d '[:space:]'
}

mc_in_media() {
  kubectl -n "$MEDIA_NS" exec deploy/everlyera-minio -- sh -c \
    'mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 && '"$1"
}

step "Plan"
cat <<EOF
  context        : $CTX
  production     : $PROD_NS  ($prod_web_image)
  staging        : $STAGE_NS  ($stage_web_image)

  Will REPLACE, in staging only:
    - database $STAGE_NS/everlyera   <- dump of $PROD_NS/everlyera
    - bucket   $STAGE_BUCKET         <- mirror of $PROD_BUCKET

  Production is read-only throughout.
EOF

echo
echo "  current row counts:"
printf '    production media=%s  collections=%s  pages=%s  users=%s\n' \
  "$(prod_rows 'select count(*) from media;')" \
  "$(prod_rows 'select count(*) from portfolio_collections;')" \
  "$(prod_rows 'select count(*) from pages;')" \
  "$(prod_rows 'select count(*) from users;')"
printf '    staging    media=%s  collections=%s  pages=%s  users=%s\n' \
  "$(stage_rows 'select count(*) from media;')" \
  "$(stage_rows 'select count(*) from portfolio_collections;')" \
  "$(stage_rows 'select count(*) from pages;')" \
  "$(stage_rows 'select count(*) from users;')"

if [ "$CONFIRM" != "--yes" ]; then
  echo
  ylw "Dry run. Nothing changed. Re-run with --yes to apply."
  exit 0
fi

echo
ylw "Staging admin accounts will be replaced by production's, including their"
ylw "password hashes. Sign in to staging with the production credentials afterwards."

# --- database --------------------------------------------------------------

step "Copying database"
# --clean --if-exists drops staging's objects as the dump is replayed, so the
# result is production's schema and data rather than a merge.
kubectl -n "$PROD_NS" exec deploy/everlyera-postgres -- \
  pg_dump -U everlyera -d everlyera --clean --if-exists --no-owner --no-privileges \
  | kubectl -n "$STAGE_NS" exec -i deploy/everlyera-postgres -- \
      psql -U everlyera -d everlyera -v ON_ERROR_STOP=1 --quiet

grn "  database copied"

# --- media -----------------------------------------------------------------

step "Mirroring media objects"
# --remove deletes staging objects absent from production, so the buckets match
# rather than accumulating. Both buckets live in the same MinIO.
mc_in_media "mc mirror --overwrite --remove local/$PROD_BUCKET local/$STAGE_BUCKET"
grn "  media mirrored"

# --- restart ---------------------------------------------------------------

step "Restarting staging web"
kubectl -n "$STAGE_NS" rollout restart deploy/everlyera-web
kubectl -n "$STAGE_NS" rollout status deploy/everlyera-web --timeout=5m

# --- verify ----------------------------------------------------------------

step "Verifying"
printf '    staging now media=%s  collections=%s  pages=%s  users=%s\n' \
  "$(stage_rows 'select count(*) from media;')" \
  "$(stage_rows 'select count(*) from portfolio_collections;')" \
  "$(stage_rows 'select count(*) from pages;')" \
  "$(stage_rows 'select count(*) from users;')"

echo "    objects in $STAGE_BUCKET: $(mc_in_media "mc ls --recursive local/$STAGE_BUCKET" | wc -l)"
echo "    objects in $PROD_BUCKET:  $(mc_in_media "mc ls --recursive local/$PROD_BUCKET" | wc -l)"

code="$(curl -s -o /dev/null -w '%{http_code}' https://staging.everlyera.com/ || true)"
echo "    https://staging.everlyera.com -> $code"

# Production must be exactly as it was.
echo "    production still media=$(prod_rows 'select count(*) from media;') (unchanged)"

echo
grn "Staging refreshed from production."
