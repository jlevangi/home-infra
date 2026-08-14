# Cross-Pool Replica Anti-Affinity Spike

**Date:** 2026-05-30
**Beads issue:** home-infra-pwo (spike, closed) → unblocks home-infra-rd0
**Status:** GO. Replace `replicaDiskSoftAntiAffinity: "true"` with `"enabled"` and proceed.

---

## What This Validated

The 2026-05-29 cross-pool architecture ([sibling handoff](2026-05-29-longhorn-cross-pool-resilience.md)) noted that Longhorn has no native "one replica per disk type" primitive — the default StorageClass uses best-effort cross-pool placement, and the audit script picks up the misses. This spike tested whether bumping `numberOfReplicas` to 3 plus `replicaDiskSoftAntiAffinity: "enabled"` produces the user's preferred 2-tank + 1-flash placement automatically, without needing a mutating webhook.

Result: yes, consistently, on every test PVC.

## Method

Created a throwaway SC + namespace + 3 × 1 Gi PVCs on prod:

```yaml
# longhorn-spike-antiaffinity SC, mirrors the default `longhorn` SC params
# except: numberOfReplicas=3, replicaDiskSoftAntiAffinity=enabled
```

Three pods attached to force replica scheduling. Inspected `replica.longhorn.io` placement and ran `scripts/maintenance/verify-cross-pool-placement.sh`.

Then deleted the namespace, waited for volume drainage, deleted the SC.

## Findings

### 1. The parameter value is `"enabled"`, not `"true"`

First attempt used `replicaDiskSoftAntiAffinity: "true"` (matching the cluster-level setting name's accepted values). The csi-provisioner rejected every PVC with:

```
failed to provision volume with StorageClass "longhorn-spike-antiaffinity":
rpc error: code = InvalidArgument
desc = invalid parameter replicaDiskSoftAntiAffinity:
       invalid ReplicaDiskSoftAntiAffinity setting: true
```

The StorageClass parameter accepts `enabled` / `disabled` / `ignored`. This is divergent from the cluster-level `replica-disk-soft-anti-affinity` setting which takes `true` / `false`. **Use `"enabled"` in any SC manifest.**

`StorageClass.parameters` are immutable — fixing the value required `kubectl delete sc` then re-apply.

### 2. Placement was 2-tank + 1-flash on every PVC

| PVC | replica 1 | replica 2 | replica 3 |
|---|---|---|---|
| spike-pvc-1 | worker-1 tank | worker-2 tank | worker-3 flash |
| spike-pvc-2 | worker-1 tank | worker-2 tank | worker-3 flash |
| spike-pvc-3 | worker-1 tank | worker-2 tank | worker-3 flash |

Identical layout every time — flash on worker-3, tank on workers 1+2. The deterministic landing suggests Longhorn's scheduler is picking the lowest-cost feasible assignment given uniform disk utilization (which equals the user's intent: more replicas on the larger, more robust pool).

### 3. The audit script correctly handled the new SC

`scripts/maintenance/verify-cross-pool-placement.sh` did not flag any of the 3 spike volumes. It only skips by SC name on `longhorn-flash` / `longhorn-tank`, so a new SC with a different name is evaluated normally, and the spike volumes' flash-and-tank replica mix means the script's "all replicas on one pool" check correctly returns false.

The audit run did surface 27 same-pool volumes (out of 71 checked, ~38 %), confirming the misplacement problem that motivated this work.

### 4. Untested: replica rebuild on disk failure

The spike did not validate behavior when a flash replica's disk goes offline — i.e. does Longhorn rebuild the flash replica back onto flash (preserving 2-tank + 1-flash), rebuild onto a different worker's flash, or fall back to a third tank replica? Observe this opportunistically during the home-infra-rd0 rollout or during a future controlled IM-pod cycle. The expected behavior (per Longhorn's documented soft-affinity semantics) is "prefer the missing affinity tag, fall back to any available disk when no qualifying disk is schedulable", but it's worth confirming on this topology before declaring victory.

## Decision

**GO** for home-infra-rd0:

- Use `replicaDiskSoftAntiAffinity: "enabled"` on the default `longhorn` SC
- Set `numberOfReplicas: "3"`
- Leave `longhorn-flash` and `longhorn-tank` at N=2 (they're pinned by design)
- Document the rebuild behavior under home-infra-60r once observed

## Side Notes

- The audit script's `KUBECTL=${KUBECTL:-kubectl}` indirection breaks when you pass `KUBECTL="kubectl --context=foo"` because `command -v` then sees the space-separated string as a single binary name. Workaround: switch context first with `kubectl config use-context`, then run the script bare. Worth a tiny `verify-cross-pool-placement.sh` polish but not blocking.
