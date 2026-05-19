#!/bin/bash
# talos-context-manager.sh
# Manage kubeconfig and talosconfig for Talos clusters.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_SCRIPT_DIR/../../.." && pwd)"

LOCAL_KUBECONFIG_DIR="${HOME}/.kube"
LOCAL_TALOSCONFIG_DIR="${HOME}/.talos"
MASTER_KUBECONFIG="${LOCAL_KUBECONFIG_DIR}/config"

ENVIRONMENTS_CONF="${_PROJECT_ROOT}/scripts/lib/talos-environments.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "${LOCAL_KUBECONFIG_DIR}" "${LOCAL_TALOSCONFIG_DIR}"

# Read a field from talos-environments.conf
# Usage: get_env_field "test" 2  (1=name, 2=ansible_group, 3=display, 4=emoji, 5=context)
get_env_field() {
    local env="$1" field="$2"
    grep "^${env}:" "${ENVIRONMENTS_CONF}" 2>/dev/null | cut -d: -f"${field}"
}

get_all_envs() {
    grep -v '^#' "${ENVIRONMENTS_CONF}" | grep -v '^$' | cut -d: -f1
}

# Resolve paths for a given environment
env_kubeconfig()  { echo "${LOCAL_KUBECONFIG_DIR}/config-talos-${1}"; }
env_talosconfig() { echo "${LOCAL_TALOSCONFIG_DIR}/config-talos-${1}"; }
env_context()     { get_env_field "$1" 5; }

show_usage() {
    cat <<EOF
Usage: talos-context-manager.sh <command> [args]

Commands:
  setup [ENV]       Register kubeconfig + talosconfig for ENV (or all envs)
  switch <ENV>      Switch kubectl and talosctl to the named environment
  list              List configured Talos contexts and their status
  status            Show current context info
  aliases           Print shell aliases for all Talos environments

Examples:
  $0 setup test           # Register talos-test kubeconfig + talosconfig
  $0 setup                # Register all available Talos environments
  $0 switch test          # Switch to talos-test
  $0 aliases              # Print aliases to eval in your shell

Add to your shell profile:
  eval "\$($0 aliases)"
EOF
}

# Merge a kubeconfig into the master config and set the context name
register_kubeconfig() {
    local config_path="$1"
    local context_name="$2"

    if [[ ! -f "${config_path}" ]]; then
        echo -e "${RED}Missing kubeconfig: ${config_path}${NC}" >&2
        return 1
    fi

    # Remove any existing entries for this context to avoid stale certs
    kubectl config delete-context "${context_name}" 2>/dev/null || true
    kubectl config delete-cluster "${context_name}" 2>/dev/null || true

    # Also clean up the authinfo name from the source config
    local source_context
    source_context="$(kubectl config current-context --kubeconfig "${config_path}" 2>/dev/null)" || true
    if [[ -n "${source_context}" && "${source_context}" != "${context_name}" ]]; then
        kubectl config delete-context "${source_context}" 2>/dev/null || true
        kubectl config delete-user "${source_context}" 2>/dev/null || true
        kubectl config rename-context "${source_context}" "${context_name}" --kubeconfig "${config_path}" >/dev/null 2>&1 || true
    fi

    local tmp_merge
    tmp_merge="$(mktemp)"
    if [[ -f "${MASTER_KUBECONFIG}" ]]; then
        KUBECONFIG="${MASTER_KUBECONFIG}:${config_path}" kubectl config view --flatten > "${tmp_merge}"
        mv "${tmp_merge}" "${MASTER_KUBECONFIG}"
    else
        cp "${config_path}" "${MASTER_KUBECONFIG}"
    fi
    chmod 600 "${MASTER_KUBECONFIG}"
}

# Register talosconfig: merge into ~/.talos/config or set as the active config
register_talosconfig() {
    local config_path="$1"
    local context_name="$2"
    local master_talosconfig="${LOCAL_TALOSCONFIG_DIR}/config"

    if [[ ! -f "${config_path}" ]]; then
        echo -e "${RED}Missing talosconfig: ${config_path}${NC}" >&2
        return 1
    fi

    if command -v talosctl >/dev/null 2>&1; then
        # Merge into the default talosconfig
        if [[ -f "${master_talosconfig}" ]]; then
            talosctl config merge "${config_path}" 2>/dev/null || cp "${config_path}" "${master_talosconfig}"
        else
            cp "${config_path}" "${master_talosconfig}"
        fi
        chmod 600 "${master_talosconfig}"
    else
        # talosctl not installed yet — just note the standalone path
        echo -e "${YELLOW}  talosctl not found; talosconfig saved at ${config_path}${NC}"
        echo -e "${YELLOW}  Install talosctl and use: talosctl --talosconfig ${config_path}${NC}"
    fi
}

setup_env() {
    local env="$1"
    local display context kubeconfig talosconfig

    display="$(get_env_field "${env}" 3)"
    context="$(env_context "${env}")"
    kubeconfig="$(env_kubeconfig "${env}")"
    talosconfig="$(env_talosconfig "${env}")"

    echo -e "${BLUE}Setting up ${display} Talos cluster (${context})...${NC}"

    if [[ ! -f "${kubeconfig}" ]]; then
        echo -e "${YELLOW}  Kubeconfig not found: ${kubeconfig}${NC}"
        echo -e "${YELLOW}  Run scripts/talos/deploy-cluster.sh --${env} first${NC}"
        return 1
    fi

    register_kubeconfig "${kubeconfig}" "${context}"
    echo -e "${GREEN}  kubectl context '${context}' registered${NC}"

    if [[ -f "${talosconfig}" ]]; then
        register_talosconfig "${talosconfig}" "${context}"
        echo -e "${GREEN}  talosconfig registered${NC}"
    else
        echo -e "${YELLOW}  No talosconfig found at ${talosconfig} (optional)${NC}"
    fi

    return 0
}

cmd_setup() {
    local target="${1:-}"

    if [[ -n "${target}" ]]; then
        if ! get_env_field "${target}" 1 >/dev/null 2>&1 || [[ -z "$(get_env_field "${target}" 1)" ]]; then
            echo -e "${RED}Unknown environment: ${target}${NC}" >&2
            echo "Available: $(get_all_envs | tr '\n' ' ')" >&2
            return 1
        fi
        setup_env "${target}"
    else
        echo -e "${BLUE}Setting up all Talos clusters...${NC}"
        echo ""
        local success=0 total=0
        while IFS= read -r env; do
            [[ -z "${env}" ]] && continue
            total=$((total + 1))
            if setup_env "${env}"; then
                success=$((success + 1))
            fi
            echo ""
        done <<< "$(get_all_envs)"
        echo -e "${GREEN}Registered ${success}/${total} Talos clusters${NC}"
    fi
}

cmd_switch() {
    local env="${1:-}"
    if [[ -z "${env}" ]]; then
        echo "Usage: $0 switch <env>" >&2
        echo "Available: $(get_all_envs | tr '\n' ' ')" >&2
        return 1
    fi

    local context
    context="$(env_context "${env}")"
    if [[ -z "${context}" ]]; then
        echo -e "${RED}Unknown environment: ${env}${NC}" >&2
        return 1
    fi

    kubectl config use-context "${context}" 2>/dev/null || {
        echo -e "${RED}Context '${context}' not found. Run '$0 setup ${env}' first.${NC}" >&2
        return 1
    }
    echo -e "${GREEN}Switched kubectl to ${context}${NC}"

    if command -v talosctl >/dev/null 2>&1; then
        local talosconfig
        talosconfig="$(env_talosconfig "${env}")"
        if [[ -f "${talosconfig}" ]]; then
            talosctl config context "${context}" 2>/dev/null || true
            echo -e "${GREEN}Switched talosctl to ${context}${NC}"
        fi
    fi
}

cmd_list() {
    echo -e "${BLUE}Talos cluster contexts:${NC}"
    echo ""
    printf "  %-12s %-14s %-30s %-30s\n" "ENV" "CONTEXT" "KUBECONFIG" "TALOSCONFIG"
    printf "  %-12s %-14s %-30s %-30s\n" "---" "-------" "----------" "-----------"
    while IFS= read -r env; do
        [[ -z "${env}" ]] && continue
        local context kubeconfig talosconfig kube_status talos_status
        context="$(env_context "${env}")"
        kubeconfig="$(env_kubeconfig "${env}")"
        talosconfig="$(env_talosconfig "${env}")"
        kube_status=$([[ -f "${kubeconfig}" ]] && echo "ok" || echo "missing")
        talos_status=$([[ -f "${talosconfig}" ]] && echo "ok" || echo "missing")
        printf "  %-12s %-14s %-30s %-30s\n" "${env}" "${context}" "${kube_status}" "${talos_status}"
    done <<< "$(get_all_envs)"
    echo ""

    local current
    current="$(kubectl config current-context 2>/dev/null)" || current="(none)"
    echo -e "  Current kubectl context: ${current}"
}

cmd_status() {
    local current
    current="$(kubectl config current-context 2>/dev/null)" || current="(none)"
    echo -e "${BLUE}Current context:${NC} ${current}"

    if [[ "${current}" == talos-* ]] && timeout 5 kubectl cluster-info >/dev/null 2>&1; then
        echo -e "${GREEN}Cluster is reachable${NC}"
        kubectl get nodes -o wide
    elif [[ "${current}" == talos-* ]]; then
        echo -e "${RED}Cannot connect to cluster${NC}"
    fi
}

cmd_aliases() {
    echo "# Talos cluster context aliases"
    echo "#   eval \"\$(${_PROJECT_ROOT}/scripts/talos/helpers/talos-context-manager.sh aliases)\""
    while IFS= read -r env; do
        [[ -z "${env}" ]] && continue
        local context
        context="$(env_context "${env}")"
        echo "alias ${context}='kubectl config use-context ${context}'"
    done <<< "$(get_all_envs)"
}

case "${1:-}" in
    setup)   cmd_setup "${2:-}" ;;
    switch)  cmd_switch "${2:-}" ;;
    list)    cmd_list ;;
    status)  cmd_status ;;
    aliases) cmd_aliases ;;
    *)       show_usage >&2; exit 1 ;;
esac
