# Plan 02: Decompose Longhorn God File

## Goal

Split `longhorn.yml` (963 lines) into 5 focused, independently maintainable task files. Each file will handle a single logical concern, making the code easier to read, test, and modify.

## Current State

`longhorn.yml` is a 963-line monolith that handles:
- API server and CRD readiness checks (lines 1-83)
- Helm repo and installation lifecycle (lines 91-294)
- GPU toleration and master node scheduling patches (lines 335-429)
- StorageClass, BackupTarget, and volume replica adjustments (lines 431-788)
- PVC validation and health checks (lines 587-657)
- DNS record creation (lines 837-847)
- Longhorn UI Ingress creation (lines 849-887)
- Backup recurring job management (lines 889-939)
- Debug/status output (scattered throughout)

This single file violates the Single Responsibility Principle and makes it difficult to:
- Find a specific section of logic
- Test individual concerns in isolation
- Understand the dependency ordering
- Reuse logic in other contexts (e.g., the restore playbook)

## Target State

Five focused task files, invoked from a new coordinator file:

```
ansible/roles/k3s/tasks/
├── longhorn.yml              # Removed (replaced by longhorn-coordinator.yml)
├── longhorn-coordinator.yml  # NEW: orchestrates all Longhorn sub-tasks
├── longhorn-readiness.yml    # NEW: API server & CRD checks
├── longhorn-install.yml      # NEW: Helm chart lifecycle
├── longhorn-node-config.yml  # NEW: Tolerations, node scheduling
├── longhorn-storage-config.yml  # NEW: StorageClass, backup targets, replica tuning
└── longhorn-validation.yml   # NEW: PVC tests & health verification
```

## Affected Files

| File | Action |
|------|--------|
| `ansible/roles/k3s/tasks/longhorn.yml` | Delete (content migrated to sub-files) |
| `ansible/roles/k3s/tasks/longhorn-coordinator.yml` | **Create** — orchestrator |
| `ansible/roles/k3s/tasks/longhorn-readiness.yml` | **Create** — lines 1-83 |
| `ansible/roles/k3s/tasks/longhorn-install.yml` | **Create** — lines 91-294 |
| `ansible/roles/k3s/tasks/longhorn-node-config.yml` | **Create** — lines 335-429 |
| `ansible/roles/k3s/tasks/longhorn-storage-config.yml` | **Create** — lines 431-788 |
| `ansible/roles/k3s/tasks/longhorn-validation.yml` | **Create** — lines 587-657, 777-788 |
| `ansible/roles/k3s/tasks/infra-install.yml` | Modify — update include reference |

## Step-by-Step Tasks

### Phase 1: Create `longhorn-readiness.yml`

Extract lines 1–83 from `longhorn.yml`. This file handles:
- Adding the Longhorn Helm repo
- Waiting for API server readiness (nodes, pods, healthz, fallback)
- CRD API readiness checks
- Displaying comprehensive API status
- The 60-second stability wait

**Variables it uses:**
- None (uses only cluster connectivity)

**Output:**
- Sets no facts; only registers status variables for debug display

### Phase 2: Create `longhorn-install.yml`

Extract lines 91–294 from `longhorn.yml`. This file handles:
- Checking Longhorn namespace, pods, and Helm release existence
- Displaying current Longhorn status
- Cleaning up stuck/pending Helm operations
- Cleaning up failed Longhorn releases
- Final CRD readiness check
- Calculating dynamic replica count
- Building Longhorn scheduling tolerations JSON
- Helm install / upgrade / repair operations

**Variables it uses:**
- `longhorn_replica_count`
- `longhorn_storage_reserved_percentage_for_default_disk`
- `longhorn_guaranteed_instance_manager_cpu`
- `longhorn_concurrent_replica_rebuild_per_node_limit`
- `enable_longhorn_backup`
- `nfs_server_ip`, `nfs_share_backup`
- `longhorn_backup_shared_across_clusters`
- `cluster_environment`
- `longhorn_exclude_master_from_storage`
- `cluster_group`
- `master_group`
- `k3s_needs_install` (guard on the 60s pause)

**Output:**
- Sets `calculated_replica_count`
- Sets `longhorn_global_tolerations_json`
- Sets `longhorn_taint_toleration_value`
- Registers `longhorn_install_result`, `longhorn_update_result`, `longhorn_repair_result`

### Phase 3: Create `longhorn-node-config.yml`

Extract lines 335–429 from `longhorn.yml`. This file handles:
- Patching Longhorn daemonsets for GPU toleration (`accelerator=nvidia`)
- Waiting for patched daemonsets to roll out
- Patching Longhorn deployments to exclude control-plane nodes (when `longhorn_exclude_master_from_storage` is true)
- Waiting for patched deployments to roll out

**Variables it uses:**
- `longhorn_exclude_master_from_storage`
- `longhorn_global_tolerations_json` (from `longhorn-install.yml`)
- `master_group`

**Output:**
- Registers `longhorn_gpu_toleration_patch`, `longhorn_daemonsets`, `longhorn_deployments`

### Phase 4: Create `longhorn-storage-config.yml`

Extract lines 431–788 from `longhorn.yml`. This file handles:
- StorageClass ConfigMap update and recreation
- BackupTarget resource update
- Replica count and auto-balance adjustments on existing volumes
- Debug/status output for storage configuration

**Variables it uses:**
- `longhorn_replica_count`
- `calculated_replica_count`
- `longhorn_replica_auto_balance`
- `longhorn_storage_reserved_percentage_for_default_disk`
- `nfs_server_ip`, `nfs_share_backup`
- `longhorn_backup_shared_across_clusters`
- `cluster_environment`
- `enable_longhorn_backup`

**Output:**
- Registers `storageclass_configmap_update_result`, `storageclass_update_result`, `backup_target_update_result`, `setting_update_result`, `storage_reservation_setting_update_result`, `replica_auto_balance_setting_result`

### Phase 5: Create `longhorn-validation.yml`

Extract lines 587–657, 777–788 from `longhorn.yml`. This file handles:
- Validation PVC creation, binding wait, and cleanup
- Volume health checks after replica adjustments

**Variables it uses:**
- `longhorn_replica_count`
- `calculated_replica_count`
- `longhorn_replica_auto_balance`

**Output:**
- Registers `existing_pvc`, `longhorn_validation_result`, `pvc_wait_result`, `volume_health_check`

### Phase 6: Create `longhorn-coordinator.yml`

Create a new coordinator file that orchestrates all sub-tasks in the correct dependency order:

```yaml
---
# Longhorn Coordinator
# Orchestrates all Longhorn-related tasks in dependency order

- name: Check API server and CRD readiness
  include_tasks: longhorn-readiness.yml
  tags: [longhorn, readiness]

- name: Calculate dynamic replica count
  set_fact:
    calculated_replica_count: "{{ [groups[cluster_group] | default([]) | length, 3] | min }}"
  when: longhorn_replica_count is not defined

- name: Build Longhorn scheduling tolerations
  set_fact:
    longhorn_global_tolerations_json: >-
      {{
        [
          {'key': 'CriticalAddonsOnly', 'operator': 'Equal', 'value': 'true', 'effect': 'NoExecute'},
          {'key': 'accelerator', 'operator': 'Equal', 'value': 'nvidia', 'effect': 'NoSchedule'}
        ] | to_json
      }}
    longhorn_taint_toleration_value: 'CriticalAddonsOnly=true:NoExecute'

- name: Install/upgrade Longhorn Helm chart
  include_tasks: longhorn-install.yml
  tags: [longhorn, install]

- name: Apply node scheduling configuration
  include_tasks: longhorn-node-config.yml
  tags: [longhorn, node-config]
  when: longhorn_exclude_master_from_storage | default(false) | bool or nvidia_gpu_worker | default(false) | bool

- name: Apply storage class and backup configuration
  include_tasks: longhorn-storage-config.yml
  tags: [longhorn, storage-config]

- name: Validate Longhorn installation
  include_tasks: longhorn-validation.yml
  tags: [longhorn, validation]
```

### Phase 7: Update `infra-install.yml`

Replace the `include_tasks: longhorn.yml` reference with `include_tasks: longhorn-coordinator.yml`.

### Phase 8: Remove Original `longhorn.yml`

Delete `ansible/roles/k3s/tasks/longhorn.yml` after confirming the new coordinator produces identical behavior.

## Validation

1. Run `ansible-playbook ansible/playbooks/k3s-deploy-cluster.yml --check` — all Longhorn tasks should be discovered under the `longhorn` tag.
2. Run the playbook against a test cluster and verify:
   - Longhorn installs correctly with the expected replica count
   - GPU tolerations are applied to daemonsets
   - Control-plane nodes are excluded from storage (if configured)
   - StorageClass is created with correct parameters
   - Backup targets and recurring jobs are configured
   - Validation PVC binds and is cleaned up
3. Verify that no references to `longhorn.yml` remain in any file.
4. Verify that each sub-file can be included independently using tags (e.g., `--tags longhorn-readiness`).
