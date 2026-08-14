# Archived Session Handoffs

Narrative handoff documents from past working sessions, moved here from the
top-level `handoff/` directory on 2026-08-14. They are kept for the reasoning
and hard-won gotchas they contain, **not** as a source of truth for current
state — much of what they describe has since changed.

**For current status, use `bd`.** Every outstanding item these documents
described was either verified as already resolved or filed as a bd issue
before archiving (see below).

## What was still outstanding when these were archived

Checked against the live cluster on 2026-08-14, not taken on trust from the
documents:

| Item | Outcome |
|---|---|
| Longhorn `replica-auto-balance` left `disabled` after the 2026-05 recovery | Still disabled — filed as `home-infra-p2zf` |
| `verify-cross-pool-placement.sh` has no scheduled run | Confirmed no cronjob — filed as `home-infra-1k7m` |
| `kioto-postgres-data-pvc` / `storage-loki-0` still on `longhorn-tank` | Confirmed — folded into `home-infra-mi4.10` |
| memos `nodeSelector` workaround for the Longhorn SIGBUS bug | Already removed — no action |
| `yams` Application `OutOfSync` | Now Synced/Healthy — no action |
| Prometheus PVC on plain `longhorn` instead of a tiered class | Since moved to `longhorn-fast` — no action |
| Vault orphan volume, SparkyFitness detached PVCs, one-PVC migration waves | Already tracked under the `home-infra-96w` epic |
| Cross-pool follow-ups (`hf1`, `pj7`, `hjt`, `13o`, `95b`) | All closed |

## Contents

- `2026-05-29-longhorn-cascade-recovery.md` — the cascade failure and recovery;
  origin of the `replica-auto-balance` disable
- `2026-05-29-longhorn-cross-pool-resilience.md` — cross-pool architecture and
  the repair runbook
- `2026-05-29-longhorn-storage-rebalance.md` — PVC over-provisioning analysis
- `2026-05-30-cross-pool-migration-complete.md` — migration methodology lessons;
  why soft anti-affinity is a tiebreaker and not a guarantee
- `2026-05-30-cross-pool-replica-anti-affinity-spike.md` — the spike that
  established `replicaDiskSoftAntiAffinity` takes `"enabled"`, not `"true"`
- `2026-05-31-storage-policy-cleanup-handoff.md` — storage policy and GitOps
  drift audit
- `2026-06-01-storage-cleanup-progress-handoff.md` — the pragmatic-scope
  narrowing of that cleanup
