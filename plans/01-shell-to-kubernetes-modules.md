# Plan 01: Replace Shell Calls with Kubernetes/Helm Modules

## Goal

Eliminate all `ansible.builtin.shell` calls that invoke `kubectl`, `helm`, or `kubectl`-related operations and replace them with native `kubernetes.core.k8s` and `kubernetes.core.helm` modules. This provides true idempotency, structured error handling, and removes the need for manual `KUBECONFIG` environment variable management.

## Current State

Across the role — and most heavily in `longhorn.yml` — Kubernetes and Helm operations are implemented as shell commands:

```yaml
# Current pattern (longhorn.yml:233)
- name: Install Longhorn (fresh installation only)
  ansible.builtin.shell: |
    KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm install longhorn longhorn/longhorn \
      --namespace longhorn-system \
      --set-json='global.tolerations={{ ... }}' \
      --wait --timeout=1200s
  become: yes
  register: longhorn_install_result
  retries: 3
  delay: 60
  until: longhorn_install_result.rc == 0
```

```yaml
# Current pattern (longhorn.yml:345)
- name: Patch Longhorn daemonsets to tolerate accelerator=nvidia
  ansible.builtin.shell: |
    KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl patch {{ item }} -n longhorn-system \
      --type='merge' -p='{...}'
  loop: "{{ longhorn_daemonsets.stdout_lines | default([]) }}"
```

Issues with this approach:
- Every command manually prefixes `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`
- No idempotency — each run applies the same `kubectl patch` regardless of whether the resource already has the desired state
- Error messages are raw stdout/stderr with no structured parsing
- `kubectl get ... | wc -l` and similar count/grep patterns are fragile and break on edge cases
- Helm operations lack the `helm` module's built-in version tracking and rollback support

## Target State

All Kubernetes resource operations use `kubernetes.core.k8s` module:

```yaml
# Target pattern
- name: Patch Longhorn daemonsets to tolerate accelerator=nvidia
  kubernetes.core.k8s:
    kubeconfig: /etc/rancher/k3s/k3s.yaml
    state: patched
    resource_definition: |
      apiVersion: apps/v1
      kind: DaemonSet
      metadata:
        name: "{{ item | regex_replace('daemonset/', '') }}"
        namespace: longhorn-system
      spec:
        template:
          spec:
            tolerations:
              - key: accelerator
                operator: Equal
                value: nvidia
                effect: NoSchedule
              - key: CriticalAddonsOnly
                operator: Equal
                value: "true"
                effect: NoExecute
    definition:
      metadata:
        name: "{{ item | regex_replace('daemonset/', '') }}"
        namespace: longhorn-system
```

All Helm operations use `kubernetes.core.helm` module:

```yaml
# Target pattern
- name: Install Longhorn (fresh installation)
  kubernetes.core.helm:
    kubeconfig: /etc/rancher/k3s/k3s.yaml
    chart_ref: longhorn/longhorn
    chart_repo_url: https://charts.longhorn.io
    release_name: longhorn
    release_namespace: longhorn-system
    create_namespace: true
    values:
      global:
        tolerations:
          - key: accelerator
            operator: Equal
            value: nvidia
            effect: NoSchedule
          - key: CriticalAddonsOnly
            operator: Equal
            value: "true"
            effect: NoExecute
      defaultSettings:
        taintToleration: "CriticalAddonsOnly=true:NoExecute"
        defaultReplicaCount: "{{ longhorn_replica_count | default(calculated_replica_count | default(3)) }}"
        storageReservedPercentageForDefaultDisk: "{{ longhorn_storage_reserved_percentage_for_default_disk | default(5) }}"
        defaultDataPath: "/var/lib/longhorn/"
        guaranteedInstanceManagerCPU: "{{ longhorn_guaranteed_instance_manager_cpu | default(12) }}"
        concurrentReplicaRebuildPerNodeLimit: "{{ longhorn_concurrent_replica_rebuild_per_node_limit | default(5) }}"
        backupTarget: "nfs://{{ nfs_server_ip }}:{{ nfs_share_backup }}{% if longhorn_backup_shared_across_clusters | default(false) %}/shared{% else %}/{{ cluster_environment | default('prod') }}{% endif %}"
    wait: true
    timeout: 1200
  register: longhorn_install_result
```

## Affected Files

| File | Scope of Change |
|------|-----------------|
| `ansible/roles/k3s/tasks/longhorn.yml` | Majority of changes — all `kubectl`, `helm`, and `kubectl apply -f -` heredocs |
| `ansible/roles/k3s/tasks/master.yml` | `slurp` of node-token, kubeconfig operations |
| `ansible/roles/k3s/tasks/worker.yml` | K3s agent status checks |
| `ansible/roles/k3s/tasks/shared/dns_management.yml` | Already uses `uri` module — no changes needed |
| `ansible/roles/k3s/requirements.yml` | May need to add `kubernetes.core` collection requirement |

## Step-by-Step Tasks

### Phase 1: Preparation

1.1. Verify `kubernetes.core` collection is installed on the control node:
  ```bash
  ansible-galaxy collection list | grep kubernetes.core
  ```

1.2. If not installed, add it to `ansible/requirements.yml`:
  ```yaml
  collections:
    - name: kubernetes.core
      version: ">=3.0.0"
  ```

1.3. Install the collection:
  ```bash
  ansible-galaxy collection install -r ansible/requirements.yml
  ```

1.4. Document the current behavior by running the K3s deployment playbook against a test cluster and capturing the output of all Longhorn-related shell commands.

### Phase 2: Kubernetes Resource Operations (`kubectl` → `kubernetes.core.k8s`)

2.1. Replace all `kubectl get` calls that query resource existence/state:
  - `longhorn.yml:91-96`: Namespace existence check → `kubernetes.core.k8s_info`
  - `longhorn.yml:98-104`: Pod existence check → `kubernetes.core.k8s_info` with label selectors
  - `longhorn.yml:114-118`: Pending Helm operations → `kubernetes.core.k8s_info` for Helm release secrets
  - `longhorn.yml:336-342`: DaemonSet listing → `kubernetes.core.k8s_info`
  - `longhorn.yml:372-378`: Deployment listing → `kubernetes.core.k8s_info`
  - `longhorn.yml:391-418`: Volume listing → `kubernetes.core.k8s_info`
  - `longhorn.yml:596-598`: PVC deletion → `kubernetes.core.k8s` with `state: absent`
  - `longhorn.yml:659-667`: Longhorn node existence check → `kubernetes.core.k8s_info`

2.2. Replace all `kubectl patch` calls:
  - `longhorn.yml:345-370`: DaemonSet toleration patching → `kubernetes.core.k8s` with `state: patched`
  - `longhorn.yml:381-429`: Deployment affinity patching → `kubernetes.core.k8s` with `state: patched`
  - `longhorn.yml:445-458`: Longhorn setting patches → `kubernetes.core.k8s`
  - `longhorn.yml:670-676`: Master node storage scheduling patch → `kubernetes.core.k8s`
  - `longhorn.yml:716-724`: Volume replica patching → `kubernetes.core.k8s`
  - `longhorn.yml:737-745`: Volume auto-balance patching → `kubernetes.core.k8s`
  - `longhorn.yml:818-822`: Frontend service NodePort patch → `kubernetes.core.k8s`
  - `longhorn.yml:804-815`: Non-storage worker exclusion patch → `kubernetes.core.k8s`

2.3. Replace all `kubectl apply -f -` heredoc blocks:
  - `longhorn.yml:601-616`: Validation PVC → `kubernetes.core.k8s` with `definition` parameter
  - `longhorn.yml:849-887`: Longhorn UI Ingress → `kubernetes.core.k8s` with `definition` parameter
  - `longhorn.yml:907-939`: Backup recurring jobs → `kubernetes.core.k8s` with `definition` parameter (as a list)
  - `longhorn.yml:502-528`: StorageClass recreation → `kubernetes.core.k8s` with `state: present` and `definition`

2.4. Replace all `kubectl delete` calls:
  - `longhorn.yml:190-195`: Helm secret cleanup → `kubernetes.core.k8s` with `state: absent` and label selector
  - `longhorn.yml:890-896`: RecurringJob deletion → `kubernetes.core.k8s` with `state: absent` and `all: true`
  - `longhorn.yml:655-657`: Test PVC cleanup → `kubernetes.core.k8s` with `state: absent`

2.5. Replace all `kubectl rollout status` calls:
  - `longhorn.yml:362-369`, `longhorn.yml:420-429`: DaemonSet and deployment rollout waits → Use `kubernetes.core.k8s` with `wait: true` or replace with `kubernetes.core.k8s_wait`

### Phase 3: Helm Operations (`helm` CLI → `kubernetes.core.helm`)

3.1. Replace `helm repo add` / `helm repo update`:
  - `longhorn.yml:3-16`: These are idempotency guards for Helm repo state. Replace with `kubernetes.core.helm_repo` module.

3.2. Replace `helm status` checks:
  - `longhorn.yml:106-111`: Helm release existence → `kubernetes.core.k8s_info` querying release secrets in the namespace

3.3. Replace `helm install`:
  - `longhorn.yml:232-253`: Fresh Longhorn install → `kubernetes.core.helm` with `state: present`

3.4. Replace `helm upgrade`:
  - `longhorn.yml:255-274`: Longhorn configuration update → `kubernetes.core.helm` with `state: present` (idempotent)

3.5. Replace `helm upgrade --install` and `helm uninstall`:
  - `longhorn.yml:276-294`: Repair broken installation → `kubernetes.core.helm` with `state: present` (handles both install and upgrade)
  - `longhorn.yml:197-211`: Failed release cleanup → `kubernetes.core.helm` with `state: absent`

3.6. Replace `helm list --pending`:
  - `longhorn.yml:113-118`: Pending Helm operations → `kubernetes.core.k8s_info` querying `helm.sh/chart` annotations in release secrets

### Phase 4: Pod and Node Readiness Checks

4.1. Replace all `kubectl wait` calls:
  - `longhorn.yml:315-325`: Longhorn manager pod readiness → `kubernetes.core.k8s_wait` or `kubernetes.core.k8s_info` with retry loop
  - `longhorn.yml:327-333`: Driver deployer readiness → same pattern
  - `longhorn.yml:623-631`: Longhorn manager/CSI pod waits → `kubernetes.core.k8s_wait`
  - `longhorn.yml:635-642`: PVC bound wait → `kubernetes.core.k8s_wait`
  - `longhorn.yml:777-788`: Volume health check → `kubernetes.core.k8s_info` with `until` retry

4.2. Replace all `kubectl get nodes`, `kubectl get pods`, `kubectl get crd` readiness loops:
  - `longhorn.yml:18-53`: API server and CRD readiness checks → `kubernetes.core.k8s_info` with `until` retry loops

4.3. Replace all `kubectl api-resources` and `kubectl get crd` calls:
  - `longhorn.yml:55-72`: CRD API checks → `kubernetes.core.k8s_info` querying `apiextensions.k8s.io` API group

### Phase 5: Cleanup and Verification

5.1. Remove all remaining `KUBECONFIG=...` prefixed `shell` calls across all files.

5.2. Consolidate repeated `kubeconfig: /etc/rancher/k3s/k3s.yaml` into role defaults or a shared variable.

5.3. Update all `debug` messages to reference module return values (`result.changed`, `result.msg`) instead of shell exit codes (`result.rc`).

5.4. Run the complete playbook against a test cluster and verify:
  - All tasks report `ok` or `changed` with no errors
  - Idempotency: running the playbook a second time reports no changes
  - Longhorn PVC creation and deletion works correctly
  - All Helm releases are tracked by the Helm module

## Validation

- Run `ansible-playbook ansible/playbooks/k3s-deploy-cluster.yml --check` against a test cluster — all `kubernetes.core` and `helm` tasks should report correctly.
- Run the playbook twice: the second run should report `changed: 0` for all infrastructure tasks (true idempotency).
- Verify that no `shell` calls with `kubectl` or `helm` remain in any task file under `ansible/roles/k3s/tasks/`.
- Verify that `longhorn.yml` still produces a fully functional Longhorn installation with correct replica counts, tolerations, storage classes, and backup targets.
