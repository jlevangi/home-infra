# Longhorn Storage Classes

ArgoCD-managed Longhorn StorageClasses for the prod cluster.

## What's here

| SC | Purpose |
|---|---|
| `longhorn` | Canonical general-purpose class. 2 replicas, soft cross-pool placement. |
| `longhorn-general` | Legacy alias for `longhorn`. |
| `longhorn-fast` | Canonical flash-pinned class for low-latency, read-mostly state. |
| `longhorn-tank` | Canonical tank-pinned class for heavy continuous writers. |
| `longhorn-steady` | Legacy alias for `longhorn-tank`. |
| `longhorn-flash` | Legacy alias for `longhorn-fast`. |
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

The current manifests keep canonical names plus temporary legacy aliases in parallel:

- Canonical names used by new manifests: `longhorn`, `longhorn-fast`,
  `longhorn-tank`, `longhorn-redundant`, `longhorn-vault-raft`
- Legacy aliases kept for bound PVC compatibility during migration:
  `longhorn-general`, `longhorn-flash`, `longhorn-steady`, `longhorn-singleton`

The canonical default `longhorn` carries `numberOfReplicas: "2"` and
`replicaDiskSoftAntiAffinity: "enabled"`.

It was `"3"` under `home-infra-rd0`, sized for 3 flash + 3 tank disks spread
across workers 1/2/3. Two of those Atlas workers are being retired (2026-08-17),
leaving three storage nodes; at N=3 every general volume is forced onto all
three, which pushes `k3s-prod-worker-4` past its DiskPressure threshold. N=2
also shifts the disk-anti-affinity outcome from 2-tank + 1-flash to 1-flash +
1-tank, keeping less app data on the slow HDD pool.

Only one default should exist during the transition. `longhorn` remains that
default; the alias objects can be retired after bound PVC migrations complete.

## Adding a new env

The `overlays/prod` overlay is the only one wired today. To add stage or test, create a sibling overlay directory and an ArgoCD `Application` under `argocd/apps/<env>/`. If per-env replica counts diverge, patch them in the overlay rather than forking the base.
