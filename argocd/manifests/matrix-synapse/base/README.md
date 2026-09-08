# Matrix Synapse

Production Synapse homeserver for `@user:matrix.levangie.dev` identities.

- Public client and federation endpoint: `https://matrix.levangie.dev`
- Authentication: Keycloak OIDC; open registration and Matrix passwords disabled
- Database: PostgreSQL on `longhorn-tank`, with hourly/daily/weekly backups
- Media and signing key state: `longhorn-redundant`, with daily/weekly backups
- No bundled web client, TURN server, or bridges

## Required Vault keys

Path: `kv/prod/matrix-synapse`

- `POSTGRES_PASSWORD`
- `OIDC_CLIENT_SECRET`
- `MACAROON_SECRET_KEY`
- `FORM_SECRET`
- `SIGNING_KEY`

`SIGNING_KEY` is the complete single-line Synapse signing-key file. Losing it breaks federation trust; it must remain on the backed-up Synapse data PVC and in Vault.

## Keycloak client

- Client ID: `matrix-synapse`
- Confidential authorization-code flow
- Redirect URI: `https://matrix.levangie.dev/_synapse/client/oidc/callback`
- Back-channel logout URL: `https://matrix.levangie.dev/_synapse/client/oidc/backchannel_logout`

After Pierce's first OIDC login, elevate that Matrix user to server admin with a controlled PostgreSQL update or Synapse Admin API call, then verify the admin flag. Do not enable password login solely for bootstrap.

## Restore warning

Longhorn backups are crash-consistent volume backups, not Synapse-aware PostgreSQL dumps. After restoring the database to an older point in time, truncate `e2e_one_time_keys_json` before starting Synapse so used one-time keys cannot be reissued. Never restore into a database that already contains tables. For stronger logical recovery, add a scheduled `pg_dump -Fc --exclude-table-data e2e_one_time_keys_json` workflow before treating this as a high-value communications archive.
