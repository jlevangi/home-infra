#!/bin/bash
# Full cluster data restore from shared backup location
# Usage: ./restore_cluster_from_backup.sh --cluster <cluster> [--date YYYY-MM-DD]

set -e

CLUSTER=""
RESTORE_DATE=""
DRY_RUN=false
APPS=("vaultwarden" "bookstack" "homepage")

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster)
      CLUSTER="$2"
      shift 2
      ;;
    --date)
      RESTORE_DATE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      echo "🚀 Full Cluster Disaster Recovery"
      echo ""
      echo "Usage: $0 --cluster <cluster> [OPTIONS]"
      echo ""
      echo "Required:"
      echo "  --cluster <name>       Target cluster (test, prod)"
      echo ""
      echo "Optional:"
      echo "  --date <YYYY-MM-DD>    Restore from specific date (latest if not specified)"
      echo "  --dry-run              Show what would be restored"
      echo ""
      echo "Examples:"
      echo "  $0 --cluster test"
      echo "  $0 --cluster prod --date 2025-08-14"
      echo "  $0 --cluster test --dry-run"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CLUSTER" ]]; then
  echo "❌ Cluster name required"
  echo "Use --help for usage"
  exit 1
fi

echo "🚀 Starting full cluster data restore..."
echo "📋 Configuration:"
echo "   Target Cluster: $CLUSTER"
echo "   Restore Date: ${RESTORE_DATE:-latest available}"
echo "   Applications: ${APPS[*]}"
echo "   Dry Run: $DRY_RUN"
echo ""

# Switch to cluster
echo "🔀 Switching to $CLUSTER cluster..."
if [[ "$DRY_RUN" == "false" ]]; then
  echo "$CLUSTER" | ./scripts/k3s-context-manager.sh switch
fi

# Find available backups
echo "🔍 Scanning available backups..."
if [[ "$DRY_RUN" == "false" ]]; then
  kubectl get backups -n longhorn-system --no-headers -o custom-columns="NAME:.metadata.name,APP:.metadata.labels.app,CREATED:.status.snapshotCreatedAt,SIZE:.status.size"
fi

# Restore each application
for app in "${APPS[@]}"; do
  echo ""
  echo "🔄 Restoring $app..."
  
  if [[ "$DRY_RUN" == "true" ]]; then
    ./scripts/restore_app_data.sh --app "$app" --cluster "$CLUSTER" --dry-run
  else
    ./scripts/restore_app_data.sh --app "$app" --cluster "$CLUSTER"
  fi
  
  echo "✅ $app restore completed"
done

echo ""
echo "🎉 Full cluster restore completed!"
echo ""
echo "📊 Final cluster status:"
if [[ "$DRY_RUN" == "false" ]]; then
  kubectl get pods -A | grep -E "(vaultwarden|bookstack|homepage)"
  echo ""
  kubectl get pvc -A
fi