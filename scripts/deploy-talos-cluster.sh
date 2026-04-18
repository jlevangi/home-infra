#!/bin/bash
# Deploy the Talos test cluster, configure local access, then bootstrap the
# shared Kubernetes platform services (Longhorn, MetalLB, Traefik, ArgoCD,
# Vault).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/environment-functions.sh"

require_ansible_config || exit 1

VERBOSITY=""
SHOW_HELP=false
AUTO_APPROVE=false
MACHINE_CONFIG_APPLY_MODE="${TALOS_MACHINE_CONFIG_MODE:-auto}"

require_command() {
  local cmd="$1"
  local reason="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Missing required command: $cmd" >&2
    echo "   Needed for: $reason" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --auto-approve)
      AUTO_APPROVE=true
      shift
      ;;
    --initial-bootstrap)
      MACHINE_CONFIG_APPLY_MODE="reported"
      shift
      ;;
    --reconfigure)
      MACHINE_CONFIG_APPLY_MODE="static"
      shift
      ;;
    -h|--help)
      SHOW_HELP=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "${SHOW_HELP}" == "true" ]]; then
  cat <<'EOF'
Usage: scripts/deploy-talos-cluster.sh [options]

Options:
  -v, -vv, -vvv     Increase Ansible verbosity
  --auto-approve    Pass -auto-approve to terraform apply
  --initial-bootstrap
                    Force Talos machine-config apply to use the guest-agent
                    reported IPs. Use for the very first cluster bring-up.
  --reconfigure     Force Talos machine-config apply to use the static Talos
                    node IPs. Use for later config changes on an existing cluster.
  -h, --help        Show this help and exit

Environment:
  TALOS_MACHINE_CONFIG_MODE=auto|reported|static
EOF
  exit 0
fi

TERRAFORM_DIR="${PROJECT_ROOT}/terraform/talos_cluster_test"
LOCAL_KUBECONFIG_DIR="${HOME}/.kube"
LOCAL_TALOSCONFIG_DIR="${HOME}/.talos"
TALOS_KUBECONFIG="${LOCAL_KUBECONFIG_DIR}/config-talos-test"
TALOSCONFIG_FILE="${LOCAL_TALOSCONFIG_DIR}/config-talos-test"
TALOS_CONTEXT="talos-test"

require_command terraform "Talos VM/bootstrap provisioning"
require_command ansible-playbook "shared Kubernetes platform bootstrap"
require_command kubectl "kubeconfig registration and cluster bootstrap"
require_command helm "Longhorn, MetalLB, Traefik, and ArgoCD installation"
require_command jq "Helm status parsing inside the shared platform role"

if [[ ! -f "${HOME}/.ansible_vault_pass" ]]; then
  echo "❌ Missing ~/.ansible_vault_pass" >&2
  echo "   Needed for Ansible Vault secrets during platform bootstrap" >&2
  exit 1
fi

mkdir -p "${LOCAL_KUBECONFIG_DIR}" "${LOCAL_TALOSCONFIG_DIR}"

if [[ "${MACHINE_CONFIG_APPLY_MODE}" == "auto" ]]; then
  if terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null | grep -Fxq "talos_cluster_kubeconfig.this"; then
    MACHINE_CONFIG_APPLY_MODE="static"
  else
    MACHINE_CONFIG_APPLY_MODE="reported"
  fi
fi

echo "Using Talos machine-config apply mode: ${MACHINE_CONFIG_APPLY_MODE}"

TF_CMD=(
  terraform
  -chdir="${TERRAFORM_DIR}"
  apply
  -var
  "machine_config_apply_mode=${MACHINE_CONFIG_APPLY_MODE}"
)
if [[ "${AUTO_APPROVE}" == "true" ]]; then
  TF_CMD+=(-auto-approve)
fi

echo "Deploying Talos test cluster with Terraform..."
"${TF_CMD[@]}"

echo "Writing local kubeconfig and talosconfig..."
terraform -chdir="${TERRAFORM_DIR}" output -raw kubeconfig > "${TALOS_KUBECONFIG}"
terraform -chdir="${TERRAFORM_DIR}" output -raw talosconfig > "${TALOSCONFIG_FILE}"
chmod 600 "${TALOS_KUBECONFIG}" "${TALOSCONFIG_FILE}"

echo "Registering kubectl context ${TALOS_CONTEXT}..."
"${SCRIPT_DIR}/helpers/cluster-context-manager.sh" register-local "${TALOS_KUBECONFIG}" "${TALOS_CONTEXT}"

ANSIBLE_CMD=(
  ansible-playbook
  "${PROJECT_ROOT}/ansible/playbooks/k8s-bootstrap-cluster.yml"
  --vault-password-file
  "${HOME}/.ansible_vault_pass"
  -e
  "target_cluster=talos_cluster_test"
  -e
  "kubeconfig_path=${TALOS_KUBECONFIG}"
)

if [[ -n "${VERBOSITY}" ]]; then
  ANSIBLE_CMD+=("${VERBOSITY}")
fi

echo "Bootstrapping shared platform services on Talos..."
"${ANSIBLE_CMD[@]}"

echo
echo "Talos cluster deployment complete."
echo "kubectl context: ${TALOS_CONTEXT}"
echo "kubeconfig: ${TALOS_KUBECONFIG}"
echo "talosconfig: ${TALOSCONFIG_FILE}"
