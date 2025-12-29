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
    --stage|--staging)
      TARGET_CLUSTER="stage"
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
  echo "Usage: $0 --prod|--test|--stage [OPTIONS]"
  echo ""
  echo "Target Selection (required):"
  echo "  --prod, --production   Rebuild production cluster"
  echo "  --test                 Rebuild test cluster"
  echo "  --stage, --staging     Rebuild staging cluster"
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
  echo "  $0 --stage             # Rebuild staging cluster"
  echo ""
  if [[ -z "$TARGET_CLUSTER" ]]; then
    echo "❌ Error: Target cluster must be specified (--prod, --test, or --stage)"
    exit 1
  else
    exit 0
  fi
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ "$TARGET_CLUSTER" == "test" ]]; then
  TF_DIR="$REPO_ROOT/terraform/k3_3node_cluster_test"
  CLUSTER_NAME="Test"
  CLUSTER_EMOJI="🧪"
elif [[ "$TARGET_CLUSTER" == "stage" ]]; then
  TF_DIR="$REPO_ROOT/terraform/k3_3node_cluster_stage"
  CLUSTER_NAME="Staging"
  CLUSTER_EMOJI="🎭"
else
  TF_DIR="$REPO_ROOT/terraform/k3_3node_cluster_prod"
  CLUSTER_NAME="Production"
  CLUSTER_EMOJI="🚀"
fi

pushd "$TF_DIR"

echo "$CLUSTER_EMOJI Destroying existing $CLUSTER_NAME cluster with Terraform..."
terraform destroy --auto-approve $VERBOSITY

echo "$CLUSTER_EMOJI Deploying $CLUSTER_NAME cluster with Terraform..."
terraform apply --auto-approve $VERBOSITY

popd
