#!/bin/bash
# Unified K3s cluster deployment script
# Uses the new k3s-deploy-cluster.yml playbook with target selection

# Determine script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source environment functions
source "$SCRIPT_DIR/lib/environment-functions.sh"

# Default values
TARGET_ENV=""
TARGET_CLUSTER=""
EXTRA_VARS=""
VERBOSITY=""
SHOW_HELP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --prod|--production)
      TARGET_ENV="prod"
      shift
      ;;
    --test)
      TARGET_ENV="test"
      shift
      ;;
    --stage|--staging)
      TARGET_ENV="stage"
      shift
      ;;
    --env)
      if [[ -n "$2" && "$2" != -* ]]; then
        TARGET_ENV="$2"
        shift 2
      else
        echo "❌ Error: --env requires an environment name"
        exit 1
      fi
      ;;
    --env=*)
      TARGET_ENV="${1#--env=}"
      shift
      ;;
    -v|--verbose)
      VERBOSITY="-v"
      shift
      ;;
    -vv)
      VERBOSITY="-vv"
      shift
      ;;
    -vvv)
      VERBOSITY="-vvv"
      shift
      ;;
    --quiet|-q)
      VERBOSITY=""
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

# Show help if requested or no target specified
if [[ "$SHOW_HELP" == "true" ]] || [[ -z "$TARGET_ENV" ]]; then
  echo "Usage: $0 [ENVIRONMENT] [OPTIONS]"
  echo ""
  show_environment_help "$0"
  echo "Options:"
  echo "  -v, --verbose          Enable verbose output"
  echo "  -vv, -vvv              Enable more verbose output"
  echo "  -q, --quiet            Disable verbose output"
  echo "  -h, --help             Show this help message"
  echo ""
  
  if [[ -z "$TARGET_ENV" ]]; then
    echo ""
    echo "❌ Error: Target environment must be specified"
    exit 1
  else
    exit 0
  fi
fi

# Set up target-specific variables using environment functions
if ! setup_environment_vars "$TARGET_ENV"; then
  exit 1
fi

# Set up Ansible extra vars for target cluster
EXTRA_VARS="$EXTRA_VARS -e target_cluster=$TARGET_CLUSTER"

# Apply default verbosity if not explicitly set and environment has a default
if [[ -z "$VERBOSITY" && -n "$DEFAULT_VERBOSITY" ]]; then
  VERBOSITY="$DEFAULT_VERBOSITY"
fi

# Switch to the appropriate kubectl context (non-blocking for initial deployments)
echo "🔄 Attempting to switch to $CLUSTER_NAME cluster context..."
if "$SCRIPT_DIR/helpers/k3s-context-manager.sh" switch "$KUBECTL_CONTEXT" 2>/dev/null; then
  echo "✅ Successfully switched to k3s-$KUBECTL_CONTEXT context"
else
  echo "ℹ️  Context k3s-$KUBECTL_CONTEXT not found (expected for initial deployment)"
  echo "   Context will be configured after cluster deployment completes"
fi
echo ""

echo "$CLUSTER_EMOJI Deploying K3s $CLUSTER_NAME Cluster..."
echo "📂 Using unified deployment playbook: k3s-deploy-cluster.yml"
echo "🎯 Target: $CLUSTER_NAME cluster ($TARGET_CLUSTER)"
echo "🔊 Verbosity: $([ -n "$VERBOSITY" ] && echo "$VERBOSITY" || echo "Standard")"
echo ""

# Pre-deployment kubeconfig setup attempt (for existing clusters)
echo "🔑 Pre-deployment kubeconfig check..."
if "$SCRIPT_DIR/helpers/k3s-context-manager.sh" setup > /dev/null 2>&1; then
  echo "✅ Existing kubeconfig contexts updated"
else
  echo "ℹ️  No existing clusters found or kubeconfig setup not needed yet"
fi
echo ""

# Get the appropriate inventory path for this environment
INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")

# Preflight SSH connectivity check
echo "🔍 Preflight: Checking SSH connectivity to all nodes in $TARGET_CLUSTER..."
PING_CMD=(ansible -i "$INVENTORY_PATH" "$TARGET_CLUSTER" -m ping)
if [[ -n "$VERBOSITY" ]]; then
  PING_CMD+=("$VERBOSITY")
fi
if ! "${PING_CMD[@]}"; then
  echo ""
  echo "❌ Preflight failed: one or more nodes are unreachable. Aborting deployment."
  exit 1
fi
echo "✅ Preflight SSH check passed"
echo ""

# Build ansible command with proper argument handling
ANSIBLE_CMD=(ansible-playbook -i "$INVENTORY_PATH" "$PROJECT_ROOT/ansible/playbooks/k3s-deploy-cluster.yml" --vault-password-file ~/.ansible_vault_pass)

# Add verbosity if set
if [[ -n "$VERBOSITY" ]]; then
  ANSIBLE_CMD+=("$VERBOSITY")
fi

# Add extra vars if set
if [[ -n "$EXTRA_VARS" ]]; then
  ANSIBLE_CMD+=($EXTRA_VARS)
fi

# Execute the command
"${ANSIBLE_CMD[@]}"

RESULT=$?

echo ""
if [ $RESULT -eq 0 ]; then
  echo "🔑 Post-deployment kubeconfig setup..."
  echo ""
  
  # Setup kubeconfig contexts for the deployed cluster
  if ! "$SCRIPT_DIR/helpers/k3s-context-manager.sh" setup; then
    echo "⚠️  Warning: Kubeconfig setup failed, but cluster deployment succeeded"
    echo "   You may need to run './scripts/helpers/k3s-context-manager.sh setup' manually"
  else
    echo "✅ Kubeconfig contexts configured successfully"
  fi
  
  echo ""
  echo "✅ $CLUSTER_NAME cluster deployment complete!"
  echo ""
  echo "ArgoCD Initial Admin Password:"
  kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo

else
  echo "❌ $CLUSTER_NAME cluster deployment failed (exit code: $RESULT)"
  exit $RESULT
  
fi
