#!/bin/bash
# talos-shell-functions.sh
# Shell functions for easy Talos cluster management
# Source this file in your .bashrc or .zshrc: source ~/path/to/home-infra/scripts/talos/helpers/talos-shell-functions.sh

# Get the directory of this script
TALOS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Quick cluster switching functions
function talos-prod() {
    echo "Switching to Talos production cluster..."
    "$TALOS_SCRIPT_DIR/talos-context-manager.sh" switch prod
}

function talos-test() {
    echo "Switching to Talos test cluster..."
    "$TALOS_SCRIPT_DIR/talos-context-manager.sh" switch test
}

function talos-stage() {
    echo "Switching to Talos stage cluster..."
    "$TALOS_SCRIPT_DIR/talos-context-manager.sh" switch stage
}

# Show current cluster status
function talos-status() {
    "$TALOS_SCRIPT_DIR/talos-context-manager.sh" status
}

# List all available Talos contexts
function talos-list() {
    "$TALOS_SCRIPT_DIR/talos-context-manager.sh" list
}

# Setup all Talos clusters
function talos-setup() {
    "$TALOS_SCRIPT_DIR/talos-context-manager.sh" setup "$@"
}

# Generic cluster switcher with tab completion
function talos-switch() {
    if [ -z "$1" ]; then
        echo "Usage: talos-switch [prod|stage|test]"
        return 1
    fi
    "$TALOS_SCRIPT_DIR/talos-context-manager.sh" switch "$1"
}

# Tab completion for talos-switch
if command -v complete > /dev/null; then
    complete -W "prod stage test" talos-switch
fi

# Show help for talos functions
function talos-help() {
    echo "Talos Cluster Management Functions:"
    echo ""
    echo "  talos-prod      - Switch to production cluster"
    echo "  talos-stage     - Switch to stage cluster"
    echo "  talos-test      - Switch to test cluster"
    echo "  talos-switch    - Switch to specific cluster (with tab completion)"
    echo "  talos-status    - Show current cluster status"
    echo "  talos-list      - List all available Talos contexts"
    echo "  talos-setup     - Setup/update Talos cluster configs"
    echo ""
    echo "Shared kubectl aliases (from k3s-shell-functions.sh):"
    echo "  kgp, kgs, kgn, kga, kns, kdesc, klogs, kctx, kinfo"
}

echo "Talos cluster management functions loaded. Run 'talos-help' for usage."
