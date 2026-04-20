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

Prod intentionally remains pinned to ESO `0.10.5` until the stage rollout is accepted. Prod overlays currently patch `ExternalSecret` and `ClusterSecretStore` resources back to `external-secrets.io/v1beta1`.

To promote ESO to prod:

1. Verify stage:
   ```bash
   kubectl --context k3s-stage -n argocd get application external-secrets external-secrets-config
   kubectl --context k3s-stage get externalsecret -A
   kubectl --context k3s-stage get clustersecretstore vault-kv
   ```
2. Ensure prod CRDs serve `external-secrets.io/v1` before removing prod `v1beta1` overlays.
3. Update `argocd/apps/prod/external-secrets.yaml` to chart `2.3.0`, `installCRDs: false`, `namespaceOverride: external-secrets`, and `ServerSideApply=true`.
4. Remove the prod `apiVersion: external-secrets.io/v1beta1` kustomize patches.
5. Sync prod in this order: `external-secrets`, `external-secrets-config`, then apps with `ExternalSecret` resources.
6. Verify every prod `ExternalSecret` reports `SecretSynced`.

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

If Grafana was already rolling with the old `RollingUpdate` strategy, the old ReplicaSet can hold the PVC and block the upgraded pod with a Multi-Attach error. Patch the live deployment to the committed `Recreate` strategy, remove the old `rollingUpdate` field, and scale the old ReplicaSet down during the maintenance window:

```bash
kubectl --context k3s-prod -n monitoring patch deployment kube-prometheus-stack-grafana \
  --type=json \
  -p='[
    {"op":"replace","path":"/spec/strategy/type","value":"Recreate"},
    {"op":"remove","path":"/spec/strategy/rollingUpdate"}
  ]'

kubectl --context k3s-prod -n monitoring get rs -l app.kubernetes.io/name=grafana
kubectl --context k3s-prod -n monitoring scale rs <old-grafana-replicaset> --replicas=0
```

After the sync, verify:

```bash
kubectl --context k3s-prod -n argocd get application kube-prometheus-stack
kubectl --context k3s-prod -n monitoring get pods
kubectl --context k3s-prod -n monitoring get deployment kube-prometheus-stack-grafana \
  -o jsonpath='{.spec.strategy.type}{"\n"}'
```
