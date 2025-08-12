#!/bin/bash
# Unified K3s cluster deployment script
# Uses the new k3s-deploy-cluster.yml playbook with target selection

# Determine script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default values
TARGET_CLUSTER=""
EXTRA_VARS=""
VERBOSITY=""
DEPLOY_APPS="true"
SHOW_HELP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --prod|--production)
      TARGET_CLUSTER="k3s_cluster"
      shift
      ;;
    --test)
      TARGET_CLUSTER="k3s_test_cluster"
      VERBOSITY="-v"  # Default verbose for test
      shift
      ;;
    --no-apps)
      DEPLOY_APPS="false"
      EXTRA_VARS="$EXTRA_VARS -e deploy_applications=false"
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
if [[ "$SHOW_HELP" == "true" ]] || [[ -z "$TARGET_CLUSTER" ]]; then
  echo "Usage: $0 --prod|--test [OPTIONS]"
  echo ""
  echo "Target Selection (required):"
  echo "  --prod, --production   Deploy to production cluster (k3s_cluster)"
  echo "  --test                 Deploy to test cluster (k3s_test_cluster)"
  echo ""
  echo "Options:"
  echo "  --no-apps              Deploy only infrastructure, skip applications"
  echo "  -v, --verbose          Enable verbose output"
  echo "  -vv, -vvv              Enable more verbose output"
  echo "  -q, --quiet            Disable verbose output"
  echo "  -h, --help             Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --prod              # Deploy full production cluster"
  echo "  $0 --test --no-apps    # Deploy test infrastructure only"
  echo "  $0 --prod -v           # Deploy production with verbose output"
  echo "  $0 --test -q           # Deploy test cluster quietly"
  echo ""
  echo "Legacy Scripts (still available):"
  echo "  ./redeploy_k3s_roles.sh                    # Production deployment"
  echo "  ./redeploy_k3s_roles_test_cluster.sh       # Test deployment"
  
  if [[ -z "$TARGET_CLUSTER" ]]; then
    echo ""
    echo "❌ Error: Target cluster must be specified (--prod or --test)"
    exit 1
  else
    exit 0
  fi
fi

# Set up target-specific variables
if [[ "$TARGET_CLUSTER" == "k3s_test_cluster" ]]; then
  EXTRA_VARS="$EXTRA_VARS -e target_cluster=k3s_test_cluster"
  CLUSTER_NAME="Test"
  CLUSTER_EMOJI="🧪"
else
  CLUSTER_NAME="Production"
  CLUSTER_EMOJI="🚀"
fi

echo "$CLUSTER_EMOJI Deploying K3s $CLUSTER_NAME Cluster..."
echo "📂 Using unified deployment playbook: k3s-deploy-cluster.yml"
echo "🎯 Target: $CLUSTER_NAME cluster ($TARGET_CLUSTER)"
echo "📦 Applications: $([ "$DEPLOY_APPS" == "true" ] && echo "Enabled" || echo "Disabled")"
echo "🔊 Verbosity: $([ -n "$VERBOSITY" ] && echo "$VERBOSITY" || echo "Standard")"
echo ""

ansible-playbook -i "$PROJECT_ROOT/ansible/k3s-inventory" "$PROJECT_ROOT/ansible/playbooks/k3s-deploy-cluster.yml" \
  --vault-password-file ~/.ansible_vault_pass \
  $VERBOSITY \
  $EXTRA_VARS

RESULT=$?

echo ""
if [ $RESULT -eq 0 ]; then
  echo "✅ $CLUSTER_NAME cluster deployment complete!"
else
  echo "❌ $CLUSTER_NAME cluster deployment failed (exit code: $RESULT)"
  exit $RESULT
fi