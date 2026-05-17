# GitOps And ArgoCD

This repository uses a path-based GitOps model. Environment separation comes
from directory paths under `argocd/apps/`, and the tracked Git revision can
vary by cluster.

## Current Model

| Environment | Root App | Path | Branch |
| --- | --- | --- | --- |
| `prod` | `root-prod` | `argocd/apps/prod` | `main` |
| `stage` | `root-stage` | `argocd/apps/stage` | `stage` |
| `test` | `root-test` | `argocd/apps/test` | `main` |

## Source-Of-Truth Rules

- Put environment-specific app enablement in `argocd/apps/<env>`.
- Put shared Kubernetes manifests in `argocd/manifests/**`.
- Keep `main` as the authoritative branch for prod and test.
- Use the `stage` branch as the isolated GitOps branch for the stage cluster.

## Day-To-Day Changes

### Add or remove an app in one environment

1. Update the corresponding file set under `argocd/apps/<env>`.
2. Commit to `stage`.
3. Sync only the affected environment root app or child apps.

### Change an app shared across environments

1. Update `argocd/manifests/<app>/base` or its overlays.
2. Commit to `stage` for stage-only validation, or `main` when promoting the
   shared change to prod and test.
3. Sync the specific environment applications that should receive the change.

## Current ArgoCD Guardrails

- Avoid mixing unrelated prod changes into the same cutover window.
- For stateful restores, disable auto-sync before deleting or recreating PVCs.
- If a restore introduces a bound `volumeName`, update the desired overlay when needed so ArgoCD stops reporting immutable PVC drift.

## Inspect ArgoCD State

```bash
kubectl --context k3s-prod -n argocd get applications
kubectl --context k3s-prod get application root-prod -n argocd \
  -o jsonpath='{.spec.source.targetRevision}{" "}{.spec.source.path}{"\n"}'
```

Expected output for prod is `main argocd/apps/prod`.

## Temporarily Disable Auto-Sync For Manual Restore Work

```bash
kubectl --context k3s-prod patch application root-prod -n argocd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

kubectl --context k3s-prod patch application <app-name> -n argocd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

Re-enable it after the manual work completes:

```bash
kubectl --context k3s-prod patch application <app-name> -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

## Related Docs

- [Cluster Operations](cluster-operations.md)
- [Major Chart Upgrades](major-chart-upgrades.md)
- [Backup And Restore](../recovery/backup-and-restore.md)
- [Production Cutover Checklist](../recovery/production-cutover-checklist.md)
