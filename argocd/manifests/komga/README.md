# Komga

Comics / manga / ebook server at `komga.levangie.dev`.

## Storage

| Mount | Source | Mode |
|-------|--------|------|
| `/config` | `komga-config-pvc` (Longhorn `longhorn-fast`, 10Gi) | rw |
| `/data/comics` | NFS `172.20.20.5:/volume1/media` subPath `comics` | rw |
| `/data/books` | NFS `172.20.20.5:/volume1/media` subPath `books` | **ro** |

`/volume1/media/books` predates Komga and holds an existing epub/Calibre tree,
so it is mounted read-only — Komga indexes it but cannot modify or delete it.
`comics` was created empty for Komga to own. Add the libraries in the Komga UI
pointing at `/data/comics` and `/data/books`.

The config volume holds Komga's database *and* its generated thumbnails, which
is why it is on flash and 10Gi rather than the ~1Gi most small apps get.

## Keycloak OIDC and the `komga` realm role

Access is gated by the **`komga` realm role**. This is enforced in Keycloak,
not in Komga: Komga has no group- or role-mapping of its own, it simply matches
OIDC users by email and would otherwise accept any account in the realm.

Enforcement is a client-scoped browser flow override — the only one in this
realm, so it is easy to miss when debugging a login:

```
client `komga` -> Advanced -> Authentication flow overrides -> browser: komga-browser

komga-browser (top level)
  komga-auth              REQUIRED       <- wrapper, see note below
    Cookie                ALTERNATIVE
    Identity Provider Redirector  ALTERNATIVE
    komga-forms           ALTERNATIVE
      Username Password Form      REQUIRED
      komga-otp           CONDITIONAL    (mirrors browser-passkeys)
  komga-role-gate         CONDITIONAL
    Condition - user role REQUIRED       (condUserRole=komga, negate=true)
    Deny access           REQUIRED
```

**The `komga-auth` wrapper is load-bearing.** Keycloak ignores ALTERNATIVE
executions in any flow that also contains a REQUIRED one, and a CONDITIONAL
subflow whose condition matches behaves as REQUIRED. Putting the role gate
directly at the top level alongside `Cookie` / `forms` therefore suppresses
every login branch and the flow dies with "Invalid username or password"
before a form is ever rendered. Nesting the auth branches one level down keeps
the top level free of ALTERNATIVEs.

The gate sits *after* `komga-auth`, so it applies on the SSO-cookie path too —
a user holding a session from another app is still denied without the role.

Granting access: Keycloak admin console -> Users -> *user* -> Role mapping ->
Assign role -> `komga`. Revoking it takes effect on the next authorization
request, including for users with a live SSO session.

Because the role gate is authoritative, `KOMGA_OAUTH2_ACCOUNT_CREATION=true` is
safe: only users who already passed the gate ever reach account creation.
New users land as regular users — promote to admin inside Komga.

## Secret

`OIDC_CLIENT_SECRET` comes from Vault `kv/prod/komga` via ESO. Rotating the
client secret in Keycloak means rewriting that Vault key.
