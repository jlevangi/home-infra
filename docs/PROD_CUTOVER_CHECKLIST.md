## Production Cutover Checklist (Stage -> Prod)

### Goals
- Promote stage-validated changes into the prod app set tracked by ArgoCD.
- Protect existing application data (PVCs, DBs, files).
- Keep Git source-of-truth on `main`.

### Safety Notes
- This cutover does not recreate namespaces unless explicitly planned.
- Do not delete prod namespaces during a normal cutover.
- Verify existing PVCs are bound before syncing apps.
- For stateful restores, disable ArgoCD auto-sync before deleting or recreating PVCs.

### Current GitOps Model
- All clusters track the `main` branch.
- Environment separation is path-based:
  - prod: `argocd/apps/prod`
  - stage: `argocd/apps/stage`
  - test: `argocd/apps/test`
- Do not use `stage` or `test` as promotion branches.
- If those branches are retained, keep them fast-forwarded to `main`.

### Pre-Cutover (Stage Validation)
- Confirm all intended stage apps are `Healthy` in ArgoCD.
- Confirm stage ingress hostnames use `*.stage.levangie.dev` only.
- Confirm the stage data you intend to promote has already been validated by application testing.
- Confirm the shared Longhorn backup target is available on both source and target clusters.

### Verify ArgoCD Source
```bash
kubectl --context k3s-prod get application root-prod -n argocd \
  -o jsonpath='{.spec.source.targetRevision}{" "}{.spec.source.path}{"\n"}'

kubectl --context k3s-stage get application root-stage -n argocd \
  -o jsonpath='{.spec.source.targetRevision}{" "}{.spec.source.path}{"\n"}'
```

Expected output:
- prod: `main argocd/apps/prod`
- stage: `main argocd/apps/stage`

### Prod Deploy
1. Commit and push the prod-ready manifests to `main`.
2. Sync only the intended prod apps:
   - `root-prod`
   - the specific child apps involved in the cutover
3. Avoid unrelated prod changes during the same sync window.

```bash
kubectl --context k3s-prod -n argocd get applications
```

### Stateful Longhorn Restore
- Remove auto-sync before touching PVCs:
  ```bash
  kubectl --context k3s-prod patch application root-prod -n argocd --type=json \
    -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
  kubectl --context k3s-prod patch application <app-name> -n argocd --type=json \
    -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
  ```
- Scale down the target deployment and confirm pods are gone.
- Delete the target PVC only if you are replacing it with a restored Longhorn volume.
- Restore the Longhorn volume from the shared backup target using `fromBackup`.
- Create a PV and PVC bound with `volumeName`.
- If ArgoCD reports immutable PVC drift, patch the prod overlay so the desired PVC includes the restored `volumeName`.
- Scale the workload back up, restore automated sync, then hard-refresh the affected `Application` objects.

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
  ```

### Post-Cutover Checks
- Ensure expected PVCs are bound.
- Confirm affected apps are `Synced Healthy` in ArgoCD.
- Confirm pods are running and have not restarted excessively.
- Validate ingress hostnames use `*.levangie.dev` only.
- Validate external endpoints directly:
  ```bash
  curl -kI https://ittools.levangie.dev
  curl -kI https://linkding.levangie.dev
  curl -kI https://ntfy.levangie.dev
  curl -kI https://pairdrop.levangie.dev
  curl -kI https://wallos.levangie.dev
  ```

### Rollback Plan
- If an app sync causes regressions, revert the relevant commit on `main` and re-sync only the affected prod apps.
- If a restored PVC was wrong, scale the app down again, remove the manual PV/PVC binding, and recreate the restore from the correct Longhorn backup URL.
- If ESO or Vault breaks secrets, scale ESO down, fix Vault, then re-enable ESO.
