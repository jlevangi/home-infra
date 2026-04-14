# Historical Note

This document is archived. It describes the rollout of dynamic environment support and is useful as implementation history, not as the current operator guide.

# Dynamic Environment Management

Your K3s infrastructure scripts now support dynamic environment management, making it easy to define and manage multiple environments.

## What Changed

### Before
- Scripts only supported `--prod` and `--test` flags
- Environment-specific logic was hardcoded in each script
- Adding new environments required modifying multiple scripts

### After
- Scripts support any environment defined in configuration
- Centralized environment configuration
- Easy to add new environments without modifying scripts
- Backward compatible with existing `--prod`, `--test`, `--stage` flags

## Environment Configuration

Environments are defined in `scripts/environments.conf`:

```
# Format: environment_name:ansible_group:display_name:emoji:kubectl_context:default_verbosity
prod:k3s_cluster:Production:🚀:prod:
test:k3s_cluster_test:Test:🧪:test:-v
stage:k3s_cluster_stage:Staging:🎭:stage:-v
```

## Usage Examples

### Existing Syntax (Backward Compatible)
```bash
# Deploy production cluster
./scripts/deploy-k3s-cluster.sh --prod

# Deploy test applications
./scripts/deploy-k3s-apps.sh --test

# Deploy staging cluster
./scripts/deploy-k3s-cluster.sh --stage
```

### New Generic Syntax
```bash
# Deploy to any environment
./scripts/deploy-k3s-cluster.sh --env prod
./scripts/deploy-k3s-cluster.sh --env test
./scripts/deploy-k3s-cluster.sh --env stage

# Deploy apps to any environment
./scripts/deploy-k3s-apps.sh --env prod
./scripts/deploy-k3s-apps.sh --env test
```

## Adding New Environments

To add a new environment (e.g., "dev"):

1. **Add to `scripts/environments.conf`:**
   ```
   dev:k3s_cluster_dev:Development:🔧:dev:-v
   ```

2. **Create Ansible group variables:**
   ```
   ansible/group_vars/k3s_cluster_dev.yml
   ```

3. **Create inventory file:**
   ```
   ansible/inventories/dev/hosts.yml
   ```
   
   Example content:
   ```yaml
   ---
   all:
     vars:
       ansible_user: <cluster-admin-user>
       ansible_ssh_private_key_file: ~/.ssh/<cluster-admin-key>
       ansible_python_interpreter: /usr/bin/python3
       ansible_ssh_common_args: '-o StrictHostKeyChecking=no'

   k3s_cluster_dev:
     children:
       k3s_cluster_dev_master:
         hosts:
           k3s-dev-node-1:
             ansible_host: 172.20.20.131
       k3s_cluster_dev_workers:
         hosts:
           k3s-dev-node-2:
             ansible_host: 172.20.20.132
   ```

4. **Update context manager:**
   Add dev cluster to `scripts/helpers/k3s-context-manager.sh` CLUSTERS array:
   ```bash
   CLUSTERS=(
       "prod:172.20.20.101:<cluster-admin-user>"
       "test:172.20.20.111:<cluster-admin-user>"
       "stage:172.20.20.121:<cluster-admin-user>"
       "dev:172.20.20.131:<cluster-admin-user>"   # New environment
   )
   ```

5. **Update inventory path mapping** (if needed):
   If the environment doesn't follow the standard pattern, add it to `get_inventory_path()` in `scripts/environment-functions.sh`

That's it! The scripts will automatically support the new environment:

```bash
./scripts/deploy-k3s-cluster.sh --env dev
./scripts/deploy-k3s-apps.sh --env dev
```

## Environment Configuration Fields

| Field | Description | Example |
|-------|-------------|---------|
| `environment_name` | Short name used in `--env` flag | `prod`, `test`, `dev` |
| `ansible_group` | Ansible inventory group name | `k3s_cluster`, `k3s_cluster_test` |
| `display_name` | Human-readable name for output | `Production`, `Test` |
| `emoji` | Visual identifier in script output | `🚀`, `🧪`, `🎭` |
| `kubectl_context` | Context for k3s-context-manager | `prod`, `test`, `stage` |
| `default_verbosity` | Default verbosity level | `""` (standard) or `"-v"` (verbose) |

## Inventory Structure

The inventory has been reorganized into separate files per environment:

```
ansible/
├── inventories/
│   ├── production/
│   │   └── hosts.yml
│   ├── test/
│   │   └── hosts.yml
│   └── staging/
│       └── hosts.yml
├── group_vars/
│   ├── k3s_cluster.yml          # Production variables
│   ├── k3s_cluster_test.yml     # Test variables
│   └── k3s_cluster_stage.yml    # Staging variables
└── k3s-inventory.old            # Backup of old inventory
```

### Benefits:
- **Environment Isolation**: Each environment has its own inventory
- **Cleaner Organization**: No mixing of environments in one file
- **Better Security**: Easier to manage access per environment
- **Scalability**: Easy to add new environments without cluttering

## Benefits

1. **Scalability**: Easy to add unlimited environments
2. **Consistency**: All environments follow the same patterns
3. **Maintainability**: Centralized configuration
4. **Backward Compatibility**: Existing scripts and workflows unchanged
5. **Flexibility**: Each environment can have unique settings
6. **Validation**: Scripts validate environment names automatically
7. **Clean Inventory**: Environment-specific inventory files
