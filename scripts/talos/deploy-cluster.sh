#!/bin/bash
# Deploy a Talos cluster, configure local access, then bootstrap the
# shared cluster_platform services (Longhorn, MetalLB, Traefik, ArgoCD,
# Vault).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/environment-functions.sh"
ENVIRONMENTS_CONF="$PROJECT_ROOT/scripts/lib/talos-environments.conf"

require_ansible_config || exit 1

TARGET_ENV=""
VERBOSITY=""
SHOW_HELP=false
AUTO_APPROVE=false
MACHINE_CONFIG_APPLY_MODE="${TALOS_MACHINE_CONFIG_MODE:-auto}"

get_talos_env_field() {
  local env_name="$1"
  local field="$2"

  grep "^${env_name}:" "${ENVIRONMENTS_CONF}" 2>/dev/null | cut -d: -f"${field}"
}

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
      TARGET_ENV="$2"
      shift 2
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

if [[ "${SHOW_HELP}" == "true" ]] || [[ -z "${TARGET_ENV}" ]]; then
  cat <<'EOF'
Usage: scripts/talos/deploy-cluster.sh --test|--stage|--prod [options]

EOF
  show_environment_help "scripts/talos/deploy-cluster.sh" "Deploy"
  cat <<'EOF'

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
  if [[ -z "${TARGET_ENV}" ]]; then
    echo ""
    echo "❌ Error: Target environment must be specified (--test, --stage, or --prod)"
    exit 1
  fi
  exit 0
fi

setup_environment_vars "${TARGET_ENV}" || exit 1

if [[ -n "${DEFAULT_VERBOSITY}" && -z "${VERBOSITY}" ]]; then
  VERBOSITY="${DEFAULT_VERBOSITY}"
fi

TALOS_CONTEXT="$(get_talos_env_field "${TARGET_ENV}" 5)"
TALOS_DEFAULT_VERBOSITY="$(get_talos_env_field "${TARGET_ENV}" 6)"
if [[ -z "${TALOS_CONTEXT}" ]]; then
  TALOS_CONTEXT="talos-${TARGET_ENV}"
fi
if [[ -n "${TALOS_DEFAULT_VERBOSITY}" && -z "${VERBOSITY}" ]]; then
  VERBOSITY="${TALOS_DEFAULT_VERBOSITY}"
fi

TERRAFORM_DIR="${PROJECT_ROOT}/terraform/stacks/talos/${TARGET_ENV}"
LOCAL_KUBECONFIG_DIR="${HOME}/.kube"
LOCAL_TALOSCONFIG_DIR="${HOME}/.talos"
TALOS_KUBECONFIG="${LOCAL_KUBECONFIG_DIR}/config-${TALOS_CONTEXT}"
TALOSCONFIG_FILE="${LOCAL_TALOSCONFIG_DIR}/config-${TALOS_CONTEXT}"

require_command terraform "Talos VM/bootstrap provisioning"
require_command ansible-playbook "shared cluster platform bootstrap"
require_command kubectl "kubeconfig registration and cluster bootstrap"
require_command helm "Longhorn, MetalLB, Traefik, and ArgoCD installation"
require_command jq "Helm status parsing inside the shared platform role"

if [[ ! -f "${HOME}/.ansible_vault_pass" ]]; then
  echo "❌ Missing ~/.ansible_vault_pass" >&2
  echo "   Needed for Ansible Vault secrets during cluster platform bootstrap" >&2
  exit 1
fi

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "❌ Terraform directory not found: ${TERRAFORM_DIR}" >&2
  echo "   Create it before deploying the ${CLUSTER_NAME} Talos cluster" >&2
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

echo "${CLUSTER_EMOJI} Deploying ${CLUSTER_NAME} Talos cluster..."
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

echo "Deploying Talos cluster with Terraform..."
"${TF_CMD[@]}"

echo "Writing local kubeconfig and talosconfig..."
terraform -chdir="${TERRAFORM_DIR}" output -raw kubeconfig > "${TALOS_KUBECONFIG}"
terraform -chdir="${TERRAFORM_DIR}" output -raw talosconfig > "${TALOSCONFIG_FILE}"
chmod 600 "${TALOS_KUBECONFIG}" "${TALOSCONFIG_FILE}"

echo "Registering kubectl context ${TALOS_CONTEXT}..."
"${PROJECT_ROOT}/scripts/helpers/cluster-context-manager.sh" register-local "${TALOS_KUBECONFIG}" "${TALOS_CONTEXT}"

ANSIBLE_CMD=(
  ansible-playbook
  "${PROJECT_ROOT}/ansible/playbooks/k8s-bootstrap-cluster.yml"
  --vault-password-file
  "${HOME}/.ansible_vault_pass"
  -e
  "target_cluster=${TARGET_CLUSTER}"
  -e
  "kubeconfig_path=${TALOS_KUBECONFIG}"
)

if [[ -n "${VERBOSITY}" ]]; then
  ANSIBLE_CMD+=("${VERBOSITY}")
fi

echo "Bootstrapping shared cluster platform services on ${CLUSTER_NAME} Talos cluster..."
"${ANSIBLE_CMD[@]}"

echo
echo "${CLUSTER_EMOJI} Talos cluster deployment complete."
echo "kubectl context: ${TALOS_CONTEXT}"
echo "kubeconfig: ${TALOS_KUBECONFIG}"
echo "talosconfig: ${TALOSCONFIG_FILE}"
