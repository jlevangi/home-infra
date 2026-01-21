## Production Cutover Checklist (Stage -> Prod)

### Goals
- Promote the staged Vault + External Secrets + ArgoCD app migrations to prod.
- Protect existing application data (PVCs, DBs, files).
- Avoid deploying any new apps to prod during this cutover.

### Safety Notes (Data Protection)
- This cutover does not recreate PVCs or wipe namespaces.
- Do not delete namespaces in prod.
- Verify existing PVCs are bound before syncing apps.
- Avoid `helm uninstall` or `kubectl delete` on app namespaces.

### Pre-Cutover (Stage Validation)
- Confirm all stage apps are Healthy in ArgoCD:
  - `root-stage`, `vault`, `external-secrets`, `external-secrets-config`
  - `homepage`, `plex`, `pocketid`, `bookstack`, `vaultwarden`
- Confirm Vault is unsealed and `ClusterSecretStore` is Valid.
- Confirm ExternalSecrets are in `Ready=True` state.
- Confirm stage ingress hostnames use `*.stage.levangie.dev` only.

### Git Merge (Stage -> Main)
- Merge `stage` into `main` and push.
  ```bash
  git checkout main
  git merge stage
  git push origin main
  ```

### Prod Deploy (No New Apps)
1. Verify ArgoCD target revision for prod is `main`.
2. Sync only the existing prod apps:
   - `root-prod`, `vault`, `external-secrets`, `external-secrets-config`
   - `homepage`, `plex`, `pocketid`
3. Do not add any new prod app manifests during this cutover.
  ```bash
  kubectl --context k3s-prod -n argocd get applications
  # Sync in ArgoCD UI or CLI for the listed prod apps only
  ```

### Prod Vault + ESO Bootstrap
- Run the Vault bootstrap once after Vault is running:
  ```bash
  ANSIBLE_CONFIG=/tmp/ansible.cfg ansible-playbook \
    -i ansible/inventories/production/hosts.yml \
    ansible/playbooks/k3s-deploy-cluster.yml \
    -e target_cluster=k3s_cluster_prod \
    --tags vault \
    --vault-password-file ~/.ansible_vault_pass
  ```
- Verify:
  ```bash
  kubectl --context k3s-prod get clustersecretstore
  kubectl --context k3s-prod -n external-secrets get pods
  kubectl --context k3s-prod -n bookstack get externalsecret
  kubectl --context k3s-prod -n vaultwarden get externalsecret
  kubectl --context k3s-prod -n pocketid get externalsecret
  ```

### Post-Cutover Checks (Prod)
- Ensure existing PVCs are still bound:
  ```bash
  kubectl --context k3s-prod -n bookstack get pvc
  kubectl --context k3s-prod -n vaultwarden get pvc
  kubectl --context k3s-prod -n plex get pvc
  kubectl --context k3s-prod -n pocketid get pvc
  ```
- Confirm pods are running and have not restarted excessively.
- Validate ingress hostnames use `*.levangie.dev` (no test/stage domains).

### Rollback Plan
- If Argo sync causes regressions, reset `main` to previous commit and re-sync.
- If ESO/Vault breaks secrets, scale ESO down, fix Vault, then re-enable ESO.
