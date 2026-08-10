# Everly Era client galleries

Dedicated Immich delivery pilot for Everly Era Photography LLC.

- Host: `gallery.everlyera.com`
- Namespace: `everlyera-galleries`
- Vault path: `prod/everlyera-galleries` (`DB_PASSWORD`)
- OIDC/break-glass Vault path: `prod/everlyera-gallery-oidc`
- Database: PostgreSQL on backed-up Longhorn storage
- Cache: Immich machine-learning cache on `longhorn-flash`
- Immich-managed files: NFS `/volume1/everlyera/Client_Galleries/Immich_Data`
- External library: NFS `/volume1/everlyera/Client_Galleries/Library`, mounted read-only at `/mnt/client-library`

The instance shares no database, Redis, cache, credentials, library, or admin users with the personal `immich` deployment.

## Authentication

- Keycloak issuer: `https://auth.levangie.org/realms/master`
- Confidential client: `everlyera-gallery`
- Redirect URIs: `/auth/login`, `/user-settings`, and the Immich mobile callback
- Keycloak `everlyera-admin` members are assigned the client role `admin`.
- The client-role mapper emits `immich_role=admin`, which Immich maps through its `immich_role` role claim.
- Immich auto-registration is disabled. Create the matching Immich account before assigning gallery access.
- Password login remains enabled for break-glass recovery. Generated passwords and the OIDC client secret are stored only at `kv/prod/everlyera-gallery-oidc`.

Pierce (`pierce@levangie.org`) and Mariah (`random2mariah@gmail.com`) were pre-provisioned as Immich administrators. On their first Keycloak login, Immich links the existing account by matching email.

## Branding

Immich's supported custom CSS setting carries the Everly Era palette and typography without patching the container image or relying on version-specific DOM replacement:

- cream `#F6EFE4` and forest `#3C4A31` light theme
- forest-deep `#2C3724` dark ground
- warm ink `#2B2118` and taupe `#564B36` text
- Cormorant/Georgia headings and Inter/system interface text

Keep Immich controls and layout recognizable. Reapply or review the custom CSS after an Immich upgrade if its documented theme variables change.

## Pilot gallery

The first non-destructive pilot is `Liv — Graduation`:

- four byte-identical JPEG copies under `Client_Galleries/Library/Liv-Graduation-Test/`
- Mariah-owned external library at `/mnt/client-library/Liv-Graduation-Test`
- 30-day password-protected shared link
- downloads enabled, uploads disabled, and metadata hidden
- link and password stored only at `kv/prod/everlyera-gallery-liv-test`

Immich v3 forces downloads off when a link is initially created with metadata hidden. Create the link, then enable downloads through the supported shared-link update action and verify both flags afterward.

## First boot

1. Confirm `prod/everlyera-galleries` exists in Vault with a random `DB_PASSWORD`.
2. Confirm both NAS paths are reachable from the cluster.
3. Confirm both pre-provisioned administrators can complete Keycloak login and retain Immich admin access.
4. In Immich, create an external library owned by Mariah and add `/mnt/client-library`.
5. Keep automatic watching disabled for NFS; configure a periodic external-library scan.
6. For each pilot delivery, copy final JPEGs under `Client_Galleries/Library/<gallery>/`, scan, create an album, and issue a password-protected expiring link.

Do not mount the whole Everly Era archive into this namespace. Do not treat Immich-only album metadata as archival metadata: moving an external file causes Immich to treat it as a new asset.
