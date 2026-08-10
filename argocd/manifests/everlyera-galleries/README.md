# Everly Era client galleries

Dedicated Immich delivery pilot for Everly Era Photography LLC.

- Host: `gallery.everlyera.com`
- Namespace: `everlyera-galleries`
- Vault path: `prod/everlyera-galleries` (`DB_PASSWORD`)
- Database: PostgreSQL on backed-up Longhorn storage
- Cache: Immich machine-learning cache on `longhorn-flash`
- Immich-managed files: NFS `/volume1/everlyera/Client_Galleries/Immich_Data`
- External library: NFS `/volume1/everlyera/Client_Galleries/Library`, mounted read-only at `/mnt/client-library`

The instance shares no database, Redis, cache, credentials, library, or admin users with the personal `immich` deployment.

## First boot

1. Confirm `prod/everlyera-galleries` exists in Vault with a random `DB_PASSWORD`.
2. Confirm both NAS paths are reachable from the cluster.
3. Sync the Argo application and create the first Immich admin at `gallery.everlyera.com`.
4. In Immich, create an external library owned by Mariah and add `/mnt/client-library`.
5. Keep automatic watching disabled for NFS; configure a periodic external-library scan.
6. For each pilot delivery, copy final JPEGs under `Client_Galleries/Library/<gallery>/`, scan, create an album, and issue a password-protected expiring link.

Do not mount the whole Everly Era archive into this namespace. Do not treat Immich-only album metadata as archival metadata: moving an external file causes Immich to treat it as a new asset.
