# Repository Guidelines

## Project Structure & Module Organization
- `terraform/` provisions Proxmox VMs and cluster networking (prod + test modules).
- `ansible/` configures nodes and deploys K3s, storage, and apps (inventories + playbooks).
- `argocd/` contains GitOps manifests and environment overlays.
- `scripts/` provides deployment and ops helpers (cluster setup, kubeconfig, restores).
- `docs/` holds operational guides (cluster management, Longhorn migration).
- `packer/` builds VM templates; `ssh-config-*` contains host config examples.

## Build, Test, and Development Commands
- `terraform -chdir=terraform/k3_3node_cluster_prod init|plan|apply` provisions production VMs.
- `terraform -chdir=terraform/k3_3node_cluster_test init|plan|apply` provisions test VMs.
- `scripts/deploy_k3s_cluster.sh` runs the main Ansible playbook for cluster bootstrap.
- `scripts/setup-local-kubeconfig.sh` fetches kubeconfig and validates access.
- `scripts/deploy_k3s_apps.sh` deploys app workloads after cluster setup.
- `scripts/k3s-context-manager.sh setup` installs multi-cluster kubeconfig contexts.
- When running Ansible here, use `ANSIBLE_CONFIG=/tmp/ansible.cfg` and `--vault-password-file ~/.ansible_vault_pass`.

## Coding Style & Naming Conventions
- Use 2-space indentation for YAML and keep Ansible variables in `snake_case`.
- Terraform follows standard HCL style; run `terraform fmt` after edits.
- Shell scripts in `scripts/` are Bash; keep names `kebab-case.sh`.
- Inventory groups follow `k3s_*` naming (e.g., `k3s_cluster_test`).

## Testing Guidelines
- No automated unit test suite is defined.
- Use `terraform plan` for safety checks before `apply`.
- Use Ansible dry-run for validation: `ansible-playbook ... --check --diff`.
- Test-cluster playbooks live under `ansible/playbooks/testing/`.

## Commit & Pull Request Guidelines
- Commit messages follow Conventional Commits with optional scope, e.g.:
  `feat(argocd): ...`, `fix(vaultwarden): ...`, `chore: ...`.
- PRs should include: target environment (prod/test), Terraform plan output if relevant,
  playbooks/scripts run, and rollback notes if changes touch data or networking.

## Security & Configuration Tips
- Keep secrets in `ansible/group_vars/*_vault.yml` and use `ansible-vault`.
- Avoid committing credentials; update `REQUIRED_VAULT_CREDENTIALS.md` when adding secrets.
