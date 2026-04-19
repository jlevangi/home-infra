#!/bin/bash
# Generic kubeconfig helper for locally-managed clusters such as Talos.

set -euo pipefail

LOCAL_KUBECONFIG_DIR="${HOME}/.kube"
MASTER_KUBECONFIG="${LOCAL_KUBECONFIG_DIR}/config"

mkdir -p "${LOCAL_KUBECONFIG_DIR}"

show_usage() {
    cat <<'EOF'
Usage: cluster-context-manager.sh [register-local|switch|list|status] ...

Commands:
  register-local <config> <context>
      Merge a kubeconfig file into ~/.kube/config and switch to <context>.
  switch <context>
      Switch kubectl to the named context.
  list
      List configured contexts.
  status
      Show the current context.
EOF
}

register_local() {
    local config_path="$1"
    local context_name="$2"
    local tmp_merge
    local source_context
    tmp_merge="$(mktemp)"

    if [[ ! -f "${config_path}" ]]; then
        echo "Missing kubeconfig: ${config_path}" >&2
        exit 1
    fi

    source_context="$(kubectl config current-context --kubeconfig "${config_path}")"
    if [[ -z "${source_context}" ]]; then
        echo "Could not determine source context from ${config_path}" >&2
        exit 1
    fi

    if [[ "${source_context}" != "${context_name}" ]]; then
        kubectl config rename-context "${source_context}" "${context_name}" --kubeconfig "${config_path}" >/dev/null
    fi

    if [[ -f "${MASTER_KUBECONFIG}" ]]; then
        KUBECONFIG="${MASTER_KUBECONFIG}:${config_path}" kubectl config view --flatten > "${tmp_merge}"
        mv "${tmp_merge}" "${MASTER_KUBECONFIG}"
    else
        cp "${config_path}" "${MASTER_KUBECONFIG}"
    fi

    chmod 600 "${MASTER_KUBECONFIG}"
    kubectl config use-context "${context_name}" >/dev/null
    echo "Configured kubeconfig context: ${context_name}"
}

case "${1:-}" in
    register-local)
        [[ $# -eq 3 ]] || { show_usage >&2; exit 1; }
        register_local "$2" "$3"
        ;;
    switch)
        [[ $# -eq 2 ]] || { show_usage >&2; exit 1; }
        kubectl config use-context "$2"
        ;;
    list)
        kubectl config get-contexts
        ;;
    status)
        kubectl config current-context
        ;;
    *)
        show_usage >&2
        exit 1
        ;;
esac
