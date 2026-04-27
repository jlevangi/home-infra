# Cluster Operations

Use this runbook for normal day-2 Kubernetes operations: switching context, deploying components, validating platform health, and running the most common direct commands.

## Environment Summary

| Environment | Context | Inventory | Domain |
| --- | --- | --- | --- |
| `prod` | `k3s-prod` | `ansible/inventories/production/hosts.yml` | `levangie.dev` |
| `stage` | `k3s-stage` | `ansible/inventories/staging/hosts.yml` | `stage.levangie.dev` |
| `test` | `k3s-test` | `ansible/inventories/test/hosts.yml` | `test.levangie.dev` |

## Context Management

### Set up or refresh kubeconfig contexts

```bash
./scripts/helpers/k3s-context-manager.sh setup
```

### Switch clusters

```bash
./scripts/helpers/k3s-context-manager.sh switch prod
./scripts/helpers/k3s-context-manager.sh switch stage
./scripts/helpers/k3s-context-manager.sh switch test
```

### Inspect available contexts

```bash
./scripts/helpers/k3s-context-manager.sh list
./scripts/helpers/k3s-context-manager.sh status
```

If you use the shell helpers, source `scripts/helpers/k3s-shell-functions.sh` from your shell profile.

## Component Deployment

### Common commands

```bash
./scripts/deploy-component.sh --list
./scripts/deploy-component.sh --prod traefik
./scripts/deploy-component.sh --prod metallb
./scripts/deploy-component.sh --prod longhorn
./scripts/deploy-component.sh --prod argocd
./scripts/deploy-component.sh --prod vault
./scripts/deploy-component.sh --prod bookstack
./scripts/deploy-component.sh --prod homepage --force
```

### Current infrastructure component order

`deploy-component.sh` treats these as the infrastructure stack:

1. `longhorn`
2. `metallb`
3. `traefik`
4. `argocd`
5. `vault`

Use `all-infra` for a fresh cluster when you want to apply them in order.

## Direct Ansible Commands

Use the wrapper scripts first. Drop to Ansible directly when you need tighter control.

### Deploy one infrastructure component

```bash
ansible-playbook -i ansible/inventories/production/hosts.yml \
  ansible/playbooks/k3s-deploy-component.yml \
  -e deploy_component=traefik \
  -e target_cluster=k3s_cluster_prod \
  --vault-password-file ~/.ansible_vault_pass
```

### Deploy one app

Applications are deployed by ArgoCD, not Ansible. Edit the relevant manifest under
`argocd/apps/<env>/` or `argocd/manifests/**` and let ArgoCD reconcile from `main`.
To force a sync immediately:

```bash
kubectl -n argocd patch application <app-name> --type=merge \
  -p '{"operation":{"sync":{}}}'
```

## Health Checks

### Cluster baseline

```bash
kubectl get nodes
kubectl get pods -A
kubectl get pvc -A
kubectl -n argocd get applications
```

### Traefik

```bash
kubectl -n traefik-system get pods
kubectl -n traefik-system get svc traefik
kubectl -n traefik-system get ingressroute
```

### MetalLB

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool
kubectl -n metallb-system get l2advertisement
kubectl get svc -A | grep LoadBalancer
```

### Longhorn

```bash
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get backuptarget
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get replicas.longhorn.io
```

### ArgoCD and Vault

```bash
kubectl -n argocd get applications
kubectl -n vault get pods
kubectl -n external-secrets get pods
kubectl get clustersecretstore
```

## Common Troubleshooting

- If kubeconfig contexts look stale, rerun `./scripts/helpers/k3s-context-manager.sh setup`.
- If deployment wrappers fail early, verify `~/.ansible_vault_pass` and SSH connectivity first.
- If PVC-related issues appear after a restore, use the recovery docs before letting ArgoCD self-heal over manual changes.

## Related Docs

- [GitOps And ArgoCD](gitops-and-argocd.md)
- [Backup And Restore](../recovery/backup-and-restore.md)
- [Longhorn Troubleshooting](../recovery/longhorn-troubleshooting.md)
