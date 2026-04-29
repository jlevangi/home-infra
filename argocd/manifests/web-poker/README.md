# Web Poker

ArgoCD app for the upstream `alexander171294/web-poker` stack, adapted for a
single public hostname at `https://poker.levangie.dev`.

## Public Routing

- `/` -> Angular frontend
- `/public` -> API server
- `/friends` -> API server
- `/users/profile` -> API server
- `/lobby/rooms` -> API server
- `/external` -> room websocket endpoint

## Required Vault Keys

Create `kv/prod/web-poker` with these keys before syncing:

- `DB_USER`
- `DB_PASSWORD`
- `DB_ROOT_PASSWORD`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USERNAME`
- `SMTP_PASSWORD`
- `SMTP_FROM`

`DB_NAME` and `JWT_SECRET` are intentionally not required by the current
manifest set because the upstream application hardcodes the database name
`poker` and signs JWTs with per-session passphrases stored in MySQL.

## Custom Images

The manifests expect these images to exist:

- `jlevangie/web-poker-frontend`
- `jlevangie/web-poker-api`
- `jlevangie/web-poker-orchestrator`
- `jlevangie/web-poker-room`

Build definitions live under `containers/web-poker/`.
