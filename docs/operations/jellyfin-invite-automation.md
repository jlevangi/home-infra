# Jellyfin invite automation

Wizarr is the user-facing onboarding/landing page. Access control stays in Keycloak.

## Current flow

1. Invitee creates a Keycloak account at `https://auth.levangie.org`.
2. Invitee submits their email and invite code to the n8n webhook:
   `POST https://n8n.levangie.dev/webhook/jellyfin-invite`
3. n8n validates the invite code from `JELLYFIN_INVITE_CODES`.
4. n8n finds the existing Keycloak user by email.
5. n8n adds the user to the Keycloak group `jellyfin-users`.
6. The `jellyfin-users` group grants the realm role used by Jellyfin and Seerr/Jellyseerr access.

## Live components

- Keycloak client: `n8n-invite-automation`
- Keycloak target group: `jellyfin-users`
- n8n workflow: `Jellyfin Invite Code → Keycloak Access`
- n8n workflow ID: `jellyfinInviteCodeAccess`
- Vault path: `kv/prod/n8n`

## n8n environment variables

These are sourced from Vault through `argocd/manifests/n8n/base/external-secret.yaml` and wired into the n8n Deployment:

- `KEYCLOAK_INVITE_CLIENT_ID`
- `KEYCLOAK_INVITE_CLIENT_SECRET`
- `KEYCLOAK_INVITE_GROUP_ID`
- `JELLYFIN_INVITE_CODES`

## Test commands

Invalid code should return 403-style JSON:

```bash
curl -sS -X POST https://n8n.levangie.dev/webhook/jellyfin-invite \
  -H 'Content-Type: application/json' \
  -d '{"email":"nobody@example.com","inviteCode":"bad"}'
```

Valid code but missing account should return a “create account first” message:

```bash
curl -sS -X POST https://n8n.levangie.dev/webhook/jellyfin-invite \
  -H 'Content-Type: application/json' \
  -d '{"email":"nobody@example.com","inviteCode":"<invite-code>"}'
```

Real test:

```bash
curl -sS -X POST https://n8n.levangie.dev/webhook/jellyfin-invite \
  -H 'Content-Type: application/json' \
  -d '{"email":"real-user@example.com","inviteCode":"<invite-code>"}'
```

Then verify the user group in Keycloak or by checking the user can sign into Jellyfin/Jellyseerr with Keycloak.

## Operational pitfall

n8n active workflows are loaded from the `workflow_history` row referenced by `workflow_entity.activeVersionId`. Updating only `workflow_entity.nodes` changes the draft but not the live active workflow. When repairing via SQL, update both the draft and the active history row, then restart n8n.

The n8n Code node sandbox does not expose `process` or `fetch`. Use `$env` for env vars and native HTTP Request nodes for Keycloak API calls.
