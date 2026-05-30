# Longhorn Storage Classes

ArgoCD-managed Longhorn StorageClasses for the prod cluster.

## What's here

| SC | Purpose |
|---|---|
| `longhorn` | Default. `numberOfReplicas: 2`, best-effort cross-pool. |
| `longhorn-flash` | Pins all replicas to flash-tagged disks. Write-heavy DBs. |
| `longhorn-tank` | Pins all replicas to tank-tagged disks. Cold storage. |

`longhorn-redundant` lives in a sibling directory (`../longhorn-redundant-sc/`). `longhorn-media` is currently still Ansible-managed (no cross-pool concern; pre-dates this work).

## Why ArgoCD owns these now

Before this directory existed, the three SCs above had inconsistent ownership:

- `longhorn` was created by the Longhorn helm chart via the `longhorn-storageclass` ConfigMap (`persistence.defaultClass: true`) and concurrently patched by Ansible's `longhorn-storage-config` role. Two writers per object.
- `longhorn-flash` and `longhorn-tank` were created by Ansible via inline `kubectl apply -f -` shell tasks. One writer, but inconsistent with the peer `longhorn-redundant` SC which already lived in ArgoCD.

`home-infra-btv` unified this by:
1. Setting `persistence.defaultClass: false` on the Longhorn helm release (Ansible template `longhorn-values.yaml.j2`) so helm stops managing the `longhorn-storageclass` ConfigMap.
2. Moving all three SC manifests here.
3. Removing the Ansible build/apply tasks from `longhorn-storage-config.yml`.

## Migration / adoption

The manifests mirror the live SC state byte-for-byte at the time of migration. Adopting them with ArgoCD should produce no parameter change. The pre-existing `longhorn.io/last-applied-configmap` annotation on `longhorn` is dropped because ArgoCD won't reapply it; this is cosmetic.

Once `home-infra-rd0` lands, the default `longhorn` manifest here picks up `numberOfReplicas: "3"` and `replicaDiskSoftAntiAffinity: "enabled"`.

## Adding a new env

The `overlays/prod` overlay is the only one wired today. To add stage or test, create a sibling overlay directory and an ArgoCD `Application` under `argocd/apps/<env>/`. If per-env replica counts diverge, patch them in the overlay rather than forking the base.
