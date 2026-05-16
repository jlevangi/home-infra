# Post-Mortem — Longhorn Cascade Triggered by Failing SSD in `flash` ZFS Pool

**Incident window**: 2026-05-15 17:18 UTC (unclean shutdown) → 2026-05-16 21:05 UTC (cluster fully recovered)
**Duration**: ~28 hours
**Cluster**: k3s-prod
**Longhorn**: v1.11.2 (manager + instance-manager); engine images formerly mixed v1.11.1/v1.11.2
**Impact**: 60 Longhorn volumes affected (~half flapping at peak), every workload PVC at risk, multiple apps required restore from backup, ~145 pods needed re-scheduling

## TL;DR

A failing SATA SSD (`/dev/sdf`, serial `TUSQA2488X00041`) in the host's `flash` raidz1 ZFS pool was silently returning bad reads. ZFS reconstructed via parity (masking the failure at the pool level), but the latency from those reconstructions propagated up through virtio-blk → guest VM kernel → containerd → Longhorn replica → engine RPC → kubelet iSCSI → workload pod. At every layer there's a timeout (Longhorn's 16 s engine-replica-timeout being the tightest). When timeouts fired, engines died, replicas got marked failed, and Longhorn flapped.

Compounded by:
1. A stuck Longhorn engine-image upgrade (30 of 60 volumes still on v1.11.1 while manager was v1.11.2) which caused RPC race conditions and rebuild EOFs
2. Recurring `tgtd` orphan iSCSI targets after every engine restart, blocking re-attaches
3. Host DRAM correctable-ECC errors on the same day (DIMM Socket 1 / Channel 1 / DIMM 0|1)
4. VM filesystem journal corruption from the original abrupt hard-stop on the un-rebuilt nodes (worker-1, worker-2, 3 CP nodes)

Fix: drain VMs off `flash` → `tank` pool, restart instance-managers to clear tgtd state, live-upgrade all engines to v1.11.2, throttle Longhorn rebuild concurrency, restore lost volumes from backup. Hardware downtime still needed to physically remove the bad SSD.

## Original Trigger Event (2026-05-15)

- OS root disk on a worker node hit 100% (related: backups+logs accumulation on the new SSD pool which has different fill patterns than the old HDDs)
- User performed a hard-stop of all CP + worker VMs simultaneously (no graceful shutdown)
- Worker-3 and worker-gpu-1 were manually rebuilt from clean templates and rejoined the cluster fresh
- Worker-1, worker-2, and all 3 CP nodes were left as-is (their guest filesystems may have unclean ext4 journals from the hard-stop)
- 26 Longhorn replicas on worker-1 all failed within a 2-second window at `2026-05-15T17:18:48-50Z` (the moment of unclean shutdown)

## Storage Layout — Critical Background

- VM OS disks live on a single Samsung SSD (separate from the issue)
- Longhorn data disks were RECENTLY MIGRATED from the slower HDD `tank` pool to a NEW **3-SATA-SSD ZFS pool called `flash`** for performance
- The `flash` pool: 3× `UDSS_UD2CS1HT301-001T` SATA SSDs in `raidz1-0` configuration. All 3 drives share consecutive serials (`TUSQA2488X00041`, `X00052`, `X00097`) — same manufacturing batch. Brand is unfamiliar (possibly budget/grey-market)

**Working hypothesis confirmed late in incident**: a hardware fault in the new `flash` SSDs was the underlying cause; the migration onto these SSDs created the exposure. HDDs had been masking the timing-sensitive issues simply by being slow enough that SATA never reached the timeout boundary.

## Root Cause Analysis

### Primary cause — Failing SSD `TUSQA2488X00041` (verified via SMART)

| Drive serial | Device | Reallocated_Sector_Ct | Reallocated_Event_Count | Current_Pending_Sector | Offline_Uncorrectable | Used_Rsvd_Blk_Cnt_Chip | Verdict |
|---|---|---|---|---|---|---|---|
| `TUSQA2488X00041` | `/dev/sdf` | **1** | **32** | **1** | **32** | **1** | **FAILING — replace** |
| `TUSQA2488X00097` | other | 0 | 0 | 0 | 0 | 0 | Clean |
| `TUSQA2488X00052` | other | 0 | 0 | 0 | 0 | 0 | Clean |

`zpool status flash` reports ONLINE with 0 errors because ZFS raidz1 reconstructs every bad read via parity. But each parity-reconstructed read adds tens-of-milliseconds latency. At sustained Longhorn rebuild bandwidth (50 MB/s × 5 concurrent = 250 MB/s aggregate), these latency spikes compound until a 16-second engine-replica-timeout fires → engine kills the replica → cascade.

### Contributing cause — Degrading host DRAM (correctable ECC errors)

```
[Fri May 15 07:12:28 2026] mce: [Hardware Error]: Machine check events logged
[Fri May 15 09:36:23 2026] EDAC sbridge MC0: HANDLING MCE MEMORY ERROR
[Fri May 15 09:36:23 2026] EDAC MC2: 1 CE memory scrubbing error on
                            CPU_SrcID#1_Ha#1_Chan#1_DIMM#0 or DIMM#1
```

Same day as the original incident. ECC corrected, but repeated CE errors signal a degrading DIMM. Could also corrupt VM memory in rare uncorrected cases.

### Contributing cause — Stuck Longhorn engine upgrade

- Manager + instance-manager + `default-engine-image` were all `v1.11.2`
- 30 of 60 volumes still pinned to **v1.11.1** (the ones that were attached when manager was upgraded)
- `concurrent-automatic-engine-upgrade-per-node-limit: 0` (explicitly disabled, leaving the upgrade half-done)
- v1.11.2 manager × v1.11.1 engine = RPC race conditions, rebuild RPC failures, mid-sync `EOF`, "cannot set rebuilding=true from state rebuilding"
- Shared instance-manager-aio means one v1.11.1 volume failing destabilizes healthy v1.11.2 volumes on the same node

### Contributing cause — Recurring `tgtd` orphan iSCSI targets

- Every engine restart picks the next free Target ID (TID)
- If that TID has a stale entry from a previous engine that didn't clean up properly (no LUN 1, just leftover I_T_nexus), the new engine's cleanup attempt fails with `tgtadm: can't find the logical unit` → engine exits with `Failed to init frontend`
- Surgical removal fails because iSCSI sessions are still active: `tgtadm: this target is still active`
- Only reliable fix: restart the instance-manager pod (~30 s outage for every volume attached on that node)
- Orphans accumulate again over hours of normal cluster activity (engine moves, IM jitter)

### Contributing cause — Suspect VM filesystems on un-rebuilt nodes

- Worker-3 (rebuilt fresh ~35h ago) and worker-gpu-1 (rebuilt fresh) had FEWER issues than worker-1 and worker-2 (not rebuilt)
- Worker-1's `/var/lib/longhorn` bind-mount inside its longhorn-manager pod disappeared once mid-incident (recoverable but suspicious)
- `EXT4-fs error` on iSCSI device files seen on all 3 storage workers — most plausibly downstream of bad SSD reads, but un-rebuilt VMs are also where ext4 journals are most likely inconsistent from the hard-stop

## Diagnostic Asymmetry Observed (supported the hardware hypothesis)

| Node | Rebuilt? | Issues observed |
|------|----------|-----------------|
| worker-1 | NO | Longhorn data disk bind-mount disappeared once; recurrent tgtd orphans; engine restart loops; midday cascade of 9 replica failures in 4s (mimics original incident) |
| worker-2 | NO | Recurrent tgtd orphans; FailedRebuilding with EOF when source replica is here; high IM memory accumulation |
| worker-3 | YES (~35h ago) | Generally cleaner; IM memory still accumulated to 6.3 GB before manual restart (so not purely about VM filesystem) |
| worker-gpu-1 | YES | Generally cleanest; was eviction-pending but Longhorn auto-re-enabled it |
| CP nodes (cp-1/2/3) | NO | No Longhorn replicas; impact unknown |

Worker-3 still showing some issues (6.3 GB IM memory; occasional EOFs) means VM-filesystem corruption alone didn't explain everything — there IS a Longhorn-side issue (tgtd cleanup; possible IM memory leak under load). But the rebuilt-vs-not-rebuilt asymmetry was real and meaningful.

## All Issues Found (in order of discovery)

### Issue 1 — Insufficient schedulable Longhorn storage nodes (RESOLVED)
- Only worker-2 and worker-3 had `allowScheduling=true`; worker-1 cordoned with `evictionRequested=true`; worker-gpu-1 disk `evictionRequested=true, allowScheduling=false`
- StorageClass `longhorn` defaults to `numberOfReplicas: 3` — born degraded with only 2 nodes
- With `replica-soft-anti-affinity=false`, max achievable replicas = 2
- **Fix**: cleared eviction + enabled scheduling on worker-1 (later determined worker-1 was unhealthy — see Issue 5)

### Issue 2 — 26 zombie failed replicas on worker-1 (RESOLVED)
- All replicas had `failedAt=2026-05-15T17:18:48-50Z` (the unclean shutdown moment)
- Occupied "replica slots" and added controller noise; ~74 GB of orphan replica data
- **Fix**: bulk-deleted all 26 failed Replica CRs; Longhorn cleaned up on-disk data

### Issue 3 — Stuck Longhorn engine upgrade with auto-upgrade DISABLED (RESOLVED — first major root cause)
- See Root Cause Analysis above for details
- **Fix**: live-engine-upgraded all 30 v1.11.1 volumes by patching `volume.spec.image` to v1.11.2 image, in waves of 5 with 25s settle between. Zero flapping during upgrade. Total time ~3 min
- Also set `concurrent-automatic-engine-upgrade-per-node-limit` from 0 → 3 (defensive)

### Issue 4 — Orphan iSCSI targets in `tgtd` blocking re-attaches (RECURRING — partial fix)
- See Root Cause Analysis above
- **Fix**: instance-manager pod restart clears tgtd state entirely (disruptive but reliable)
- IMs restarted multiple times during incident: worker-3 (twice), worker-2 (twice), worker-1 (once), worker-gpu-1 (once)
- **Long-term fix needed**: upgrade Longhorn to v1.12.x (V2 SPDK engine doesn't use tgtd), or schedule periodic IM restarts as maintenance

### Issue 5 — Worker-1 disk subsystem unhealthy (PARTIALLY RESOLVED)
- At 2026-05-16T05:01:46Z, **9 replicas on worker-1 failed in 4 seconds** — same pattern as the original incident
- `/var/lib/longhorn` bind-mount inside longhorn-manager pod disappeared ("No such file or directory") while host mount table still showed `/dev/sdb` mounted
- dmesg showed `EXT4-fs error (device sdf): __ext4_find_entry:1683: inode #2: comm .NET ThreadPool: reading directory lblock 0` + `Remounting filesystem read-only`
- `sdf` was the iSCSI device for a .NET app (sonarr/radarr/prowlarr), NOT the Longhorn data disk
- OS root disk 76% used (not the original 100% issue)
- **Mitigation**: cordoned worker-1; drained workloads; later moved its VM disks to `tank` pool which stabilized it
- **Still TODO**: rebuild the worker-1 VM from clean templates (FS journal may be unclean from original hard-stop)

### Issue 6 — ext4 corruption on iSCSI mount points across multiple workers (UNDERSTOOD)
- dmesg on worker-2: `EXT4-fs error (device sdm): comm libuv-worker: Detected aborted journal, Remounting filesystem read-only`
- dmesg on worker-3: `EXT4-fs error (device sdn): comm loki: reading directory lblock 0`
- dmesg on worker-1: `comm .NET ThreadPool: reading directory lblock 0`
- These were historical (timestamps ~7h before discovery, from the original cascade period)
- Caused by Longhorn engines returning stale/inconsistent data during cascade; kernel ext4 detected and protected via RO remount
- Subset of affected volumes had to be restored fresh from backup
- **Lesson**: under load, Longhorn replica revision divergence (or `Revision conflict detected!` errors in engine logs) can produce data the kernel sees as corrupt

### Issue 7 — Restore script doesn't filter 0 B backups (UNRESOLVED — code fix)
- `ansible/roles/k3s/files/discover-backups.py:99,175,251,271` captures `size_bytes` but never filters 0 B
- `ansible/playbooks/k3s-restore-from-backup.yml` proceeds with empty backups silently
- Result: restores succeed-but-empty (gatus, firefox-config, seerr-config, sonarr-config all had `actualSize=0` from this)
- Workaround used: manual `--list` inspection before each restore; prefer older known-good backups via `--backup-before`
- **TODO**: add `size_bytes > 0` filter in discover-backups.py + preflight assert in playbook + `--allow-empty-backup` opt-in in restore-app.sh

### Issue 8 — Restore script's volume name truncation breaks long PVC names (UNRESOLVED — code fix)
- `ansible/playbooks/k3s-restore-from-backup.yml:228` waits for volume by full PVC name
- Longhorn auto-truncates volume names to ~40 chars + hash → wait-loop never finds it
- Affected PVCs: `alertmanager-prometheus-alertmanager-db-alertmanager-prometheus-alertmanager-0` (77 chars), `prometheus-prometheus-prometheus-db-prometheus-prometheus-prometheus-0` (76 chars)
- Workaround: skipped these in `--app` restore; the existing PVCs were already healthy
- **TODO**: script should compare against the actual created Longhorn volume name (or use label selector)

### Issue 9 — Restore script doesn't respect namespace PVC minimum (UNRESOLVED — code fix)
- Script uses backup `size_bytes` as PVC size request
- Namespaces with `LimitRange` requiring min 100 Mi (immich, yams, linkding) reject smaller PVCs
- Affected: `immich-power-tools-data` (72 MiB backup), `maintainerr-config` (62 MiB), `nzbget-config` (70 MiB), `nzbget-gluetun-config` (62 MiB), `qbittorrent-gluetun-config` (64 MiB), `linkding-data` (88 MiB)
- Workaround used: post-restore resize the Longhorn volume + recreate the PV at the minimum size (see Workaround section)
- **TODO**: script should use the original PVC's `spec.resources.requests.storage` from the manifest, not the backup data size

### Issue 10 — Bandwidth/concurrency saturation under restore load (CONFIRMED — partial workaround)
- Original settings: `replica-rebuilding-bandwidth-limit: 50 MB/s`, `concurrent-replica-rebuild-per-node-limit: 5`, `backup-concurrent-limit: 2`
- Jellyfin restore (~64 GB) at default settings triggered a cluster-wide cascade: 9 volumes faulted in 24 s (vault-raft-0/-2, vaultwarden, sonarr, firefox, librechat-meilisearch, tautulli)
- Pattern: `context deadline exceeded`, `RST_STREAM with error code: CANCEL`, mid-file-sync `EOF`
- Source: NFS read saturation (100 MB/s for 8 min) + IM RPC starvation, made worse by the underlying bad SSD's latency
- Throttled settings used during recovery: `replica-rebuilding-bandwidth-limit: 10 MB/s`, `concurrent-replica-rebuild-per-node-limit: 1`, `backup-concurrent-limit: 1`
- At concurrency=1, rebuilds succeed cleanly but slowly (~1.5 vol/min)
- At concurrency=3, occasional FailedRebuilding events with EOF
- At concurrency=5, **17 volumes faulted briefly** — do not exceed 3 while the bad SSD is in play

### Issue 11 — Volumes stuck attached to wrong node after IM restart (RECURRING — workaround works)
- After IM restart, some volumes have `status.ownerID` on one node but workload pod scheduled to another
- Multi-Attach error blocks attach: `volume is currently attached to different node`
- Affected: immich-db, kube-prometheus-stack-grafana
- **Fix**: `kubectl -n longhorn-system patch volume.longhorn.io <name> --type=merge -p '{"spec":{"nodeID":"<workload-node>"}}'`

### Issue 12 — Stuck PVC/PV in `Terminating` (RESOLVED)
- `storage-loki-0` PVC + its PV in Terminating for 11+ hours
- Finalizers `kubernetes.io/pvc-protection`, `external-provisioner.volume.kubernetes.io/finalizer`, `kubernetes.io/pv-protection`, `external-attacher/driver-longhorn-io` were stuck
- Loki pod stuck `ContainerCreating` waiting for the doomed volume
- **Fix**: force-cleared finalizers on both, deleted loki-0 pod, StatefulSet recreated PVC fresh

### Issue 13 — HARDWARE ROOT CAUSE: failing SSD + degrading DIMM (UNDERLYING)
- See Root Cause Analysis above for full details
- Status: bad SSD still physically in the host but no longer in the IO path (VM data migrated to `tank` pool); safe to schedule host downtime to remove
- DIMM CE errors still need memtest86+ confirmation during the host downtime

### Issue 14 — Restore script races with ArgoCD's PVC auto-recreation (UNRESOLVED — script bug)
- When the restore script runs for an app whose ArgoCD application defines the PVC, the script's PVC-create step can race against ArgoCD recreating the PVC at the manifest size with a different `volumeName`
- Observed for **plex-config-pvc**: script's PV at 28 GB (= backup size); ArgoCD recreated PVC at 50 GB (= manifest size) → script's PVC step failed with immutability error
- **Workaround used**: pause ArgoCD, delete auto-bound PVC + PV + Longhorn volume, resize restored Longhorn volume to match git manifest size, update PV capacity to match, re-enable ArgoCD. New PVC binds cleanly
- **Real fix**: script should (a) keep ArgoCD paused until AFTER PVC is successfully created and bound, AND (b) size both the restored Longhorn volume AND the PV to match the original PVC's `spec.resources.requests.storage`, not the backup data size

### Issue 15 — external-dns blocked by a single conflicting manual A record (RESOLVED)
- After adding the missing `external-dns.alpha.kubernetes.io/target` annotation to kioto's ingress, `koito.levangie.dev` still didn't resolve
- `koito.levangie.dev` had a manual A record (added 2026-04-24) at 172.20.20.200 — predated the external-dns annotation
- external-dns tried to add a CNAME at the same name; Technitium correctly rejected per RFC: *"a CNAME record cannot exists with other record types for the same name"*
- That single 500 response from the Technitium webhook **stalled external-dns's entire batch reconciliation** — every other DNS update also blocked
- **Fix**: delete the conflicting A record in Technitium via API; external-dns auto-recovered after 12 consecutive soft errors
- **Lesson**: when external-dns is in a soft-error loop, ALL DNS updates are blocked, not just the failing one

## Recovery Timeline (UTC)

| Time | Action | Result |
|------|--------|--------|
| 2026-05-15 ~17:18 | Original unclean shutdown | 26 worker-1 replicas failed simultaneously |
| 2026-05-16 ~02:00 | Various per-app restore attempts pre-investigation | Mixed; flapping observed |
| 2026-05-16 ~03:00 | Investigation begins | Found 2-node scheduling issue, 26 zombie replicas |
| 2026-05-16 03:05 | Deleted 26 failed worker-1 replicas | ~74 GB freed |
| 2026-05-16 03:08 | Cleared worker-1 eviction + enabled Longhorn scheduling | 3 schedulable nodes |
| 2026-05-16 03:11–03:25 | Live-engine-upgraded 30 v1.11.1 volumes → v1.11.2 | Zero flapping during upgrade |
| 2026-05-16 ~03:30 | Paperless restore (5 PVCs from <May 9 backups) | All 5 bound |
| 2026-05-16 ~03:40 | Discovered tgtd orphan target issue on worker-3 | Surgical cleanup failed (sessions active) |
| 2026-05-16 ~03:45 | Pinned paperless to worker-1 (clean tgtd) | Paperless up |
| 2026-05-16 04:03 | Restarted worker-3 IM | Cleared tgtd orphans |
| 2026-05-16 04:17 | Restarted worker-2 IM | Cleared tgtd orphans |
| 2026-05-16 ~04:30 | Monitoring restore | Alertmanager hit name-truncation bug; grafana restored OK |
| 2026-05-16 ~04:40 | Change-detection restore (May 10 backup) | OK |
| 2026-05-16 ~04:45 | Immich restore (latest backups) | immich-db, immich-model-cache restored |
| 2026-05-16 ~05:00 | YAMS restore | 10 PVCs restored (sonarr, radarr, prowlarr, qbittorrent, jellyseerr, bazarr, wizarr, tautulli, etc.) |
| 2026-05-16 ~05:25 | Jellyfin restore (64 GB) attempted | Triggered cascade: 17 volumes faulted; ABORTED |
| 2026-05-16 ~05:30 | Throttled bandwidth/concurrency limits | Rebuilds succeed cleanly but slowly |
| 2026-05-16 ~05:35 | Cluster stabilized: 55 healthy, 0 faulted | |
| 2026-05-16 ~05:50 | gatus re-restored from May 9 backup | Up with 95 MB |
| 2026-05-16 ~05:55 | vault-raft-0 unblocked (uncordoned worker-1 kubelet) | All 3 raft pods running; vault unsealed |
| 2026-05-16 ~06:00 | Immich postgres + grafana Multi-Attach fixes | Patched `volume.spec.nodeID` |
| 2026-05-16 ~17:15 | New cascade: firefox-config + data-vault-raft-2 faulted | tgtd orphans RECURRED — same Issue 4 |
| 2026-05-16 17:20–17:30 | Restarted all 3 worker IMs | tgtd cleared |
| 2026-05-16 17:40 | Bumped concurrency 3→5 to speed convergence | **17 volumes briefly faulted** — reverted to 1 |
| 2026-05-16 ~18:30 | User identified `flash` SSD pool as suspect (storage history) | Game-changing context |
| 2026-05-16 ~19:00 | SSH'd to Proxmox host, ran SMART checks | **Found failing SSD `X00041` + DIMM CE errors** |
| 2026-05-16 ~19:15+ | User started VM disk migrations from `flash` → `tank` | Paused Longhorn rebuilds for full IO budget |
| 2026-05-16 ~20:00 | All workers (worker-1, worker-gpu-1, worker-2) migrated off flash | Worker-3 in flight |
| 2026-05-16 ~20:15 | Worker-3 migration complete | All VMs off flash; bad SSD no longer in IO path |
| 2026-05-16 ~20:15 | Re-enabled scheduling + ArgoCD apps; throttle 1→2 concurrent | 137 pods Running |
| 2026-05-16 ~20:30 | linkding restored (88 MiB → 1 GiB PV workaround) | Up |
| 2026-05-16 ~20:35 | jellyfin/plex placed on GPU node with restored data | Up |
| 2026-05-16 ~20:40 | kioto: removed KOITO_DATABASE_URL env (re-migration loop) + added external-dns annotation | Up but DNS still 500 |
| 2026-05-16 ~21:00 | Deleted conflicting manual `koito` A record in Technitium | external-dns recovered; all DNS works |
| 2026-05-16 ~21:05 | **145 pods Running, 0 faulted volumes** | Recovery complete |

## Operational Reference

### Known Failure Patterns (from incident)

| Symptom | Meaning | First diagnostic move |
|---|---|---|
| `AttachVolume.Attach failed ... volume <name> is not ready for workloads` | Engine refusing to come up on the target node | Check engine state + IM logs on `<spec.nodeID>` |
| `Engine of volume <name> dead unexpectedly, setting v.Status.Robustness to faulted` | Engine process died after starting | Check IM logs for tgtadm errors; likely tgtd orphan |
| `volume <name> has been detached` followed by repeated `Remount` requests | Workload pod can't keep the volume attached | Engine cycle; check if pod and volume.spec.nodeID agree |
| `Multi-Attach error for volume "X": volume is currently attached to different node` | `status.ownerID` ≠ pod node | Patch `volume.spec.nodeID` to the workload's node |
| `actualSize: 0` after a restore completes | Restore picked an empty backup OR restore raced and never wrote | Reject this backup; pick an older one with `--backup-before <date>` |
| `tgtadm: this access control rule does not exist` + `tgtadm: can't find the logical unit` + `Failed to init frontend` | Orphan tgtd target with no LUN 1, blocking new engine on that TID | Restart IM pod on that node |
| `cannot set rebuilding=true from state rebuilding` / mid-sync `EOF` | RPC race condition between manager and engine | Was caused by engine version split during this incident; verify all volumes are on same engine version |
| `Revision conflict detected! Expect X, got Y in replica` | Replica data diverged from peers | Replica will be marked failed; auto-rebuild should follow |
| `context deadline exceeded` / `RST_STREAM with error code: CANCEL` during rebuild | RPC/network timeout; usually IO bandwidth saturation OR an underlying flaky disk | Throttle rebuild concurrency + bandwidth; investigate disk health |
| `failed to sync files [...] error reading from server: EOF` | Source replica's connection dropped mid-sync | Same as above |

### Longhorn Signals To Watch (per affected volume)

```
status.state                              # attached / attaching / detached / detaching
status.robustness                         # healthy / degraded / faulted / unknown
status.actualSize                         # 0 after restore = bad
status.currentNode                        # null = no engine running
status.ownerID                            # must match pod's node for clean attach
status.restoreRequired                    # true while restore in progress
status.restoreStatus                      # per-replica restore progress
status.kubernetesStatus.workloadsStatus   # what pod thinks it owns this volume
```

For each replica:

```
spec.nodeID, spec.failedAt, spec.healthyAt, spec.rebuildRetryCount
status.currentState     # running / stopped / starting / error
```

For each engine:

```
spec.nodeID, spec.image
status.currentState
status.replicaModeMap   # per-replica RW (read-write, healthy) / WO (write-only, rebuilding) / ERR
```

### Triage Questions

1. **Is the volume failing on one specific node, or on every node?**
   If one node: tgtd or VM filesystem issue on that node. Pin workload elsewhere temporarily.
   If every node: underlying data corruption or Longhorn version mismatch.
2. **Is the engine dying, or is the pod simply landing too fast (Multi-Attach)?**
   Engine dying → look at IM logs on the engine's node.
   Multi-Attach → patch `volume.spec.nodeID` to match the workload's node.
3. **Does the volume have at least one healthy replica left to rebuild from?**
   `kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '.items[] | select(.spec.volumeName=="X")'`
   Look for any with `spec.healthyAt != ""` and `spec.failedAt == ""`. If yes, auto-salvage works. If no, restore from backup.
4. **Is the restore point actually non-empty?**
   `./scripts/restore-app.sh --prod --pvc <pvc> --list` — eyeball sizes. Reject 0 MiB rows; reject suspiciously small ones (e.g. plex 1 GiB when normal is 28 GiB).
5. **Is the IM on the source node under memory pressure?**
   `kubectl top pod -n longhorn-system | grep instance-manager` — if any IM is >4 GB, restart it (clears tgtd state AND frees memory).
6. **Are all volumes on the same engine image?**
   `kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '.items[] | .status.currentImage' | sort | uniq -c` — if multiple versions appear, perform live-upgrade.

### Recovery Discipline (one app at a time)

1. Work one app at a time. Scale the deployment to `1` only after confirming the Longhorn volume is in a sane state.
2. Verify both: the PVC is `Bound` AND the Longhorn volume is `attached` + `healthy`.
3. If attachment fails, stop immediately and inspect the volume state and events. Do not retry blindly.
4. If a restore returns `actualSize: 0`, do not proceed. Pick a different backup or treat it as invalid.
5. Do not move on to the next app until the current one passes the attach gate.
6. When you need an older point-in-time restore, use a cutoff rather than the newest backup:
   `./scripts/restore-app.sh --prod --app <app> --backup-before YYYY-MM-DD`

### Standard Mitigation Sequence (for cascading flaps)

1. Pause Longhorn rebuilds: `kubectl -n longhorn-system patch setting concurrent-replica-rebuild-per-node-limit --type=merge -p '{"value":"0"}'`
2. Drop bandwidth: `kubectl -n longhorn-system patch setting replica-rebuilding-bandwidth-limit --type=merge -p '{"value":"10485760"}'` (10 MB/s)
3. Identify cascade source via recent fault events:
   `kubectl -n longhorn-system get events --sort-by=.lastTimestamp | grep -i 'fault\|detached.*unexpect'`
4. If tgtd orphans: restart affected IM pod
5. If Multi-Attach: patch `volume.spec.nodeID`
6. If replica all-failed: check for healthy replica with `healthyAt` timestamp → auto-salvage will work
7. If volume genuinely lost both replicas: restore from backup with `--backup-before`
8. Resume rebuilds at concurrency=1 first; only bump to 2-3 after the source of cascading is removed; **do not exceed 3 while a flaky disk is in the IO path**

## Workarounds (Recipes)

### Restoring an app whose backup is smaller than the namespace `LimitRange` minimum

```bash
# 1. Let restore script run (it creates Longhorn volume but fails on PVC step)
./scripts/restore-app.sh --prod --pvc <pvc-name> -y

# 2. Resize the created Longhorn volume to >= namespace minimum
kubectl -n longhorn-system patch volume.longhorn.io <volume-name> \
  --type=merge -p '{"spec":{"size":"1073741824"}}'  # 1 GiB

# 3. Delete the wrong-sized PV the script created
kubectl delete pv <volume-name>-pv

# 4. Delete the failed pending PVC
kubectl -n <namespace> delete pvc <pvc-name>

# 5. Recreate PV at the larger size pointing to the existing Longhorn volume
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: <volume-name>-pv
spec:
  capacity: { storage: 1Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Delete
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    volumeHandle: <volume-name>
    fsType: ext4
EOF

# 6. ArgoCD re-creates the PVC at the manifest size; binds to the PV; pod starts
```

The Longhorn volume retains the restored data; only the wrapper sizing was wrong.

### Live-upgrading a v1.11.x volume's engine image (used to fix 30 stuck volumes)

```bash
# Set spec.image; Longhorn handles the engine swap, replicas migrate cleanly
kubectl -n longhorn-system patch volume.longhorn.io <volume-name> --type=merge \
  -p '{"spec":{"image":"docker.io/longhornio/longhorn-engine:v1.11.2"}}'

# Wait ~10s, verify
kubectl -n longhorn-system get volume.longhorn.io <volume-name> -o jsonpath='{.status.currentImage}{"\n"}'
```

Safe to do in waves of 5 with 25s settle between, even on attached/in-use volumes.

### Force-detaching a volume that's stuck attached to a stale node

```bash
# Clear spec.nodeID, then set to the desired node
kubectl -n longhorn-system patch volume.longhorn.io <name> --type=merge -p '{"spec":{"nodeID":""}}'
sleep 15
kubectl -n longhorn-system patch volume.longhorn.io <name> --type=merge -p '{"spec":{"nodeID":"<workload-node>"}}'
```

### Deleting a Technitium DNS record via API

```bash
TOKEN=$(curl -sf "$URL/api/user/login?user=$U&pass=$P&includeInfo=false" | jq -r .token)
curl -s "$URL/api/zones/records/delete?token=$TOKEN&zone=<zone>&domain=<fqdn>&type=A&ipAddress=<ip>"
```

Useful when a manual record conflicts with what external-dns wants to manage.

## Settings Changed During Incident

```
replica-rebuilding-bandwidth-limit                = 10485760 (10 MB/s)  [default was 50 MB/s]
concurrent-replica-rebuild-per-node-limit         = 2                    [default was 5; we used 0/1/2/3/5 at various points]
backup-concurrent-limit                           = 2                    [default was 2; was 1 during peak; restored]
concurrent-automatic-engine-upgrade-per-node-limit = 3                   [originally 0/disabled; now 3]
```

The bandwidth and rebuild concurrency were dropped to avoid pushing through the bad SSD's latency limits. After the SSD is replaced and the host is on healthy storage, these can be returned to defaults (or stay at the moderate values — they're not painfully slow).

## Lessons Learned

- **Verify hardware before trusting "ONLINE" from a redundant pool.** ZFS raidz1 masks single-drive failure via parity but the latency cost propagates everywhere. Run `smartctl -A` against each drive periodically; check `Reallocated_Sector_Ct`, `Reallocated_Event_Count`, `Current_Pending_Sector`, `Offline_Uncorrectable`. ANY non-zero is a yellow flag; multiple non-zero is "replace now".
- **Live engine upgrades during `state=deploying` engineimage WORKS.** The "deploying" status is cosmetic when caused by CP nodes counting against the deployment percentage but never being intended to host engines. Don't be afraid to patch `volume.spec.image` on an attached volume.
- **Instance-manager pod restart is the standard fix for tgtd state issues**, but is disruptive (~30s outage per volume on that node). Drop concurrent-rebuild to 1 + bandwidth to 10 MB/s BEFORE restarting to avoid cascading during recovery.
- **Multi-Attach errors after IM restart** are routine: `kubectl -n longhorn-system patch volume.longhorn.io <name> --type=merge -p '{"spec":{"nodeID":"<workload-node>"}}'`
- **Longhorn auto-cancels disk `evictionRequested` once all replicas drain.** The GPU node was supposed to stay excluded from storage but was re-enabled implicitly during the incident — re-disable manually if that's not desired.
- **Watch the FULL output of restore scripts**, not just the tail. False-failure reports happened because a `tail -5` was missing the success line that appeared earlier in the playbook output.
- **External-dns failures are batch-wide.** A single conflicting record (or any other 500 from the provider webhook) stalls reconciliation for ALL records. Check for stale manual DNS records before deploying a new app with the external-dns annotation.
- **Backup-source asymmetry: the latest backup isn't always best.** Several apps' May 14/15/16 backups were captured during the cluster's broken state, so they had little or no data. The May 10/11 backups (pre-incident) were the good ones. The restore script should ideally surface backup-size trends so a sudden drop is obvious.
- **Etcd quorum: never run 2 control plane nodes.** 1 CP = no HA but quorum=1 always. 3 CP = tolerates 1 failure. 2 CP = WORSE than 1 CP (need 2/2 = 100% available).

## Remaining Work (Open TODO)

1. ✅ Identified hardware root cause (failing SSD `/dev/sdf` serial `X00041`; DIMM CE errors on Skt1/Ch1)
2. ✅ ALL VM disks migrated off `flash` pool → `tank` pool
3. ✅ Cluster brought back online: 145 pods Running, all apps reachable, DNS working
4. ✅ jellyfin running on GPU node from existing 70 GB volume (no restore needed)
5. ✅ linkding/plex restored with `LimitRange` workaround
6. 🔲 Identify physical drive bay for SSD `X00041` before host downtime (visual inspection of serial sticker on bay; or `dd if=/dev/sdf of=/dev/null bs=1M count=10000 &` to blink its activity LED)
7. 🔲 Cleanly remove worker-3 from cluster (`kubectl drain`, `kubectl delete node`, delete Longhorn node CR, delete VM in Proxmox)
8. 🔲 Decide CP topology — **DO NOT run 2 CP nodes**. Stay at 3, or go to 1
9. 🔲 Host downtime: clean shutdown all VMs (NOT hard-stop), pull bad SSD, rebuild flash as 2-drive mirror, memtest the DIMM (socket 1, channel 1), recreate pool
10. 🔲 Rebuild worker-1 + worker-2 VMs from clean templates (FS corruption from hard-stop still possible)
11. 🔲 After mirror is up: migrate VMs back from tank → new flash mirror, gradually un-throttle Longhorn
12. 🔲 Restore plex-config-pvc deferred volumes if any new issues; retry jellyfin-config restore if needed (already up via existing volume)
13. 🔲 Code fixes for `scripts/restore-app.sh` + `ansible/roles/k3s/files/discover-backups.py` + playbook (Issues 7, 8, 9, 14)
14. 🔲 Long-term:
   - Longhorn version upgrade (v1.12.x for V2 SPDK / tgtd improvements)
   - Root-disk usage alerting (prevent recurrence of original 100% fill)
   - Weekly ZFS scrubs (catch silent data errors early)
   - SMART monitoring alerts (smartd or Prometheus node-exporter SMART collector)
   - Proxmox host MCE alerts (mcelog or rasdaemon)
   - StorageClass `numberOfReplicas: 3` vs `default-replica-count: 2` mismatch — pick one source of truth

## Volumes Restored During Incident (for reference)

| App | Backup Date | Size | Notes |
|-----|-------------|------|-------|
| paperless (5 PVCs) | May 7-8 (before May 9 cutoff) | 1.95 GB + 336 MB + 242 MB + 418 MB + 152 MB | All clean |
| change-detection | May 10 | 196 MB | Latest May 15 was faulty per user |
| grafana | May 15 | 552 MB | |
| immich-db | May 15 | 1.55 GB | |
| immich-model-cache | May 15 | 1.24 GB | |
| YAMS (10 PVCs) | May 15-16 | various | Script reported false failures but actually succeeded |
| tracearr-data (jellyfin ns) | May 11 | 376 MB | |
| gatus | May 9 | 90 MB | Recent May 16 backup was empty/small |
| linkding | May 15 | 88 MiB | Required `LimitRange` workaround to bind |
| plex | May 11 | 28 GB | Required `LimitRange`-like sizing workaround due to ArgoCD race |
| jellyfin-config | (not restored) | n/a | Existing 70 GB volume reused (had survived the incident) |
