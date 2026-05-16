# Plan 04: Modernize `prepare.yml`

## Goal

Replace procedural `shell` and `get_url` + `shell` patterns in `prepare.yml` with native Ansible modules. This improves idempotency, readability, and aligns the file with Ansible best practices.

## Current State

`prepare.yml` contains several patterns that can be improved:

### 1. Swap Disabling via Shell (line 67-71)
```yaml
- name: Disable swap
  shell: |
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
  become: yes
```

Issues:
- `shell` is not idempotent for fstab modification — the `sed` command runs every time
- No structured check for whether swap is actually enabled

### 2. Helm Installation via `get_url` + `shell` (lines 94-112)
```yaml
- name: Download Helm install script
  get_url:
    url: https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    dest: /tmp/get_helm.sh
    mode: '0755'
  when: k3s_install_helm

- name: Install Helm
  shell: /tmp/get_helm.sh
  become: yes
  when: k3s_install_helm

- name: Remove Helm install script
  file:
    path: /tmp/get_helm.sh
    state: absent
  become: yes
  when: k3s_install_helm
```

Issues:
- Downloads a script from the internet and executes it — risky and untracked
- No version pinning for the Helm installation script
- The `get_helm.sh` script may install a different Helm version than expected

### 3. Bash Completion via `shell` (lines 114-130)
```yaml
- name: Setup kubectl completion
  shell: kubectl completion bash > /etc/bash_completion.d/kubectl
  become: yes
  when: k3s_install_bash_completion

- name: Setup helm completion
  shell: helm completion bash > /etc/bash_completion.d/helm
  become: yes
  when: k3s_install_bash_completion and k3s_install_helm
```

Issues:
- Redirection is a shell feature — the `copy` or `template` module should be used instead
- No idempotency guard — the file is overwritten every run

### 4. Package Cache Update (lines 8-12)
```yaml
- name: Update package cache
  apt:
    update_cache: yes
    cache_valid_time: 3600
  become: yes
```

This is actually fine — no changes needed.

### 5. Kernel Module Loading via `loop` (lines 42-55)
```yaml
- name: Load required kernel modules
  modprobe:
    name: "{{ item }}"
    state: present
  loop: "{{ k3s_kernel_modules }}"
  become: yes

- name: Ensure kernel modules load at boot
  lineinfile:
    path: /etc/modules-load.d/k3s.conf
    line: "{{ item }}"
    create: yes
  loop: "{{ k3s_kernel_modules }}"
  become: yes
```

This is reasonable but could use `ansible.builtin.include_tasks` with `loop_control` for clarity, or use the `community.general.sysctl` module's `sysctl_file` parameter alongside a dedicated modules-load configuration. No critical issues here.

## Target State

### 1. Swap Disabling

Replace with a structured approach using `shell` only where unavoidable, but with proper idempotency guards:

```yaml
- name: Check if swap is enabled
  command: swapon --show
  register: swap_status
  changed_when: false
  failed_when: false
  become: yes

- name: Disable swap
  command: swapoff -a
  become: yes
  when: swap_status.stdout | length > 0

- name: Remove swap entries from /etc/fstab
  ansible.builtin.lineinfile:
    path: /etc/fstab
    regexp: '^\s*.*\s+swap\s+'
    state: absent
    backup: yes
  become: yes
```

This uses `lineinfile` with a regex to match swap lines instead of the fragile `sed` pattern.

### 2. Helm Installation

Replace with a direct binary download, which is more transparent and version-pinned:

```yaml
- name: Download Helm binary
  ansible.builtin.get_url:
    url: "https://get.helm.sh/helm-v{{ helm_version }}-linux-amd64.tar.gz"
    dest: "/tmp/helm-tarball-{{ helm_version }}.tar.gz"
    mode: '0644'
  when: k3s_install_helm
  register: helm_download

- name: Extract Helm binary
  ansible.builtin.unarchive:
    src: "/tmp/helm-tarball-{{ helm_version }}.tar.gz"
    dest: /tmp
    remote_src: yes
    src_new_options: '--strip-components=1 -L'
    dest_new_options: ''
  when: k3s_install_helm
  register: helm_extract

- name: Install Helm binary
  ansible.builtin.copy:
    src: /tmp/linux-amd64/helm
    dest: /usr/local/bin/helm
    mode: '0755'
  when: helm_extract.changed
  become: yes

- name: Clean up Helm tarball
  ansible.builtin.file:
    path: "/tmp/helm-tarball-{{ helm_version }}.tar.gz"
    state: absent
  become: yes

- name: Clean up Helm extraction directory
  ansible.builtin.file:
    path: /tmp/linux-amd64
    state: absent
  become: yes
```

### 3. Bash Completion

Replace `shell` redirection with `copy` or `template`:

```yaml
- name: Generate and install kubectl bash completion
  shell: kubectl completion bash
  register: kubectl_completion
  become: yes
  when: k3s_install_bash_completion

- name: Install kubectl bash completion file
  ansible.builtin.copy:
    content: "{{ kubectl_completion.stdout }}"
    dest: /etc/bash_completion.d/kubectl
    mode: '0644'
    owner: root
    group: root
  become: yes
  when: k3s_install_bash_completion

- name: Generate and install helm bash completion
  shell: helm completion bash
  register: helm_completion
  become: yes
  when: k3s_install_bash_completion and k3s_install_helm

- name: Install helm bash completion file
  ansible.builtin.copy:
    content: "{{ helm_completion.stdout }}"
    dest: /etc/bash_completion.d/helm
    mode: '0644'
    owner: root
    group: root
  become: yes
  when: k3s_install_bash_completion and k3s_install_helm
```

Or, as a single template:

```jinja2
# Managed by Ansible — bash completions for kubernetes tools
{{ kubectl_completion_content | default('') }}
{{ helm_completion_content | default('') }}
```

### 4. Add `helm_version` Default Variable

Ensure the following variable is defined in `ansible/roles/k3s/defaults/main.yml`:

```yaml
helm_version: "3.14.0"   # Pin to a known-good Helm 3 version
```

## Affected Files

| File | Action |
|------|--------|
| `ansible/roles/k3s/tasks/prepare.yml` | Modify — replace swap, helm, and completion tasks |
| `ansible/roles/k3s/defaults/main.yml` | Verify — add `helm_version` if not present |

## Step-by-Step Tasks

### Phase 1: Replace Swap Logic

Replace the `shell` swap task (lines 67-71 of `prepare.yml`) with the structured approach shown in Target State section 1.

### Phase 2: Replace Helm Installation

Replace the `get_url` + `shell` + `file` sequence (lines 94-112) with the direct binary download approach shown in Target State section 2.

### Phase 3: Replace Bash Completion

Replace the `shell` completion tasks (lines 114-130) with the `shell` + `copy` pattern shown in Target State section 3.

### Phase 4: Verify `helm_version` Variable

Ensure `helm_version` is defined in `ansible/roles/k3s/defaults/main.yml`. If it does not exist, add it with a reasonable default (e.g., `3.14.0`).

### Phase 5: Clean Up Display Debug

Review the final `debug` task at the end of `prepare.yml` (lines 132-138) to ensure it accurately reflects the updated operations. Consider removing the `systemd-resolved` check since it registers but does not drive any logic (it's a no-op observation).

## Validation

1. Run the playbook against a test cluster and verify:
   - Swap is disabled and removed from fstab
   - Helm binary is installed at `/usr/local/bin/helm` with the pinned version
   - Bash completion files exist at `/etc/bash_completion.d/kubectl` and `/etc/bash_completion.d/helm`
2. Run the playbook a second time:
   - Swap tasks should report `ok` (no change)
   - Helm binary should report `ok` (no change)
   - Completion files should report `ok` (no change)
3. Verify that `kubectl --help` and `helm --help` work correctly after deployment.
