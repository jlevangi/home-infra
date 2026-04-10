# LXC Operations

Use this runbook for the Ansible-managed Proxmox LXC side of the repository.

## Source Of Truth

- Container definitions: `ansible/lxc_definitions/containers/`
- Template definitions: `ansible/lxc_definitions/templates/`
- Inventory: `ansible/inventories/lxc/hosts.yml`
- Playbook: `ansible/playbooks/lxc-deploy.yml`
- Shared vars: `ansible/group_vars/lxc.yml`

## Common Commands

### List available container definitions

```bash
./scripts/deploy-lxc.sh --list
```

### Deploy a container

```bash
./scripts/deploy-lxc.sh nbn-srv
./scripts/deploy-lxc.sh nbn-srv -v
```

### Prepare only the base template

```bash
./scripts/deploy-lxc.sh --template-only
```

### Skip template preparation

```bash
./scripts/deploy-lxc.sh nbn-srv --skip-template
```

## Adding A New Container

1. Create a YAML definition in `ansible/lxc_definitions/containers/`.
2. Set the container ID, resources, network, features, and application flags.
3. Run `./scripts/deploy-lxc.sh <container-name>`.

Example structure:

```yaml
container_name: nbn-srv
container_id: 200
description: "Hugo website hosting via Docker"
node: pve1
template: ubuntu-24.04

resources:
  cores: 2
  memory: 2048
  disk_size: 16

network:
  bridge: vmbr0
  dhcp: true

features:
  unprivileged: true
  nesting: true

applications:
  docker_installed: true
```

## Required Secrets And Access

LXC automation depends on values in `ansible/group_vars/lxc_vault.yml`, including:

- Proxmox API host and token credentials
- SSH public key used for container access

The script also expects `~/.ansible_vault_pass`.

## Troubleshooting

- If the base image is missing, run `./scripts/deploy-lxc.sh --template-only`.
- If deployment fails before the playbook runs, verify the vault password file first.
- If the container comes up but is unreachable, check the Proxmox console for the DHCP-assigned IP or the configured static address.

## Related Docs

- [Repository Overview](../getting-started/repository-overview.md)
- [Deployment Workflow](../getting-started/deployment-workflow.md)
