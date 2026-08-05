#!/usr/bin/env bash
#
# Promote an Everly Era release to staging or production.
#
#   ./promote-everlyera.sh 0.3.1 stage     # roll staging to 0.3.1-stage
#   ./promote-everlyera.sh 0.3.1 prod      # roll production to 0.3.1
#   ./promote-everlyera.sh 0.3.0 prod      # same command rolls back
#
# Edits the overlay tag, pushes, waits for ArgoCD, and verifies the result.
# Promotion to production refuses unless that exact version is already running
# on staging, so "test on staging first" is enforced by the tool rather than
# remembered.
#
# Prerequisite: the image must already be published. Pushing git tag vX.Y.Z in
# the website repo builds X.Y.Z (production URL) and X.Y.Z-stage (staging URL).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFESTS="$REPO/argocd/manifests/everlyera"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { red "error: $*" >&2; exit 1; }

VERSION="${1:-}"
ENVIRONMENT="${2:-}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "version must look like 0.3.1 (got '${VERSION:-}')"

case "$ENVIRONMENT" in
  stage) NS=everlyera-stage; TAG="${VERSION}-stage"; HOST=staging.everlyera.com ;;
  prod)  NS=everlyera;       TAG="${VERSION}";       HOST=everlyera.com ;;
  *) die "environment must be 'stage' or 'prod' (got '${ENVIRONMENT:-}')" ;;
esac

OVERLAY="$MANIFESTS/overlays/$ENVIRONMENT/kustomization.yaml"
[ -f "$OVERLAY" ] || die "overlay not found: $OVERLAY"

command -v kubectl >/dev/null || die "kubectl not found"
kubectl get ns "$NS" >/dev/null 2>&1 || die "namespace $NS not found"

current_tag() {
  kubectl -n "$1" get deploy everlyera-web \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://'
}

# --- guards ----------------------------------------------------------------

# A -stage image carries the staging URL baked into the bundle. Shipping it to
# production would publish staging canonical URLs, OpenGraph tags and sitemap.
if [ "$ENVIRONMENT" = "prod" ] && [[ "$TAG" == *-stage ]]; then
  die "refusing to put a -stage build in production"
fi

if [ "$ENVIRONMENT" = "prod" ]; then
  STAGE_NOW="$(current_tag everlyera-stage)"
  if [ "$STAGE_NOW" != "${VERSION}-stage" ]; then
    red "refusing: staging is running '${STAGE_NOW:-unknown}', not '${VERSION}-stage'."
    echo
    echo "  Test on staging first:"
    echo "    $0 $VERSION stage"
    echo
    echo "  To override deliberately (rollback, hotfix), set ALLOW_UNSTAGED=1."
    [ "${ALLOW_UNSTAGED:-}" = "1" ] || exit 1
    ylw "  ALLOW_UNSTAGED=1 set — continuing anyway."
  fi
fi

FROM="$(current_tag "$NS")"
if [ "$FROM" = "$TAG" ]; then
  grn "$NS is already running $TAG. Nothing to do."
  exit 0
fi

printf '\n\033[1m==> Promoting %s: %s -> %s\033[0m\n' "$ENVIRONMENT" "${FROM:-none}" "$TAG"
echo "  namespace : $NS"
echo "  overlay   : ${OVERLAY#"$REPO"/}"
echo "  host      : https://$HOST"

if [ "${DRY_RUN:-}" = "1" ]; then
  echo
  ylw "DRY_RUN=1 — nothing changed."
  exit 0
fi

# --- edit, validate, push ---------------------------------------------------

sed -i -E "s|(newTag: )\"[^\"]*\"|\1\"$TAG\"|" "$OVERLAY"

RENDERED="$(kubectl kustomize "$MANIFESTS/overlays/$ENVIRONMENT" 2>/dev/null \
  | grep -m1 'image: ghcr.io/jlevangi/everlyera' | sed 's/.*://')"
[ "$RENDERED" = "$TAG" ] || {
  git -C "$REPO" checkout -- "$OVERLAY"
  die "overlay rendered '$RENDERED', expected '$TAG'; reverted"
}

# The other environment must be untouched by this change.
OTHER_ENV=$([ "$ENVIRONMENT" = "prod" ] && echo stage || echo prod)
git -C "$REPO" diff --name-only | grep -q "overlays/$OTHER_ENV" \
  && die "refusing: the $OTHER_ENV overlay also changed"

git -C "$REPO" add "$OVERLAY"
git -C "$REPO" commit -q -m "chore(everlyera): $ENVIRONMENT -> $TAG"
git -C "$REPO" pull --rebase -q
git -C "$REPO" push -q
grn "  pushed"

# --- sync and verify --------------------------------------------------------

APP=$([ "$ENVIRONMENT" = "prod" ] && echo everlyera || echo everlyera-stage)
kubectl -n argocd annotate application "$APP" \
  argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

echo "  waiting for ArgoCD and rollout..."
for _ in $(seq 1 60); do
  [ "$(current_tag "$NS")" = "$TAG" ] && break
  sleep 5
done
[ "$(current_tag "$NS")" = "$TAG" ] || die "deployment never picked up $TAG"

kubectl -n "$NS" rollout status deploy/everlyera-web --timeout=10m

POD="$(kubectl -n "$NS" get pods -l app=everlyera-web \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
MIG="$(kubectl -n "$NS" get pod "$POD" \
  -o jsonpath='{.status.initContainerStatuses[?(@.name=="migrate")].state.terminated.exitCode}' 2>/dev/null)"
echo "  migrate init exit code : ${MIG:-n/a}"
[ "${MIG:-0}" = "0" ] || die "migrations failed"

CODE="$(curl -s -o /dev/null -w '%{http_code}' "https://$HOST/" || true)"
echo "  https://$HOST -> $CODE"
[ "$CODE" = "200" ] || die "site did not return 200 after rollout"

printf '\n'
grn "$ENVIRONMENT is now on $TAG."
[ "$ENVIRONMENT" = "stage" ] && cat <<EOF

  Verify staging, then promote the same version to production:
    $0 $VERSION prod
EOF
exit 0
