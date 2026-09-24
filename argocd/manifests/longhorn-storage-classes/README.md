# Longhorn Storage Classes

ArgoCD-managed Longhorn StorageClasses for the prod cluster.

## What's here

| SC | Purpose |
|---|---|
| `longhorn` | Default 2-replica class, pinned to flash. |
| `longhorn-general` | Compatibility alias for `longhorn`. |
| `longhorn-flash` | Canonical explicit flash tier for latency-sensitive state. |
| `longhorn-fast` | Compatibility alias for `longhorn-flash`. |
| `longhorn-tank` | Canonical tank tier for capacity/archive workloads. |
| `longhorn-steady` | Legacy alias for `longhorn-tank`. |
| `longhorn-redundant` | Canonical higher-redundancy class for singleton state. |
| `longhorn-singleton` | Legacy alias for `longhorn-redundant`. |
| `longhorn-vault-raft` | Vault raft only. Single replica on tank. |

`longhorn-media` is currently still Ansible-managed (no cross-pool concern;
pre-dates this work).

## Why ArgoCD owns these now

Before this directory existed, the three legacy SCs above had inconsistent
ownership:

- `longhorn` was created by the Longhorn helm chart via the `longhorn-storageclass` ConfigMap (`persistence.defaultClass: true`) and concurrently patched by Ansible's `longhorn-storage-config` role. Two writers per object.
- `longhorn-flash` and `longhorn-tank` were created by Ansible via inline `kubectl apply -f -` shell tasks. One writer, but inconsistent with the peer `longhorn-redundant` SC which already lived in ArgoCD.

`home-infra-btv` unified this by:
1. Setting `persistence.defaultClass: false` on the Longhorn helm release (Ansible template `longhorn-values.yaml.j2`) so helm stops managing the `longhorn-storageclass` ConfigMap.
2. Moving all three SC manifests here.
3. Removing the Ansible build/apply tasks from `longhorn-storage-config.yml`.

## Current state

The current manifests keep canonical names plus compatibility aliases in parallel:

- Canonical names used by new manifests: `longhorn`, `longhorn-flash`,
  `longhorn-tank`, `longhorn-redundant`, `longhorn-vault-raft`
- Compatibility aliases kept for bound PVCs: `longhorn-general`,
  `longhorn-fast`, `longhorn-steady`, `longhorn-singleton`

The default `longhorn` class has two replicas and `diskSelector: flash`.
Capacity/archive workloads must explicitly select `longhorn-tank`; tank is not
automatic spillover for normal app state. Existing volumes retain their current
placement until individually reconciled.

Only `longhorn` is marked default. Alias objects can be retired after bound PVC
migrations complete.

## Adding a new env

The `overlays/prod` overlay is the only one wired today. To add stage or test, create a sibling overlay directory and an ArgoCD `Application` under `argocd/apps/<env>/`. If per-env replica counts diverge, patch them in the overlay rather than forking the base.
