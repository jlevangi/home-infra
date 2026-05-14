#!/bin/bash

# Unified K3s cluster rebuild script
# Allows target selection and verbosity

set -euo pipefail

TARGET_CLUSTER=""
SHOW_HELP=false
VERBOSITY=""
TF_DIRS=()
STACK_SCOPE="all"
TF_TARGETS=()

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
    --yes)
      # Accepted for compatibility with callers such as restore-cluster.sh.
      shift
      ;;
    --control-plane-only)
      STACK_SCOPE="control-plane"
      shift
      ;;
    --workers-only)
      STACK_SCOPE="workers"
      shift
      ;;
    --terraform-target)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --terraform-target"
        exit 1
      fi
      TF_TARGETS+=("$2")
      shift 2
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
  echo "  --control-plane-only   Limit work to the control-plane Terraform stack"
  echo "  --workers-only         Limit work to the worker Terraform stack"
  echo "  --terraform-target     Pass a Terraform target address; may be repeated"
  echo "  -h, --help             Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --prod              # Rebuild production cluster"
  echo "  $0 --test -v           # Rebuild test cluster with verbose output"
  echo "  $0 --stage             # Rebuild staging cluster"
  echo "  $0 --prod --control-plane-only --terraform-target 'module.nodes.proxmox_vm_qemu.this[0]' --terraform-target 'module.nodes.proxmox_vm_qemu.this[2]'"
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
  TF_DIRS=(
    "$REPO_ROOT/terraform/stacks/k3s/atlas/test/workers"
    "$REPO_ROOT/terraform/stacks/k3s/atlas/test/control-plane"
  )
  CLUSTER_NAME="Test"
  CLUSTER_EMOJI="🧪"
elif [[ "$TARGET_CLUSTER" == "stage" ]]; then
  TF_DIRS=(
    "$REPO_ROOT/terraform/stacks/k3s/atlas/stage/workers"
    "$REPO_ROOT/terraform/stacks/k3s/atlas/stage/control-plane"
  )
  CLUSTER_NAME="Staging"
  CLUSTER_EMOJI="🎭"
else
  TF_DIRS=(
    "$REPO_ROOT/terraform/stacks/k3s/atlas/prod/workers"
    "$REPO_ROOT/terraform/stacks/k3s/atlas/prod/control-plane"
  )
  CLUSTER_NAME="Production"
  CLUSTER_EMOJI="🚀"
fi

# Apply stack-scope filtering
if [[ "$STACK_SCOPE" != "all" ]]; then
  FILTERED_DIRS=()
  for TF_DIR in "${TF_DIRS[@]}"; do
    case "$STACK_SCOPE" in
      control-plane)
        [[ "$TF_DIR" == *"/control-plane" ]] && FILTERED_DIRS+=("$TF_DIR")
        ;;
      workers)
        [[ "$TF_DIR" == *"/workers" ]] && FILTERED_DIRS+=("$TF_DIR")
        ;;
    esac
  done
  TF_DIRS=("${FILTERED_DIRS[@]}")
fi

if [[ ${#TF_TARGETS[@]} -gt 0 && ${#TF_DIRS[@]} -ne 1 ]]; then
  echo "--terraform-target requires exactly one selected Terraform stack."
  echo "Use --control-plane-only or --workers-only."
  exit 1
fi

for TF_DIR in "${TF_DIRS[@]}"; do
  pushd "$TF_DIR" >/dev/null

  echo "$CLUSTER_EMOJI Initializing Terraform in $TF_DIR..."
  terraform init

  if [[ ${#TF_TARGETS[@]} -gt 0 ]]; then
    echo "$CLUSTER_EMOJI Applying targeted $CLUSTER_NAME resources in $TF_DIR..."
    TARGET_ARGS=()
    for TF_TARGET in "${TF_TARGETS[@]}"; do
      TARGET_ARGS+=("-target=$TF_TARGET")
    done
    terraform apply --auto-approve $VERBOSITY "${TARGET_ARGS[@]}"
  else
    echo "$CLUSTER_EMOJI Destroying existing $CLUSTER_NAME resources in $TF_DIR..."
    terraform destroy --auto-approve $VERBOSITY

    echo "$CLUSTER_EMOJI Deploying $CLUSTER_NAME resources in $TF_DIR..."
    terraform apply --auto-approve $VERBOSITY
  fi

  popd >/dev/null
done

# Clear stale SSH host keys (VMs get new host keys on rebuild)
INVENTORY_PATH="$REPO_ROOT/ansible/inventories/$TARGET_CLUSTER/hosts.yml"
if [[ -f "$INVENTORY_PATH" ]]; then
  echo ""
  echo "🔑 Clearing stale SSH host keys for $CLUSTER_NAME nodes..."
  NODE_IPS=$(grep -E '^\s+ansible_host:' "$INVENTORY_PATH" | awk '{print $2}')
  for ip in $NODE_IPS; do
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" 2>/dev/null
  done
  echo "✅ SSH host keys cleared"
fi
