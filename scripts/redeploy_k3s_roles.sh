#!/bin/bash
# Production cluster deployment script using unified playbook
# Uses the new k3s-deploy-cluster.yml playbook

# Parse command line arguments
EXTRA_VARS=""
VERBOSITY=""
DEPLOY_APPS="true"

while [[ $# -gt 0 ]]; do
  case $1 in
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
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --no-apps          Deploy only infrastructure (K3s, networking), skip applications"
      echo "  -v, --verbose      Enable verbose output"
      echo "  -vv, -vvv          Enable more verbose output"
      echo "  -h, --help         Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                 # Deploy full production cluster with apps"
      echo "  $0 --no-apps       # Deploy only infrastructure"
      echo "  $0 -v --no-apps    # Deploy infrastructure with verbose output"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

echo "🚀 Deploying K3s Production Cluster..."
echo "📂 Using unified deployment playbook: k3s-deploy-cluster.yml"
echo "🎯 Target: Production cluster (k3s_cluster)"
echo "📦 Applications: $([ "$DEPLOY_APPS" == "true" ] && echo "Enabled" || echo "Disabled")"
echo ""

ansible-playbook -i ../ansible/k3s-inventory ../ansible/playbooks/k3s-deploy-cluster.yml \
  --vault-password-file ~/.ansible_vault_pass \
  $VERBOSITY \
  $EXTRA_VARS

echo ""
echo "✅ Production cluster deployment complete!"