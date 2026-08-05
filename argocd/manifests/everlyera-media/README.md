# Everly Era — shared media namespace

One MinIO, one imgproxy, one FileBrowser, serving both Everly Era environments.

| Resource | Consumer |
| --- | --- |
| bucket `everlyera-media` | namespace `everlyera` (production) |
| bucket `everlyera-media-stage` | namespace `everlyera-stage` |
| `everlyera-imgproxy:8080` | both |
| FileBrowser `files.everlyera.com` | Mariah's raw-photography drop, not wired to Payload |

**Two buckets, not one.** Payload's `s3Storage` plugin deletes the S3 object when the
media document is deleted. Stage and prod have separate Postgres databases, so a shared
bucket would let a stage cleanup silently delete a live production image. Two buckets in
one MinIO keep every operational benefit (one PVC, one imgproxy, one signing key) without
that hazard. Isolation comes from each environment's `S3_BUCKET`; a single S3 identity is
granted access to both.

## Status: deployed, FileBrowser held back

The rollout was **split**. MinIO + imgproxy + both buckets are live; the Application is
active at `argocd/apps/prod/everlyera-media.yaml`. Everything FileBrowser-related is
commented out of `base/kustomization.yaml` behind a `TODO(home-infra-c20)` block —
re-enabling is uncommenting seven lines, and no manifest was deleted.

| Component | State |
| --- | --- |
| MinIO + both buckets + bootstrap Job | live |
| imgproxy | live |
| `everlyera-media-secrets` ExternalSecret | live (reads `kv/prod/everlyera`) |
| FileBrowser Deployment/Service/PVC/ExternalSecret/ConfigMap | commented out |
| `ingress.yaml`, `middleware-redirect.yaml` | commented out — **must stay out** until DNS resolves |

The Ingress is the load-bearing exclusion. `files.everlyera.com` does not resolve, so a
live Ingress makes Traefik retry HTTP-01 against Let's Encrypt, which rate-limits failed
validations at 5 per hostname per hour. Protecting that budget is why the rollout was
split.

Three things must clear before uncommenting.

### 1. Vault path `kv/prod/everlyera-media`

Only FileBrowser's credentials live here. The shared MinIO/imgproxy material is read
directly from `kv/prod/everlyera` by `base/external-secret.yaml`, deliberately: the
`IMGPROXY_KEY`/`IMGPROXY_SALT` and `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY` in this
namespace must stay byte-identical to what the web pods sign and upload with. Duplicating
them would let the two copies drift, invalidating every already-published signed `/img/*`
URL with no error until a browser got a 403.

```bash
kubectl -n vault-raft exec -it vault-raft-0 -- vault kv put kv/prod/everlyera-media \
  FILEBROWSER_ADMIN_PASSWORD='<password for user mariah>' \
  FILEBROWSER_JWT_TOKEN_SECRET='<random>'
```

Generate values with `openssl rand -base64 24`. `FILEBROWSER_ADMIN_PASSWORD` is the
initial password for the `mariah` admin account (username set in `base/configmap.yaml`);
`FILEBROWSER_JWT_TOKEN_SECRET` pins session signing so logins survive pod restarts.

### 2. Public DNS for `files.everlyera.com`

`everlyera.com` is authoritative in the site's own Cloudflare account. The homelab
external-dns has `domainFilters: [levangie.dev, levangie.org]` and does **not** manage
this zone, so the ingress carries no external-dns annotation — same as the `everlyera`
and `everlyera-stage` ingresses. The record is created by hand:

```
files.everlyera.com    A    172.20.20.200    (DNS only / grey cloud)
```

Traefik's `letsencrypt` certresolver uses HTTP-01 and cannot issue until the name
resolves publicly and port 80 reaches `172.20.20.200`. Unlike `staging.everlyera.com`
(internal-only via the Technitium `everlyera.com` zone), this host is meant to be
reachable from outside the house, so it needs a real public record plus a WAN
80/443 path to the Traefik LB.

### 3. Keycloak OIDC rework

Pierce decided FileBrowser authenticates via Keycloak OIDC, matching
`cloud.levangie.dev`, not the local `adminUsername: mariah` / password auth currently in
`base/configmap.yaml`. That config must be reworked before the pod is worth starting —
which also means `FILEBROWSER_ADMIN_PASSWORD` above may become unnecessary.

### Re-enable FileBrowser

Once all three clear, uncomment the seven resource lines in the
`TODO(home-infra-c20)` block of `base/kustomization.yaml`, render to confirm the
Ingress and Middleware reappear, and let ArgoCD sync. Nothing else changes.

## Not covered here

Nothing in this directory modifies `argocd/manifests/everlyera/`. Repointing
`everlyera` / `everlyera-stage` at this MinIO and imgproxy, and removing their
per-namespace MinIO/imgproxy stacks, was done separately in those overlays.

## Validation

```bash
kubectl kustomize argocd/manifests/everlyera-media/overlays/prod
```
