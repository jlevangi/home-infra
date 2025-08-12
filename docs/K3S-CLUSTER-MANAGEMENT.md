# K3s Cluster Management

This directory contains an improved K3s cluster management system that supports multiple clusters with proper context switching.

## Overview

The new system uses Kubernetes contexts to manage multiple clusters cleanly, eliminating the need to overwrite config files when switching between clusters.

## Files

- **`k3s-context-manager.sh`** - Main script for managing cluster contexts
- **`k3s-shell-functions.sh`** - Shell functions for easy cluster switching

## Quick Start

1. **Initial Setup** - Configure all clusters:
   ```bash
   ./scripts/k3s-context-manager.sh setup
   ```

2. **Load Shell Functions** - Add to your `~/.bashrc` or `~/.zshrc`:
   ```bash
   source /path/to/home-infra/scripts/k3s-shell-functions.sh
   ```

3. **Switch Between Clusters**:
   ```bash
   k3s-prod     # Switch to production cluster
   k3s-test     # Switch to test cluster
   k3s-status   # Show current cluster status
   ```

## Available Commands

### Core Management
- `k3s-context-manager.sh setup` - Setup all cluster contexts
- `k3s-context-manager.sh switch [cluster]` - Switch to specific cluster
- `k3s-context-manager.sh list` - List available contexts
- `k3s-context-manager.sh status` - Show current cluster status

### Shell Functions (after sourcing k3s-shell-functions.sh)
- `k3s-prod` - Switch to production cluster
- `k3s-test` - Switch to test cluster
- `k3s-switch [cluster]` - Switch with tab completion
- `k3s-status` - Show current cluster status
- `k3s-list` - List all contexts
- `k3s-setup` - Setup/update all clusters
- `kinfo` - Enhanced cluster info with context display
- `k3s-help` - Show help for all functions

### Enhanced kubectl
- `k` - kubectl with context display
- Standard aliases: `kgp`, `kgs`, `kgn`, `kga`, `kns`, `kdesc`, `klogs`, `kctx`

## Configuration

The system is configured for two clusters:
- **prod**: 172.20.20.101 (k3s-prod context)
- **test**: 172.20.20.111 (k3s-test context)

## Benefits

1. **No Config Conflicts** - Each cluster has its own context
2. **Easy Switching** - Simple commands to switch between clusters
3. **Context Awareness** - Always know which cluster you're working with
4. **Tab Completion** - Auto-completion for cluster names

## Migration from Old Scripts

The old `setup-local-kubeconfig.sh` and `setup-local-kubeconfig-test-cluster.sh` scripts now act as wrappers and will:
1. Show deprecation warning
2. Run the new context manager
3. Guide you to use the new functions

## Examples

```bash
# Setup all clusters
k3s-setup

# Switch to production and check nodes
k3s-prod
k get nodes

# Switch to test cluster and check pods
k3s-test
k get pods

# See current context and cluster info
kinfo

# List all available contexts
k3s-list
```