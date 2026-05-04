# Vault Raft Recovery

Prod Vault is now a canonical 3-node Raft deployment managed by `root-prod`.
This runbook covers bootstrap and recovery for that steady-state layout.
The recovery playbook is Raft-aware: it can recover a primary-only seal, a
follower-only seal, or a full-cluster seal without assuming the first pod is
always the one that needs unsealing.

## Canonical Files

- [argocd/apps/prod/vault.yaml](/mnt/c/Users/pierc/git/home-infra/argocd/apps/prod/vault.yaml)
- [argocd/apps/prod/vault-storageclass.yaml](/mnt/c/Users/pierc/git/home-infra/argocd/apps/prod/vault-storageclass.yaml)
- [ansible/playbooks/maintenance/vault-bootstrap.yml](/mnt/c/Users/pierc/git/home-infra/ansible/playbooks/maintenance/vault-bootstrap.yml)
- [ansible/playbooks/maintenance/vault-unseal.yml](/mnt/c/Users/pierc/git/home-infra/ansible/playbooks/maintenance/vault-unseal.yml)
- [scripts/maintenance/migrate-vault-kv.sh](/mnt/c/Users/pierc/git/home-infra/scripts/maintenance/migrate-vault-kv.sh)

## What This Gives You

- A Raft-backed Vault cluster in namespace `vault-raft`
- 3 pods spread across nodes
- Automated init, join, unseal, and ESO auth configuration during bootstrap
- A reusable KV migration helper for future restores or cluster replacements

It does **not** solve auto-unseal by itself. With the current Shamir-only setup,
cold restarts still require unseal keys. For hands-off restart recovery you
still need an external seal provider such as KMS-backed auto-unseal.

## Bootstrap Or Rebuild

1. Sync the prod storage class and Vault applications:

```bash
kubectl --context k3s-prod -n argocd get application vault-storageclass vault
```

2. Bootstrap the in-cluster Raft deployment:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp \
ANSIBLE_REMOTE_TEMP=/tmp/ansible-tmp \
ansible-playbook ansible/playbooks/maintenance/vault-bootstrap.yml \
  -e "kubectl_context=k3s-prod"
```

3. Verify pod health and Raft peer membership:

```bash
kubectl --context k3s-prod get pods -n vault-raft
kubectl --context k3s-prod exec -n vault-raft vault-raft-0 -- \
  sh -ec 'VAULT_ADDR="http://vault-raft.vault-raft.svc:8200" vault operator raft list-peers'
```

4. If Vault restarted sealed, recover it with:

```bash
./scripts/recover-vault.sh --prod
```

Or run the playbook directly:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp \
ANSIBLE_REMOTE_TEMP=/tmp/ansible-tmp \
ansible-playbook ansible/playbooks/maintenance/vault-unseal.yml \
  -e "kubectl_context=k3s-prod"
```

That playbook now handles these cases:

- Primary sealed, followers sealed
- Primary already unsealed, one or more followers sealed
- Everything already unsealed, so only the auth refresh and ESO recovery run

## Restoring KV Data

Use the migration helper only when replacing a Vault cluster or importing data
from an older instance.

1. Dry-run the copy:

```bash
DRY_RUN=true KUBECTL_CONTEXT=k3s-prod \
  SOURCE_NAMESPACE=<old-vault-namespace> \
  DEST_NAMESPACE=vault-raft \
  ./scripts/maintenance/migrate-vault-kv.sh
```

2. Run the copy:

```bash
KUBECTL_CONTEXT=k3s-prod \
SOURCE_NAMESPACE=<old-vault-namespace> \
DEST_NAMESPACE=vault-raft \
./scripts/maintenance/migrate-vault-kv.sh
```

3. Verify the imported paths:

```bash
kubectl --context k3s-prod exec -n vault-raft vault-raft-0 -- \
  sh -ec 'VAULT_ADDR="http://vault-raft.vault-raft.svc:8200" vault kv list kv/prod'
```

## Verify ESO

```bash
kubectl --context k3s-prod get clustersecretstore vault-kv
kubectl --context k3s-prod get externalsecrets -A
```

## Notes

- The migration helper copies KV v2 data for `prod`, `stage`, `test`, and
  `talos-test` by default.
- It does not migrate auth methods, leases, tokens, or non-KV engines.
