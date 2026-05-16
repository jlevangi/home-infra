# Plan 05: Refine K3s Installation Logic

## Goal

Streamline and standardize the K3s master and worker installation/reinstallation detection logic in `master.yml` and `worker.yml`. Replace the manual `uri` + `systemctl` checks with a unified, clearly-documented approach that is easier to reason about and maintain.

## Current State

### Master (`master.yml`)

The reinstall detection logic (lines 4-28):

```yaml
- name: Check if K3s is already installed and running
  shell: |
    systemctl is-active k3s && k3s --version | head -1
  register: k3s_status_check
  ignore_errors: yes
  changed_when: false

- name: Check if K3s API server is responding
  uri:
    url: "https://{{ ansible_default_ipv4.address }}:6443/version"
    method: GET
    validate_certs: no
    timeout: 10
  register: k3s_api_check
  ignore_errors: yes
  failed_when: false
  when: k3s_status_check.rc == 0

- name: Determine if reinstall is needed
  set_fact:
    k3s_needs_install: >-
      {{
        k3s_status_check.rc != 0 or
        (k3s_status_check.rc == 0 and k3s_api_check.status != 200)
      }}
```

Issues:
- `ignore_errors: yes` masks real errors — if `systemctl` fails for an unexpected reason, it's silently swallowed
- The `uri` check runs only if `systemctl` succeeds, but the logic is hard to follow
- `k3s_status_check.rc != 0` means "not running" — but `shell` returning non-zero from `systemctl is-active` is conflated with "not installed"
- No version comparison — if K3s is running but at a different version, it may not reinstall

### Worker (`worker.yml`)

The reinstall detection logic (lines 4-13):

```yaml
- name: Check if K3s agent is already installed and running
  shell: |
    systemctl is-active k3s-agent && k3s --version | head -1
  register: k3s_agent_status_check
  failed_when: false
  changed_when: false

- name: Determine if reinstall is needed
  set_fact:
    k3s_needs_install: "{{ k3s_agent_status_check.rc != 0 }}"
```

Issues:
- Simpler than master logic, but still conflates "not running" with "not installed"
- Does not check API server health
- Does not compare versions

### Shared Issues

Both files use the K3s install script (`curl -sfL https://get.k3s.io | sh -s -`) which is the recommended approach, but:
- No explicit `INSTALL_K3S_SKIP_START=true` check — the script always tries to start K3s
- The token is shared via `slurp` + `delegate_to` which is fragile
- No mechanism to force reinstall when configuration has changed

## Target State

### Unified Installation Check Task

Create a new shared task file `ansible/roles/k3s/tasks/shared/check-k3s-install.yml` that both master and worker can include:

```yaml
---
# check-k3s-install.yml
# Determines whether K3s needs to be installed, upgraded, or is already correctly configured

- name: Check if K3s service exists
  stat:
    path: /etc/systemd/system/k3s.service
  register: k3s_service_file

- name: Check if K3s service is active
  systemd:
    name: k3s
    state: started
  register: k3s_service_active
  ignore_errors: yes
  changed_when: false

- name: Check K3s version
  command: k3s --version
  register: k3s_version_check
  ignore_errors: yes
  changed_when: false
  when: k3s_service_active.failed | default(false) | bool | not true

- name: Check API server health
  uri:
    url: "https://{{ ansible_default_ipv4.address }}:6443/version"
    method: GET
    validate_certs: no
    timeout: 10
  register: k3s_api_health
  ignore_errors: yes
  changed_when: false
  when: k3s_service_active.failed | default(false) | bool | not true

- name: Determine installation action
  set_fact:
    k3s_action: >-
      {% if not k3s_service_file.stat.exists %}
      install
      {% elif not k3s_service_active.failed | default(false) | bool and k3s_api_health.status == 200 %}
      skip
      {% elif k3s_version_check.stdout is defined and k3s_version_check.stdout | default('') | regex_search(k3s_version) %}
      skip
      {% else %}
      reinstall
      {% endif %}
```

### Master (`master.yml`) — Refactored

```yaml
---
# K3s master installation tasks

- name: Check current K3s installation state
  include_tasks: shared/check-k3s-install.yml

- name: Display K3s installation decision
  debug:
    msg: "K3s action: {{ k3s_action }}"

- name: Determine first-master identity
  set_fact:
    k3s_first_master: "{{ groups[master_group][0] }}"
    k3s_is_first_master: "{{ inventory_hostname == groups[master_group][0] }}"

- name: Resolve first-master API URL
  set_fact:
    k3s_first_master_url: "https://{{ hostvars[k3s_first_master]['ansible_default_ipv4']['address'] }}:6443"

- name: Build K3s server arguments
  set_fact:
    k3s_effective_server_args: >-
      {{
        k3s_server_args + (
          ['--cluster-init'] if k3s_is_first_master
          else ['--server', k3s_first_master_url]
        ) + (
          ['--node-taint=' ~ k3s_master_workload_taint]
          if (k3s_master_workload_taint | default('') | length > 0)
          else []
        )
      }}

- name: Wait for first master API before joining
  wait_for:
    port: 6443
    host: "{{ hostvars[k3s_first_master]['ansible_default_ipv4']['address'] }}"
    timeout: 300
  when:
    - not k3s_is_first_master
    - k3s_action != 'skip'

- name: Install K3s master
  shell: |
    {% if k3s_datastore_endpoint %}
    export K3S_DATASTORE_ENDPOINT='{{ k3s_datastore_endpoint }}'
    {% endif %}
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION={{ k3s_version }} \
    K3S_TOKEN={{ k3s_token }} \
    sh -s - server {{ k3s_effective_server_args | join(' ') }}
  register: k3s_install_result
  failed_when: k3s_install_result.rc != 0
  when: k3s_action != 'skip'

# ... rest of file (token sharing, kubeconfig setup) remains the same
```

### Worker (`worker.yml`) — Refactored

```yaml
---
# K3s worker installation tasks

- name: Check current K3s installation state
  include_tasks: shared/check-k3s-install.yml

- name: Display K3s installation decision
  debug:
    msg: "K3s action: {{ k3s_action }}"

- name: Download K3s install script
  get_url:
    url: https://get.k3s.io
    dest: /tmp/k3s-install.sh
    mode: '0755'
  when: k3s_action != 'skip'

- name: Wait for master to be ready
  wait_for:
    port: 6443
    host: "{{ hostvars[groups[master_group][0]]['ansible_default_ipv4']['address'] }}"
    delay: 10
    timeout: 300
  when: k3s_action != 'skip'

- name: Install K3s worker
  shell: |
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION={{ k3s_version }} \
    K3S_URL=https://{{ hostvars[groups[master_group][0]]['ansible_default_ipv4']['address'] }}:6443 \
    K3S_TOKEN={{ hostvars[groups[master_group][0]]['k3s_node_token'] }} \
    sh -s - agent {% if k3s_agent_args %}{{ k3s_agent_args | join(' ') }}{% endif %}
  register: k3s_worker_install
  failed_when: k3s_worker_install.rc != 0
  when:
    - hostvars[groups[master_group][0]]['k3s_node_token'] is defined
    - k3s_action != 'skip'

# ... rest of file (verification) remains the same
```

## Affected Files

| File | Action |
|------|--------|
| `ansible/roles/k3s/tasks/shared/check-k3s-install.yml` | **Create** — shared installation check logic |
| `ansible/roles/k3s/tasks/master.yml` | Modify — replace inline check logic with `include_tasks` |
| `ansible/roles/k3s/tasks/worker.yml` | Modify — replace inline check logic with `include_tasks` |

## Step-by-Step Tasks

### Phase 1: Create `shared/check-k3s-install.yml`

Create the shared task file as shown in the Target State section. This file:
- Checks if the K3s systemd service file exists
- Checks if the K3s service is active
- Checks the installed K3s version
- Checks API server health
- Sets `k3s_action` to one of: `install`, `skip`, or `reinstall`

### Phase 2: Refactor `master.yml`

Replace the inline status checks (lines 4-28) with:
```yaml
- name: Check current K3s installation state
  include_tasks: shared/check-k3s-install.yml

- name: Display K3s installation decision
  debug:
    msg: "K3s action: {{ k3s_action }}"
```

Update the installation task's `when` clause to use `k3s_action != 'skip'` instead of `k3s_needs_install`.

### Phase 3: Refactor `worker.yml`

Replace the inline status checks (lines 4-13) with:
```yaml
- name: Check current K3s installation state
  include_tasks: shared/check-k3s-install.yml

- name: Display K3s installation decision
  debug:
    msg: "K3s action: {{ k3s_action }}"
```

Update the installation task's `when` clause to use `k3s_action != 'skip'` instead of `k3s_needs_install`.

### Phase 4: Remove Redundant Variables

Both files define `k3s_needs_install`. After this refactor:
- Remove `k3s_needs_install` from both files
- The `k3s_action` variable replaces it
- Update any downstream tasks that reference `k3s_needs_install`

## Validation

1. Run the playbook against a test cluster where K3s is **not installed** — verify `k3s_action` is `install` and K3s installs correctly.
2. Run the playbook again against the same cluster — verify `k3s_action` is `skip` and no reinstallation occurs.
3. Manually change the K3s version on a node (e.g., `k3s uninstall` then reinstall a different version) — verify `k3s_action` is `reinstall`.
4. Verify that the worker correctly picks up the token from the master and joins the cluster.
5. Verify that the `k3s_needs_install` variable no longer appears in any task file.
