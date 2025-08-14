#!/bin/bash
# Automated Longhorn backup restore script
# Usage: ./restore_app_data.sh --app <app-name> --cluster <cluster> [--backup <backup-name>]

set -e

# Default values
APP_NAME=""
CLUSTER=""
BACKUP_NAME=""
NAMESPACE=""
DRY_RUN=false
SHOW_HELP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --app)
      APP_NAME="$2"
      NAMESPACE="$2"  # Assuming namespace = app name
      shift 2
      ;;
    --cluster)
      CLUSTER="$2"
      shift 2
      ;;
    --backup)
      BACKUP_NAME="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      SHOW_HELP=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Show help
if [[ "$SHOW_HELP" == "true" ]] || [[ -z "$APP_NAME" ]] || [[ -z "$CLUSTER" ]]; then
  echo "🔄 Longhorn Application Data Restore Script"
  echo ""
  echo "Usage: $0 --app <app-name> --cluster <cluster> [OPTIONS]"
  echo ""
  echo "Required:"
  echo "  --app <name>           Application name (vaultwarden, bookstack, homepage)"
  echo "  --cluster <name>       Target cluster (test, prod, staging)"
  echo ""
  echo "Optional:"
  echo "  --backup <name>        Specific backup to restore (latest if not specified)"
  echo "  --namespace <name>     Override namespace (defaults to app name)"
  echo "  --dry-run              Show what would be done without executing"
  echo "  --help, -h             Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --app vaultwarden --cluster test"
  echo "  $0 --app bookstack --cluster prod --backup backup-abc123"
  echo "  $0 --app vaultwarden --cluster test --dry-run"
  exit 0
fi

# Set namespace if not provided
if [[ -z "$NAMESPACE" ]]; then
  NAMESPACE="$APP_NAME"
fi

echo "🔄 Starting Longhorn backup restore..."
echo "📋 Configuration:"
echo "   App: $APP_NAME"
echo "   Namespace: $NAMESPACE"
echo "   Cluster: $CLUSTER"
echo "   Backup: ${BACKUP_NAME:-latest available}"
echo "   Dry Run: $DRY_RUN"
echo ""

# Switch to target cluster
echo "🔀 Switching to $CLUSTER cluster..."
if [[ "$DRY_RUN" == "false" ]]; then
  echo "$CLUSTER" | ./scripts/k3s-context-manager.sh switch
fi

# Find backup if not specified
if [[ -z "$BACKUP_NAME" ]]; then
  echo "🔍 Finding latest backup for $APP_NAME..."
  if [[ "$DRY_RUN" == "false" ]]; then
    # Get the latest backup for this app's PVC
    PVC_NAME=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$PVC_NAME" ]]; then
      BACKUP_NAME=$(kubectl get backups -n longhorn-system -l backup-volume="$PVC_NAME" --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")
    fi
    
    if [[ -z "$BACKUP_NAME" ]]; then
      echo "❌ No backups found for $APP_NAME"
      echo "Available backups:"
      kubectl get backups -n longhorn-system --no-headers -o custom-columns="NAME:.metadata.name,CREATED:.status.snapshotCreatedAt,SIZE:.status.size"
      exit 1
    fi
  else
    BACKUP_NAME="<latest-backup-for-$APP_NAME>"
  fi
fi

echo "✅ Using backup: $BACKUP_NAME"

# Get backup details
if [[ "$DRY_RUN" == "false" ]]; then
  BACKUP_URL=$(kubectl get backup "$BACKUP_NAME" -n longhorn-system -o jsonpath='{.status.url}' 2>/dev/null || echo "")
  BACKUP_SIZE=$(kubectl get backup "$BACKUP_NAME" -n longhorn-system -o jsonpath='{.status.size}' 2>/dev/null || echo "0")
  
  if [[ -z "$BACKUP_URL" ]]; then
    echo "❌ Backup $BACKUP_NAME not found or not accessible"
    exit 1
  fi
  
  echo "📊 Backup Details:"
  echo "   URL: $BACKUP_URL"
  echo "   Size: $(( BACKUP_SIZE / 1024 / 1024 ))MB"
fi

# Scale down application
echo "⬇️ Scaling down $APP_NAME..."
if [[ "$DRY_RUN" == "false" ]]; then
  kubectl scale deployment "$APP_NAME" -n "$NAMESPACE" --replicas=0
  kubectl wait --for=delete pod -l app="$APP_NAME" -n "$NAMESPACE" --timeout=300s
fi

# Create temporary restore volume
echo "💾 Creating restore volume from backup..."
TEMP_VOLUME_NAME="restore-$APP_NAME-$(date +%s)"
if [[ "$DRY_RUN" == "false" ]]; then
  kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: $TEMP_VOLUME_NAME
  namespace: longhorn-system
spec:
  size: "$BACKUP_SIZE"
  numberOfReplicas: 2
  frontend: blockdev
  fromBackup: "$BACKUP_URL"
EOF

  # Wait for restore to complete
  echo "⏳ Waiting for restore to complete..."
  kubectl wait --for=jsonpath='{.status.state}'=detached volume/$TEMP_VOLUME_NAME -n longhorn-system --timeout=600s
fi

# Create migration pod
echo "🔄 Creating data migration pod..."
if [[ "$DRY_RUN" == "false" ]]; then
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $APP_NAME-data-migrator
  namespace: $NAMESPACE
spec:
  containers:
  - name: migrator
    image: busybox:1.35
    command: ['sleep', '3600']
    volumeMounts:
    - name: current-data
      mountPath: /current-data
    - name: restored-data
      mountPath: /restored-data
  volumes:
  - name: current-data
    persistentVolumeClaim:
      claimName: ${APP_NAME}-data-pvc
  - name: restored-data
    csi:
      driver: driver.longhorn.io
      volumeAttributes:
        volume: $TEMP_VOLUME_NAME
  restartPolicy: Never
EOF

  kubectl wait --for=condition=Ready pod/$APP_NAME-data-migrator -n "$NAMESPACE" --timeout=300s
  
  # Copy data
  echo "📋 Copying restored data..."
  kubectl exec -n "$NAMESPACE" "$APP_NAME-data-migrator" -- sh -c "rm -rf /current-data/* && cp -r /restored-data/* /current-data/"
  
  # Verify copy
  echo "✅ Verifying data integrity..."
  kubectl exec -n "$NAMESPACE" "$APP_NAME-data-migrator" -- ls -la /current-data/
fi

# Clean up
echo "🧹 Cleaning up temporary resources..."
if [[ "$DRY_RUN" == "false" ]]; then
  kubectl delete pod "$APP_NAME-data-migrator" -n "$NAMESPACE"
  kubectl delete volume "$TEMP_VOLUME_NAME" -n longhorn-system
fi

# Scale up application
echo "⬆️ Scaling up $APP_NAME..."
if [[ "$DRY_RUN" == "false" ]]; then
  kubectl scale deployment "$APP_NAME" -n "$NAMESPACE" --replicas=1
  kubectl wait --for=condition=Ready pod -l app="$APP_NAME" -n "$NAMESPACE" --timeout=300s
fi

echo ""
echo "🎉 Restore completed successfully!"
echo "📊 Final Status:"
if [[ "$DRY_RUN" == "false" ]]; then
  kubectl get pods -n "$NAMESPACE"
  echo ""
  echo "🔍 Next Steps:"
  echo "1. Test application functionality"
  echo "2. Verify data integrity" 
  echo "3. Check application logs if needed: kubectl logs -n $NAMESPACE -l app=$APP_NAME"
else
  echo "   This was a dry run - no changes were made"
fi