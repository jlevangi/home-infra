# Calibre-Web (Calibre-Web-Automated)

Ebook library at <https://calibre.levangie.dev>, gated on the `calibre` Keycloak
realm role.

## Why the fork and not `janeczku/calibre-web`

Upstream Calibre-Web supports only GitHub and Google OAuth, and the maintainer
has declined to add generic OIDC ([janeczku/calibre-web#2965][1]). The only way
to put upstream behind Keycloak is an `oauth2-proxy` injecting a trusted
username header — and upstream's own docs warn that anything able to reach the
app directly can then log in as *any* user by setting that header, which inside
a cluster means every pod.

[Calibre-Web-Automated][2] is the same application with native generic OIDC, so
the gate is enforced by Keycloak itself. It also auto-converts ingested books to
EPUB, which is why PDFs land here as readable reflowable text.

[1]: https://github.com/janeczku/calibre-web/issues/2965
[2]: https://github.com/crocodilestick/Calibre-Web-Automated

## Storage

| Mount | Backing | Purpose |
|-------|---------|---------|
| `/config` | Longhorn PVC `calibre-web-config-pvc` (`longhorn-fast`, daily+weekly backup) | `app.db` — settings, users, **and the OIDC configuration** |
| `/calibre-library` | NFS `/volume1/media/calibre/library` | The Calibre library: `metadata.db` + book files |
| `/cwa-book-ingest` | NFS `/volume1/media/calibre/ingest` | Drop zone; **files here are deleted after import** |
| `/books-readonly` | NFS `/volume1/media/books` (read-only) | The pre-existing hand-organised tree, mounted so it can be copied from but never restructured or deleted |

`/volume1/media/books/metadata.db` is a 0-byte placeholder and is **not** a
Calibre library. The real library was created fresh at
`/volume1/media/calibre/library`; the original tree is untouched.

### Ingest behaviour

Drop a book into `/volume1/media/calibre/ingest` and it is imported, converted
to EPUB, and **removed from the ingest folder**. Always copy, never move, unless
you intend the source to disappear.

Writes made from another machine (SMB, another pod) are picked up — verified by
writing from a separate pod and watching it import. So dropping books on the NAS
share from a desktop works.

Conversion keeps only the target format: an ingested PDF becomes an EPUB and the
PDF is not retained in the library. Originals under `/media/books` still exist.

## Authentication

Keycloak realm `master` at `https://auth.levangie.org`, client `calibre-web`,
callback `https://calibre.levangie.dev/login/generic/authorized`.

Access requires the **`calibre` realm role**. This is enforced by the
`calibre-browser` authentication flow bound to the client via *Advanced →
Authentication flow overrides → browser*. Two structural rules matter, both
learned the hard way on the Komga client:

1. The conditional role gate must **not** sit at the top level beside Cookie /
   Identity Provider Redirector / forms. Keycloak ignores ALTERNATIVE executions
   in any flow that also contains a REQUIRED one, and a CONDITIONAL subflow whose
   condition matches behaves as REQUIRED — so a top-level gate suppresses every
   login branch and the request dies with HTTP 400 before a form is ever drawn.
   The auth branches are therefore nested in a REQUIRED wrapper subflow
   (`calibre-auth`), with `calibre-role-gate` CONDITIONAL after it at top level.
   That placement also makes the gate apply on the SSO-cookie path.
2. The `conditional-user-role` config keys are `condUserRole` and `negate` — not
   the dotted names. Wrong keys save with HTTP 201 and then silently evaluate
   false, letting everyone through.

The gate is `negate: true` — it fires, and denies, when the user lacks the role.

Verified end-to-end with a throwaway user: with the role an authorization code is
issued, without it Keycloak returns "Access denied". When testing this way, clear
the user's `VERIFY_EMAIL` and `VERIFY_PROFILE` required actions first (set
`emailVerified`, `firstName`, `lastName`), or the required-action redirect
happens before the gate and every result looks like a denial.

### OIDC settings are not in git

CWA configures OAuth in its admin UI, not from environment variables, so the
client ID, secret and discovery URL live in `app.db` on the config PVC — which is
why that PVC carries Longhorn backup labels. Losing it means re-entering the OIDC
configuration by hand. The credentials are mirrored to Vault at
`kv/prod/calibre-web` for exactly that case; nothing reads them via ESO.

Local username/password login remains enabled alongside OIDC as a deliberate
lockout fallback. The `admin` account's password is in Vault at
`kv/prod/calibre-web` under `LOCAL_ADMIN_PASSWORD` — the image ships with a
well-known default, so it must not be left as shipped on a routable host.

## Granting someone access

```bash
# add the realm role to a user in Keycloak; they can then log in and CWA
# creates the local account on first successful login
```

Admin rights inside CWA are separate from the Keycloak role and are set per-user
in *Admin → Users*.
