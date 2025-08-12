#!/bin/bash

# Unified K3s cluster rebuild script
# Allows target selection and verbosity

TARGET_CLUSTER=""
SHOW_HELP=false
VERBOSITY=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --prod|--production)
      TARGET_CLUSTER="prod"
      shift
      ;;
    --test)
      TARGET_CLUSTER="test"
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

if [[ "$SHOW_HELP" == "true" ]] || [[ -z "$TARGET_CLUSTER" ]]; then
  echo "Usage: $0 --prod|--test [OPTIONS]"
  echo ""
  echo "Target Selection (required):"
  echo "  --prod, --production   Rebuild production cluster (k3_3node_cluster)"
  echo "  --test                 Rebuild test cluster (k3_3node_test_cluster)"
  echo ""
  echo "Options:"
  echo "  -v, --verbose          Enable verbose output"
  echo "  -vv, -vvv              Enable more verbose output"
  echo "  -q, --quiet            Disable verbose output"
  echo "  -h, --help             Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --prod              # Rebuild production cluster"
  echo "  $0 --test -v           # Rebuild test cluster with verbose output"
  echo "  $0 --prod -q           # Rebuild production cluster quietly"
  echo ""
  if [[ -z "$TARGET_CLUSTER" ]]; then
    echo "❌ Error: Target cluster must be specified (--prod or --test)"
    exit 1
  else
    exit 0
  fi
fi

if [[ "$TARGET_CLUSTER" == "test" ]]; then
  TF_DIR="../terraform/k3_3node_test_cluster"
  CLUSTER_NAME="Test"
  CLUSTER_EMOJI="🧪"
else
  TF_DIR="../terraform/k3_3node_cluster"
  CLUSTER_NAME="Production"
  CLUSTER_EMOJI="🚀"
fi

pushd "$TF_DIR"

echo "$CLUSTER_EMOJI Destroying existing $CLUSTER_NAME cluster with Terraform..."
terraform destroy --auto-approve $VERBOSITY

echo "$CLUSTER_EMOJI Deploying $CLUSTER_NAME cluster with Terraform..."
terraform apply --auto-approve $VERBOSITY

popd
