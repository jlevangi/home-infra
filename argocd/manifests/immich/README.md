## Immich

- Production hosts: `photos.levangie.org`, `immich.levangie.org`
- Vault path: `prod/immich` — keys: `DB_PASSWORD`, `IMMICH_API_KEY`
- Persistent data:
  - Postgres on Longhorn (`immich-db-pvc`)
  - Machine learning cache on Longhorn (`immich-model-cache-pvc`)
  - Power Tools runtime data on Longhorn (`immich-power-tools-data-pvc`)
  - Media library on shared NFS (`172.20.20.5:/volume1/media/immich`)

The source Docker host keeps the photo library on NFS already, so the migration only moves the database and runtime workloads into Kubernetes.

### Immich Power Tools

- Host: `immich-tools.levangie.dev`
- Talks to the Immich server in-cluster (`http://immich-server:2283`) and shares the Immich Postgres instance (`immich-postgres:5432`, db `immich`).
- Requires `IMMICH_API_KEY` in Vault at `prod/immich`. Generate one in the Immich UI under Account Settings → API Keys, then:
  ```
  vault kv patch kv/prod/immich IMMICH_API_KEY=<value>
  ```
  ESO will sync it into the `immich-secrets` Secret on the next refresh (default 1h; force with `kubectl annotate externalsecret immich-secrets -n immich force-sync=$(date +%s) --overwrite`).
