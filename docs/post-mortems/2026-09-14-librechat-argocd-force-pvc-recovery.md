# LibreChat ArgoCD Force Sync PVC Recovery

## Summary

On 2026-09-14, an operator-triggered ArgoCD sync with `force` was used while deploying a MongoDB CPU-limit change. The LibreChat Helm release includes three PersistentVolumeClaims, so ArgoCD attempted to replace all three claims even though their specifications were unchanged. Kubernetes PVC protection held the claims in `Terminating` while their pods still mounted them.

## Impact

- LibreChat remained available while PVC protection blocked deletion.
- The recovery required a controlled stop of LibreChat, MongoDB, and Meilisearch for several minutes.
- All three Longhorn volumes remained healthy and retained their original data.
- No restore from backup was required.

## Detection and containment

ArgoCD reported a failed sync and all three claims showed a deletion timestamp. The associated PVs had `persistentVolumeReclaimPolicy: Retain`, and the Longhorn volumes remained attached and healthy.

Automated sync was temporarily disabled on `root-prod` and `librechat` to stop reconciliation. Recovery proceeded only after explicit production-data approval.

## Recovery

1. Saved the complete live PVC and PV definitions.
2. Scaled LibreChat, MongoDB, and Meilisearch to zero.
3. Waited for all pods and terminating PVCs to disappear.
4. Verified the three PVs were `Released` with `Retain` and the expected CSI volume handles.
5. Removed the stale `claimRef` from each exact PV.
6. Recreated each PVC with its original name, size, storage class, and explicit `volumeName`.
7. Verified all claims rebound to their original PV and Longhorn volume.
8. Started MongoDB and Meilisearch, then LibreChat.
9. Re-enabled automated reconciliation and performed a normal sync with `RespectIgnoreDifferences=true`.

Final state: both ArgoCD applications were `Synced / Healthy`, all pods were ready, all three Longhorn volumes were `attached / healthy`, and `https://librechat.levangie.dev` returned HTTP 200.

## Root cause

ArgoCD force sync uses replacement semantics. Replacement is unsafe for applications that render PVCs because it may delete and recreate immutable storage objects even when the intended change affects only a Deployment.

## Preventive action

- Never use ArgoCD `force` sync for an application that owns PVCs.
- Use normal sync with the application's declared sync options.
- Before syncing stateful applications, inspect rendered resources for PVCs and confirm existing `ignoreDifferences` rules cover accepted static bindings.
- If a PVC enters `Terminating`, stop reconciliation and preserve attached workloads until the PV reclaim policy and Longhorn volume state are verified.

Related policy: `argocd/apps/prod/librechat.yaml` uses `RespectIgnoreDifferences=true` and ignores restored PVC `spec.volumeName` bindings.
