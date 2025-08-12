#!/bin/bash
# k3s-shell-functions.sh
# Shell functions for easy K3s cluster management
# Source this file in your .bashrc or .zshrc: source ~/path/to/k3s-shell-functions.sh

# Get the directory of this script
K3S_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Quick cluster switching functions
function k3s-prod() {
    echo "🔄 Switching to production cluster..."
    "$K3S_SCRIPT_DIR/k3s-context-manager.sh" switch prod
}

function k3s-test() {
    echo "🔄 Switching to test cluster..."
    "$K3S_SCRIPT_DIR/k3s-context-manager.sh" switch test
}

# Show current cluster status
function k3s-status() {
    "$K3S_SCRIPT_DIR/k3s-context-manager.sh" status
}

# List all available contexts
function k3s-list() {
    "$K3S_SCRIPT_DIR/k3s-context-manager.sh" list
}

# Setup all clusters
function k3s-setup() {
    "$K3S_SCRIPT_DIR/k3s-context-manager.sh" setup
}

# Generic cluster switcher with tab completion
function k3s-switch() {
    if [ -z "$1" ]; then
        echo "Usage: k3s-switch [prod|test]"
        return 1
    fi
    "$K3S_SCRIPT_DIR/k3s-context-manager.sh" switch "$1"
}

# Tab completion for k3s-switch
if command -v complete > /dev/null; then
    complete -W "prod test" k3s-switch
fi

# Enhanced kubectl aliases that show current context
function k() {
    echo "🔍 Context: $(kubectl config current-context 2>/dev/null || echo 'none')"
    kubectl "$@"
}

# Cluster-aware aliases
alias kgp='kubectl get pods'
alias kgs='kubectl get services'  
alias kgn='kubectl get nodes'
alias kga='kubectl get all'
alias kns='kubectl get namespaces'
alias kdesc='kubectl describe'
alias klogs='kubectl logs'
alias kctx='kubectl config current-context'

# Quick cluster info with context display
function kinfo() {
    local current_ctx=$(kubectl config current-context 2>/dev/null || echo "none")
    echo -e "\033[0;34m📊 Current Context: $current_ctx\033[0m"
    
    if [ "$current_ctx" != "none" ]; then
        echo ""
        kubectl cluster-info
        echo ""
        kubectl get nodes -o wide
    else
        echo -e "\033[0;31m❌ No active context. Run 'k3s-setup' first.\033[0m"
    fi
}

# Show help for k3s functions
function k3s-help() {
    echo "🚀 K3s Cluster Management Functions:"
    echo ""
    echo "  k3s-prod       - Switch to production cluster"
    echo "  k3s-test       - Switch to test cluster"  
    echo "  k3s-switch     - Switch to specific cluster (with tab completion)"
    echo "  k3s-status     - Show current cluster status"
    echo "  k3s-list       - List all available contexts"
    echo "  k3s-setup      - Setup/update all cluster configs"
    echo "  kinfo          - Show cluster info with current context"
    echo "  k              - Enhanced kubectl with context display"
    echo ""
    echo "📋 Standard kubectl aliases:"
    echo "  kgp, kgs, kgn, kga, kns, kdesc, klogs, kctx"
    echo ""
    echo "💡 Pro tip: Use tab completion with k3s-switch!"
}

echo "✅ K3s cluster management functions loaded! Run 'k3s-help' for usage."