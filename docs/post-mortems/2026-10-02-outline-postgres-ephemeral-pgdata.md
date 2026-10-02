# 2026-10-02 — Outline data loss: Postgres data was never on its PVC

## Summary
Outline's Postgres container had no `volumeMounts`. Only the `outline-init`
init container mounted `outline-db-pvc` (to create `pgdata`). Postgres wrote
PGDATA to the container's writable layer from initial deployment (2026-09-24,
`75c21f49`) onward. Scaling Outline to 0 during the flash right-size migration
destroyed the layer and with it all documents and collections.

## Detection
`rightsize.py` copied `outline-db-pvc` and reported 24KB, while the running pod
had shown ~70MB. The migration was halted, and Outline and `root-prod` were paused.

## Why backups did not help
- All 16 Longhorn backups (hourly/daily/weekly, 09-26 to 10-02) were of an
  empty filesystem. Backup jobs reported success throughout.
- A raw block-device scan of the source volume found no Postgres table names.
- Node VM 107 has no PBS backup. There was no `pg_dump` job. The containerd
  snapshot was gone after the pod was deleted.

## Resolution
- `d934a1dd`: mount `db-data` at `/var/lib/postgresql/data` in the `postgres`
  container. Outline redeployed empty. Verified PGDATA is on
  `/dev/longhorn/pvc-48ecf8c3-...` and 45 tables were created.
- Manual Longhorn backups were taken of the 8 PVCs recreated by the migration
  (all `Completed`, non-trivial sizes).

## Cluster audit (no other app affected)
- No running pod has a PVC mounted only by init containers.
- Known data directories on the container overlay filesystem: none hold live
  data. Checked tracearr (PGDATA `/data/postgres` on PVC; `/var/lib/postgresql`
  is the image's initdb leftover) and tautulli (`/app/data` holds image assets;
  state is in `/config` on PVC).
- Largest writable layers (plex, whisparr, calibre-web, alist, wallos, termix)
  had no recently modified data files outside PVC mounts.
- Non-exec containers (distroless) were reviewed by manifest. Stateful ones
  (gatus, notemark, surrealdb, rustdesk, vikunja) mount their data paths from PVCs.

## Lessons
1. "Backup completed" does not mean "backup has the data". Restore-test content.
2. Before stopping a workload for storage work, compare in-pod usage of the
   data path with the PVC's filesystem. `rightsize.py` now aborts if any PVC
   volume is not mounted by a main container.
3. Databases need a logical dump independent of block backups.

Follow-up: `home-infra-tbhc` (nightly pg_dump + Healthchecks, periodic
restore-test, manifest lint for init-only PVC mounts).
