# Vault Raft Migration

Use this runbook to migrate production Vault from the current single-node
filesystem backend to a separate 3-node Raft cluster without cutting ArgoCD or
External Secrets over until the new cluster is proven.

This runbook deliberately uses assets outside `argocd/apps/prod`, so nothing in
here is auto-synced by `root-prod`.

## What This Gives You

- A temporary `vault-raft` cluster in namespace `vault-raft`
- 3 Vault pods spread across nodes
- Raft peer join and unseal automation
- A repeatable KV copy step before cutover

It does **not** solve auto-unseal by itself. With the current Shamir-only setup,
all nodes can rejoin the Raft cluster, but cold restarts still require unseal
keys. For true hands-off restart recovery you still need an external seal
provider.

## Files Added For This Migration

- [argocd/manual/vault-raft-prod.yaml](/mnt/c/Users/pierc/git/home-infra/argocd/manual/vault-raft-prod.yaml)
- [ansible/playbooks/maintenance/vault-bootstrap.yml](/mnt/c/Users/pierc/git/home-infra/ansible/playbooks/maintenance/vault-bootstrap.yml)
- [scripts/maintenance/migrate-vault-kv.sh](/mnt/c/Users/pierc/git/home-infra/scripts/maintenance/migrate-vault-kv.sh)

## Safe Sequence

1. Keep the existing `vault` application running. Do not change the live prod
   Vault chart from `file` to `raft` in place.
2. Create the temporary ArgoCD app:

```bash
kubectl --context k3s-prod apply -f argocd/manual/vault-raft-prod.yaml -n argocd
```

3. Wait for `vault-raft` pods to exist, then bootstrap the new cluster:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp \
ANSIBLE_REMOTE_TEMP=/tmp/ansible-tmp \
ansible-playbook ansible/playbooks/maintenance/vault-bootstrap.yml \
  -e "kubectl_context=k3s-prod \
      vault_namespace=vault-raft \
      vault_statefulset_name=vault-raft \
      vault_internal_service_name=vault-raft-internal \
      vault_service_name=vault-raft \
      vault_ha_enabled=true \
      vault_raft_enabled=true \
      vault_replica_count=3"
```

4. Verify the new Raft cluster:

```bash
kubectl --context k3s-prod get pods -n vault-raft
kubectl --context k3s-prod exec -n vault-raft vault-raft-0 -- \
  sh -ec 'VAULT_ADDR="http://vault-raft.vault-raft.svc:8200" vault operator raft list-peers'
```

5. Dry-run the KV copy:

```bash
DRY_RUN=true KUBECTL_CONTEXT=k3s-prod ./scripts/maintenance/migrate-vault-kv.sh
```

6. Copy the KV data:

```bash
KUBECTL_CONTEXT=k3s-prod ./scripts/maintenance/migrate-vault-kv.sh
```

7. Validate the new cluster has the expected data:

```bash
kubectl --context k3s-prod exec -n vault-raft vault-raft-0 -- \
  sh -ec 'VAULT_ADDR="http://vault-raft.vault-raft.svc:8200" vault kv list kv/prod'
```

8. Cut External Secrets over only after KV validation:

```bash
kubectl --context k3s-prod patch clustersecretstore vault-kv --type=merge -p \
  '{"spec":{"provider":{"vault":{"server":"http://vault-raft.vault-raft.svc:8200"}}}}'

kubectl --context k3s-prod rollout restart deployment -n external-secrets external-secrets
kubectl --context k3s-prod rollout restart deployment -n external-secrets external-secrets-webhook
kubectl --context k3s-prod rollout restart deployment -n external-secrets external-secrets-cert-controller
```

9. Verify ESO recovery:

```bash
kubectl --context k3s-prod get clustersecretstore vault-kv
kubectl --context k3s-prod get externalsecrets -A
```

10. Only after the new cluster is serving cleanly should you retire the old
    standalone Vault and replace the prod `vault` app with the Raft-backed
    manifest.

## Rollback

If the new cluster does not validate cleanly, reverse the cutover immediately:

```bash
kubectl --context k3s-prod patch clustersecretstore vault-kv --type=merge -p \
  '{"spec":{"provider":{"vault":{"server":"http://vault.vault.svc:8200"}}}}'

kubectl --context k3s-prod rollout restart deployment -n external-secrets external-secrets
kubectl --context k3s-prod rollout restart deployment -n external-secrets external-secrets-webhook
kubectl --context k3s-prod rollout restart deployment -n external-secrets external-secrets-cert-controller
```

Then delete the temporary app:

```bash
kubectl --context k3s-prod delete -f argocd/manual/vault-raft-prod.yaml -n argocd
```

## Notes

- The migration helper copies the latest KV v2 data for `prod`, `stage`, `test`,
  and `talos-test` by default.
- It does not migrate auth methods, leases, tokens, or non-KV engines.
- The new bootstrap playbook recreates the ESO policy and Kubernetes auth role
  in the temporary cluster before cutover.
