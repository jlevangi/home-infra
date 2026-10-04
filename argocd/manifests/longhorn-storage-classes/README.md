# Longhorn Storage Classes

ArgoCD-managed Longhorn StorageClasses for the prod cluster.

## What's here

| SC | Purpose |
|---|---|
| `longhorn` | Default 2-replica class, pinned to flash, any flash node. |
| `longhorn-flash` | Canonical explicit flash tier for latency-sensitive state. |
| `longhorn-tank` | Canonical tank tier for capacity/archive workloads. |
| `longhorn-redundant` | Canonical higher-redundancy class for singleton state. |
| `longhorn-vault-raft` | Vault raft only. 2 replicas on flash. |
| `longhorn-one-replica-flash` | Opt-in single replica on flash, backup-restorable. |

Unused `longhorn-general`, `longhorn-singleton`, `longhorn-steady`,
`longhorn-media`, `longhorn-fast`, and `longhorn-one-replica-tank` were retired after checking live PVC/PV references. Ansible
no longer creates media classes. Keep `longhorn-static`: it is Longhorn's
configured recovery/import class, even when no current PVC uses it.

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

Classes: `longhorn`, `longhorn-flash`, `longhorn-tank`, `longhorn-redundant`
(retire once Plex is gone, home-infra-9wvm), `longhorn-vault-raft`,
`longhorn-one-replica-flash`.

Tank disks exist only on Atlas, so a 2-replica tank volume has both replicas
on one physical host. Prefer flash for anything that matters.

The default `longhorn` class has two replicas and `diskSelector: flash`.
Capacity/archive workloads must explicitly select `longhorn-tank`; tank is not
automatic spillover for normal app state. Existing volumes retain their current
placement until individually reconciled.

Only `longhorn` is marked default. K3s `local-path` is un-defaulted by the
ansible k3s role (`local-storage.yaml.skip` + annotation).

## Adding a new env

The `overlays/prod` overlay is the only one wired today. To add stage or test, create a sibling overlay directory and an ArgoCD `Application` under `argocd/apps/<env>/`. If per-env replica counts diverge, patch them in the overlay rather than forking the base.
