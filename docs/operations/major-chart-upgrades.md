# Major Chart Upgrades

Use this runbook for large Helm chart jumps promoted through stage before prod. Keep prod changes narrow: upgrade one dependency family, verify it, then move to the next.

## 2026-04-20 Stage Baseline

Stage has been verified with:

- `external-secrets` chart `2.3.0`
- `kube-prometheus-stack` chart `83.6.0`
- Prometheus Operator CRDs from `kube-prometheus-stack` `83.6.0` (`operator.prometheus.io/version: 0.90.1`)
- Grafana `12.4.3`
- Prometheus `3.11.2`

Test manifests track the same chart revisions as stage. The test cluster does not need to be running for these manifests to remain aligned.

## Prod Promotion Checklist

Before applying these upgrades to prod:

1. Confirm prod Longhorn is healthy and recent backups exist for Grafana, Prometheus, and Alertmanager PVCs.
2. Confirm `root-prod`, `external-secrets`, `external-secrets-config`, and `kube-prometheus-stack` are `Synced` and `Healthy`.
3. Avoid mixing unrelated prod manifest changes into the same sync window.
4. Plan for a short Grafana interruption. The Grafana deployment must use `Recreate` with its single ReadWriteOnce PVC.

## External Secrets Operator

Prod was promoted from ESO `0.10.5` to `2.3.0` on 2026-04-21. The key production difference from a fresh stage cluster is that prod had existing objects stored as `v1beta1`, so the CRD storage version had to be migrated before ending on the `2.3.0` CRDs.

To promote ESO to prod:

1. Verify stage:
   ```bash
   kubectl --context k3s-stage -n argocd get application external-secrets external-secrets-config
   kubectl --context k3s-stage get externalsecret -A
   kubectl --context k3s-stage get clustersecretstore vault-kv
   ```
2. Apply transitional ESO CRDs that serve both `v1beta1` and `v1`, with `v1` as storage. If webhook conversion fields remain from the old CRDs, patch the affected CRDs to `conversion: None` while both versions are served.
3. Update `argocd/apps/prod/external-secrets.yaml` to chart `2.3.0`, `installCRDs: false`, `namespaceOverride: external-secrets`, and `ServerSideApply=true`.
4. Remove the prod `apiVersion: external-secrets.io/v1beta1` kustomize patches.
5. Sync prod in this order: `external-secrets`, `external-secrets-config`, then apps with `ExternalSecret` resources.
6. After the v1 objects have been reapplied, patch CRD status `storedVersions` to `["v1"]` for `externalsecrets`, `clustersecretstores`, `secretstores`, and `clusterexternalsecrets`, then apply the final sanitized ESO `2.3.0` CRDs.
7. Verify every prod `ExternalSecret` reports `SecretSynced`.

## Kube Prometheus Stack

The stage upgrade from `67.x` to `83.6.0` required a Prometheus Operator CRD pre-apply. Without the CRD update, ArgoCD failed diffing Alertmanager resources because the live CRD schema did not include new fields such as `spec.hostNetwork`.

Before changing prod's chart revision:

```bash
helm pull kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --version 83.6.0 \
  --untar \
  --untardir /tmp/kps-83.6.0

kubectl --context k3s-prod apply \
  --server-side \
  --force-conflicts \
  --field-manager=argocd-application-controller \
  -f /tmp/kps-83.6.0/kube-prometheus-stack/charts/crds/crds
```

Verify the CRD schema before syncing the app:

```bash
kubectl --context k3s-prod get crd alertmanagers.monitoring.coreos.com \
  -o yaml | rg 'operator.prometheus.io/version|hostNetwork'
```

Then update `argocd/apps/prod/kube-prometheus-stack.yaml`:

- Set `targetRevision: 83.6.0`.
- Add `grafana.deploymentStrategy.type: Recreate` and `grafana.deploymentStrategy.rollingUpdate: null`. The explicit `null` removes the old RollingUpdate field during ArgoCD server-side apply.
- Keep `ServerSideApply=true`.

Sync `kube-prometheus-stack` and watch the rollout:

```bash
kubectl --context k3s-prod -n argocd get application kube-prometheus-stack -w
kubectl --context k3s-prod -n monitoring rollout status deployment/kube-prometheus-stack-grafana --timeout=300s
kubectl --context k3s-prod -n monitoring get pods
```

If Grafana was already rolling with the old `RollingUpdate` strategy, patch the live deployment strategy before retrying the sync. Replacing the whole `strategy` object is more reliable than removing only `rollingUpdate`:

```bash
kubectl --context k3s-prod -n monitoring patch deployment kube-prometheus-stack-grafana \
  --type=json \
  -p='[{"op":"replace","path":"/spec/strategy","value":{"type":"Recreate"}}]'
```

After the sync, verify:

```bash
kubectl --context k3s-prod -n argocd get application kube-prometheus-stack
kubectl --context k3s-prod -n monitoring get pods
kubectl --context k3s-prod -n monitoring get deployment kube-prometheus-stack-grafana \
  -o jsonpath='{.spec.strategy.type}{"\n"}'
```

## Gatus

Gatus uses a single RWO PVC. Set prod Gatus to `deployment.strategy: Recreate` before chart upgrades. If an upgrade was already started with `RollingUpdate`, deleting the old Gatus pod allows the new pod to attach the PVC, but committing `Recreate` avoids repeating that manual step.

## Vault

Vault chart `0.32.0` updates the StatefulSet template to Vault `1.21.2`, but the chart uses `OnDelete`, so the pod does not restart automatically. After syncing the chart:

1. Confirm the StatefulSet template image and update revision changed.
2. Delete `vault-0` during the maintenance window.
3. Run the maintenance unseal/auth-refresh playbook:
   ```bash
   ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp ANSIBLE_REMOTE_TEMP=/tmp/ansible-tmp \
     ansible-playbook ansible/playbooks/maintenance/vault-unseal.yml \
     -e kubectl_context=k3s-prod
   ```
4. Verify Vault is unsealed, `vault-kv` is `Valid`, and all ExternalSecrets are `SecretSynced`.
