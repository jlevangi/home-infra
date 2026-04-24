## Immich

- Production hosts: `photos.levangie.org`, `immich.levangie.org`
- Vault path: `prod/immich`
- Persistent data:
  - Postgres on Longhorn (`immich-db-pvc`)
  - Machine learning cache on Longhorn (`immich-model-cache-pvc`)
  - Media library on shared NFS (`172.20.20.5:/volume1/media/immich`)

The source Docker host keeps the photo library on NFS already, so the migration only moves the database and runtime workloads into Kubernetes.
