# Jellyfin invite automation

Wizarr is the user-facing onboarding/landing page. Access control stays in Keycloak.

## Current flow

1. Create a normal Wizarr invite.
2. Invitee follows the Wizarr onboarding link/code.
3. Invitee submits their email and the same Wizarr invite code to the n8n webhook:
   `POST https://n8n.levangie.dev/webhook/jellyfin-invite`
4. n8n validates the code against the Wizarr API.
5. n8n searches Keycloak for the submitted email.
6. If the Keycloak user already exists, n8n adds them to `jellyfin-users`.
7. If the Keycloak user does not exist, n8n creates the account, adds it to `jellyfin-users`, and sends a Keycloak setup email with `VERIFY_EMAIL` + `UPDATE_PASSWORD` required actions.
8. The `jellyfin-users` group grants the realm role used by Jellyfin and Seerr/Jellyseerr access.

## Live components

- Keycloak client: `n8n-invite-automation`
- Keycloak target group: `jellyfin-users`
- Wizarr API key name: `n8n-invite-validation`
- n8n workflow: `Jellyfin Invite Code → Keycloak Access`
- n8n workflow ID: `jellyfinInviteCodeAccess`
- Vault path: `kv/prod/n8n`

## n8n environment variables

These are sourced from Vault through `argocd/manifests/n8n/base/external-secret.yaml` and wired into the n8n Deployment:

- `KEYCLOAK_INVITE_CLIENT_ID`
- `KEYCLOAK_INVITE_CLIENT_SECRET`
- `KEYCLOAK_INVITE_GROUP_ID`
- `WIZARR_API_KEY`

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
  -d '{"email":"nobody@example.com","inviteCode":"<wizarr-code>"}'
```

Real test:

```bash
curl -sS -X POST https://n8n.levangie.dev/webhook/jellyfin-invite \
  -H 'Content-Type: application/json' \
  -d '{"email":"real-user@example.com","inviteCode":"<wizarr-code>"}'
```

Then verify the user group in Keycloak or by checking the user can sign into Jellyfin/Jellyseerr with Keycloak.

## Wizarr onboarding step

Wizarr has a DB-backed Jellyfin `pre_invite` wizard step named `Activate Jellyfin access with Keycloak`. It renders an inline form that POSTs email + invite code to `https://n8n.levangie.dev/webhook/jellyfin-invite` before the normal Wizarr invite flow consumes the code.

If testing with `curl -L`, preserve cookies or Wizarr loses invite session state between `/j/<code>` and `/wizard/pre-wizard`:

```bash
curl -ksS -c /tmp/wizarr.cookies -b /tmp/wizarr.cookies -L \
  https://join.levangie.dev/j/<wizarr-code>
```

## Operational pitfall

n8n active workflows are loaded from the `workflow_history` row referenced by `workflow_entity.activeVersionId`. Updating only `workflow_entity.nodes` changes the draft but not the live active workflow. When repairing via SQL, update both the draft and the active history row, then restart n8n.

The n8n Code node sandbox does not expose `process` or `fetch`. Use `$env` for env vars and native HTTP Request nodes for Keycloak API calls.
