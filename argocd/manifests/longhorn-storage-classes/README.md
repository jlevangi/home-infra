# Longhorn Storage Classes

ArgoCD-managed Longhorn StorageClasses for the prod cluster.

## What's here

| SC | Purpose |
|---|---|
| `longhorn-general` | Canonical general-purpose class. 3 replicas, soft cross-pool placement. |
| `longhorn-fast` | Canonical flash-pinned class for low-latency, read-mostly state. |
| `longhorn-steady` | Canonical tank-pinned class for heavy continuous writers. |
| `longhorn` | Legacy alias for `longhorn-general`. Remains the default during the naming transition. |
| `longhorn-flash` | Legacy alias for `longhorn-fast`. |
| `longhorn-tank` | Legacy alias for `longhorn-steady`. |

`longhorn-singleton` and legacy `longhorn-redundant` live in a sibling
directory (`../longhorn-redundant-sc/`). `longhorn-media` is currently still
Ansible-managed (no cross-pool concern; pre-dates this work).

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

The current manifests keep two naming sets in parallel:

- Canonical names used by new manifests: `longhorn-general`, `longhorn-fast`,
  `longhorn-steady`
- Legacy aliases kept for bound PVC compatibility during migration:
  `longhorn`, `longhorn-flash`, `longhorn-tank`

The legacy default `longhorn` already reflects the post-`home-infra-rd0` state:
`numberOfReplicas: "3"` and `replicaDiskSoftAntiAffinity: "enabled"`.

Only one default should exist during the transition. Once all managed PVCs use
explicit canonical names, the default can move from `longhorn` to
`longhorn-general` and the legacy aliases can be retired.

## Adding a new env

The `overlays/prod` overlay is the only one wired today. To add stage or test, create a sibling overlay directory and an ArgoCD `Application` under `argocd/apps/<env>/`. If per-env replica counts diverge, patch them in the overlay rather than forking the base.
