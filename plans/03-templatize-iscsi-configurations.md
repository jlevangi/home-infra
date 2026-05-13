# Plan 03: Templatize iSCSI Configurations

## Goal

Replace the fragmented `lineinfile` calls in `main.yml` with a Jinja2 template for `/etc/iscsi/iscsid.conf`. This consolidates the iSCSI configuration into a single, maintainable file and makes it easier to audit and modify.

## Current State

In `main.yml` (lines 46-74), iSCSI tuning is implemented as three separate `lineinfile` tasks:

```yaml
- name: Tune iSCSI noop_out_interval for Longhorn
  ansible.builtin.lineinfile:
    path: /etc/iscsi/iscsid.conf
    regexp: '^\s*node\.conn\[0\]\.timeo\.noop_out_interval\s*='
    line: "node.conn[0].timeo.noop_out_interval = {{ k3s_iscsi_noop_out_interval }}"
    state: present
  become: yes
  when: k3s_install_longhorn | default(true)
  notify: restart iscsid

- name: Tune iSCSI noop_out_timeout for Longhorn
  ansible.builtin.lineinfile:
    path: /etc/iscsi/iscsid.conf
    regexp: '^\s*node\.conn\[0\]\.timeo\.noop_out_timeout\s*='
    line: "node.conn[0].timeo.noop_out_timeout = {{ k3s_iscsi_noop_out_timeout }}"
    state: present
  become: yes
  when: k3s_install_longhorn | default(true)
  notify: restart iscsid

- name: Tune iSCSI session replacement_timeout for Longhorn
  ansible.builtin.lineinfile:
    path: /etc/iscsi/iscsid.conf
    regexp: '^\s*node\.session\.timeo\.replacement_timeout\s*='
    line: "node.session.timeo.replacement_timeout = {{ k3s_iscsi_replacement_timeout }}"
    state: present
  become: yes
  when: k3s_install_longhorn | default(true)
  notify: restart iscsid
```

Issues with this approach:
- Three separate file writes to the same file
- `lineinfile` is not ideal for multi-line config files — it operates line-by-line
- If the file format changes, each `regexp` must be updated independently
- No single view of the complete iSCSI configuration

## Target State

A single Jinja2 template file (`templates/iscsid.conf.j2`) that writes the entire iSCSI configuration block:

```ini
# Managed by Ansible — do not edit manually
# iSCSI settings optimized for Longhorn storage

node.conn[0].timeo.noop_out_interval = {{ k3s_iscsi_noop_out_interval }}
node.conn[0].timeo.noop_out_timeout = {{ k3s_iscsi_noop_out_timeout }}
node.session.timeo.replacement_timeout = {{ k3s_iscsi_replacement_timeout }}
```

Replaced by a single task in `main.yml`:

```yaml
- name: Configure iSCSI settings for Longhorn
  ansible.builtin.template:
    src: iscsid.conf.j2
    dest: /etc/iscsi/iscsid.conf.d/longhorn.conf   # or append to iscsid.conf
    owner: root
    group: root
    mode: '0644'
  become: yes
  when: k3s_install_longhorn | default(true)
  notify: restart iscsid
```

## Affected Files

| File | Action |
|------|--------|
| `ansible/roles/k3s/tasks/main.yml` | Modify — remove 3 `lineinfile` tasks |
| `ansible/roles/k3s/templates/iscsid.conf.j2` | **Create** — new template |
| `ansible/roles/k3s/defaults/main.yml` | Verify — confirm `k3s_iscsi_*` variables exist |

## Step-by-Step Tasks

### Phase 1: Create the Template

Create `ansible/roles/k3s/templates/iscsid.conf.j2`:

```jinja2
# Managed by Ansible — do not edit manually
# iSCSI settings optimized for Longhorn storage

node.conn[0].timeo.noop_out_interval = {{ k3s_iscsi_noop_out_interval }}
node.conn[0].timeo.noop_out_timeout = {{ k3s_iscsi_noop_out_timeout }}
node.session.timeo.replacement_timeout = {{ k3s_iscsi_replacement_timeout }}
```

### Phase 2: Update `main.yml`

Remove the three `lineinfile` tasks (lines 46-74 of `main.yml`) and replace with the single `template` task shown in the Target State section above.

**Decision point** — file destination strategy:

Option A (recommended): Write to `/etc/iscsi/iscsid.conf.d/longhorn.conf`
- Uses the `iscsid.conf` drop-in directory (supported by open-iscsi on most modern distributions)
- Does not overwrite the system-managed default config
- Idempotent and clean

Option B: Append to `/etc/iscsi/iscsid.conf` via `template`
- Overwrites the entire file, which may conflict with system-managed content
- Less safe on systems where the OS manages `iscsid.conf`

### Phase 3: Verify Default Variables

Ensure the following variables exist in `ansible/roles/k3s/defaults/main.yml` (or in environment-specific group_vars):

```yaml
k3s_iscsi_noop_out_interval: 60
k3s_iscsi_noop_out_timeout: 120
k3s_iscsi_replacement_timeout: 600
```

### Phase 4: Verify the `restart iscsid` Handler

Confirm that the handler `restart iscsid` exists in `ansible/roles/k3s/handlers/main.yml`:

```yaml
- name: restart iscsid
  ansible.builtin.systemd:
    name: iscsid
    state: restarted
  become: yes
```

If the handler does not exist, create it.

## Validation

1. Run the playbook against a test cluster and verify `/etc/iscsi/iscsid.conf.d/longhorn.conf` is created with the correct values.
2. Verify that `iscsid` is restarted after the template is applied (handler fires).
3. Run the playbook a second time — the file should be unchanged (idempotent).
4. Verify that iSCSI connections to Longhorn volumes still function correctly after the config change.
5. Run `diff` between the old `lineinfile`-generated config and the new template-generated config to confirm functional equivalence.
