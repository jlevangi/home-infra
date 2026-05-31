# Cross-Pool Migration Complete

**Date:** 2026-05-30
**Beads issues:** home-infra-22f (epic), home-infra-pwo, home-infra-rd0, home-infra-yov, home-infra-btv, home-infra-n4r (all closed)
**Status:** Cross-pool replica placement is the cluster's steady state. 25 of 27 originally-misplaced volumes migrated; only `memos-data-v3` remains misplaced (permanent skip).

---

## What's Now Live on Prod

- **Default `longhorn` StorageClass:** `numberOfReplicas: 3`, `replicaDiskSoftAntiAffinity: enabled`, no `diskSelector`. New PVCs land 2-tank + 1-flash automatically. See [`home-infra-pwo` spike](2026-05-30-cross-pool-replica-anti-affinity-spike.md) for the empirical validation.
- **StorageClass ownership:** `longhorn`, `longhorn-flash`, `longhorn-tank` all moved to ArgoCD under `argocd/manifests/longhorn-storage-classes/`. The Longhorn helm chart's `persistence.defaultClass` is set to `false` (in `ansible/roles/cluster_platform/templates/longhorn-values.yaml.j2`) so the chart-managed `longhorn-storageclass` ConfigMap no longer fights ArgoCD.
- **Existing volumes:** 25 of the 27 audit-flagged misplaced volumes migrated to either 2-tank + 1-flash (originally all-tank) or 2-flash + 1-tank (originally all-flash). Of these, 11 large-or-redundant ones spread across worker-gpu-1's tank disk as well.

## Audit Cadence

```bash
scripts/maintenance/verify-cross-pool-placement.sh
```

Should exit 0 in steady state. The one expected exception is `memos-data-v3` (worker-2 pinned, both replicas on same disk per the [Memos workaround memory](#)). Anything else flagged is a regression.

Run after Longhorn maintenance, after any large volume restore, and at least monthly.

## Methodology Lessons from Migration

These are the things the next operator needs to know if they ever do this kind of migration again.

### 1. Soft anti-affinity is a tiebreaker, not a guarantee

The cluster-level `replica-disk-soft-anti-affinity = true` setting and per-volume `spec.replicaDiskSoftAntiAffinity = enabled` are real, but they only weight the scheduler's choice — they don't override decisions driven by disk free-space, node load, or existing replica counts. On existing N=2 volumes where both replicas were tank, simply bumping to N=3 with anti-affinity enabled still placed the 3rd replica on tank in our testing. The reliable way to force cross-pool placement during migration is the `--force-flash` / `--force-tank` mechanism in `scripts/maintenance/migrate-volumes-to-cross-pool.sh`, which temporarily disables scheduling on the over-represented pool.

### 2. Cluster-wide pool-disable has a cascade window

`set_pool_scheduling tank false` disables every tank disk on every node. Any other volume that needs to rebuild a replica during that window will fail and retry, sometimes landing on the wrong pool. Observed on `pvc-d26ca227` (jellyfin-config-rdn) twice during this session — its 60 GB rebuild kept timing out during shorter migration windows for other volumes and eventually settled on tank.

Mitigation: minimize the disabled window. The fast pattern is:

1. Disable the over-pool cluster-wide
2. Patch the target volume to `numberOfReplicas: 3` (or delete one replica for the already-N=3 case)
3. Wait only for the new replica to be *scheduled* (its CR appears with a flash diskPath)
4. Re-enable the pool immediately
5. Then wait for sync to complete

This shrinks the window to seconds even for large volumes. Used for all 25 migrations on 2026-05-30 with one regression (jellyfin) before adopting this pattern.

### 3. Large volumes (>50 GB) need isolated handling

Rebuilds take longer than the short windows above. If something else triggers a rebuild on the same large volume mid-migration, both rebuilds will retry until one wins. Migrate large volumes last and don't run any other migration until the large one's rebuild has fully completed (volume `status.robustness = healthy` with 3 running replicas).

### 4. Vault migrations: standby pods first, leader last

Each vault-raft PVC is consumed by one vault pod, which has its own raft consensus. Bumping a Longhorn volume's replica count doesn't affect raft membership, but during a brief PVC IO stall a vault pod can lose its raft heartbeat. With 3 vault pods, you can lose one at a time without losing raft quorum.

Procedure:

```bash
# Check that all 3 are unsealed and identify the leader before each PVC
for i in 0 1 2; do
  echo "=== vault-raft-$i ===";
  kubectl -n vault-raft exec vault-raft-$i -- vault status \
    | grep -E "Sealed|HA Mode";
done
```

Migrate `data-vault-raft-N` PVCs only when both other pods are unsealed and `vault-raft-N` itself is a standby (not the active leader). Migrate the leader's PVC last.

### 5. The `--keep-extra` flag matches the new SC default

The original `migrate-volumes-to-cross-pool.sh` design was 2→3→2, leaving each migrated volume at N=2 cross-pool. With `home-infra-rd0` setting the default SC to N=3, the script gained a `--keep-extra` flag (commit `8aed670`) that skips the drop step. Use `--keep-extra` for new migrations so existing volumes converge to the same shape new volumes get.

### 6. StorageClass parameter format

`replicaDiskSoftAntiAffinity` at the StorageClass level takes `enabled` / `disabled` / `ignored`. The same setting at the cluster level (`replica-disk-soft-anti-affinity` Longhorn Setting CR) takes booleans `true` / `false`. Using `"true"` in a SC parameter produces:

```
failed to provision volume with StorageClass "...":
rpc error: code = InvalidArgument
desc = invalid parameter replicaDiskSoftAntiAffinity:
       invalid ReplicaDiskSoftAntiAffinity setting: true
```

…and the PVC stays Pending. SC parameters are also immutable — fixing the value requires `kubectl delete sc` + re-apply (or for ArgoCD-managed, `Replace=true` syncOption plus manual SC delete on the first apply because ArgoCD's Replace uses `kubectl replace` without `--force`).

### 7. The helm-managed `longhorn-storageclass` ConfigMap

The Longhorn chart's `persistence.defaultClass: true` (default) generates a `longhorn-storageclass` ConfigMap in `longhorn-system` that longhorn-manager reads on startup to render the default `longhorn` SC. If you want ArgoCD to own the default SC manifest, set `persistence.defaultClass: false` and delete the existing ConfigMap. Otherwise longhorn-manager will recreate the SC from the configmap on every restart, fighting ArgoCD's selfHeal.

## Where the Code Lives

| Concern | Path |
|---|---|
| SC manifests (default + flash + tank) | `argocd/manifests/longhorn-storage-classes/` |
| ArgoCD Application | `argocd/apps/prod/longhorn-storage-classes.yaml` |
| Helm values for Longhorn | `ansible/roles/cluster_platform/templates/longhorn-values.yaml.j2` |
| Tank disk Ansible task | `ansible/roles/k3s/tasks/longhorn-tank-disk.yml` |
| Audit script | `scripts/maintenance/verify-cross-pool-placement.sh` |
| Migration script | `scripts/maintenance/migrate-volumes-to-cross-pool.sh` |
| Operator runbook | `docs/operations/cluster-operations.md` (Longhorn section) |

## Follow-ups

Tracked in beads:

- `home-infra-hf1` (P2): DRY device paths in worker host_vars → group_vars
- `home-infra-pj7` (P2): collapse `longhorn-tank-disk.yml` + `longhorn-data-disk.yml`
- `home-infra-zdc` (P3): Longhorn settings via Helm values, not `kubectl patch`
- `home-infra-ark` (P3): bring the flash disk mount under Ansible (currently fstab-only)
- `home-infra-hjt` (P4, deferred): wrap migrate-script in an Ansible playbook
