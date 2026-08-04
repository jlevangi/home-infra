# Everly Era

GitOps source for the Everly Era photography site.

## Environments

| Environment | Namespace | Host | Vault path | Image policy |
| --- | --- | --- | --- | --- |
| Stage | `everlyera-stage` | `staging.everlyera.com` | `prod/everlyera` (shared with prod for now) | immutable `main-<sha>` candidate |
| Prod | `everlyera` | `everlyera.com`, `www.everlyera.com` | `prod/everlyera` | immutable release tag before launch |

> **2026-08-04 status**: the stage cluster (172.20.21.111-114) is offline. Until it returns, both the
> staging site (`everlyera-stage` ns) and the primary site (`everlyera` ns) run **on k3s-prod** from the
> `main` branch, deployed via `argocd/apps/prod/everlyera-stage.yaml` and `argocd/apps/prod/everlyera.yaml`.
> They share Vault `prod/everlyera`. The `stage` branch / `argocd/apps/stage` flow resumes when the stage
> cluster is back online.

## DNS (split-horizon)

- `everlyera.com` is authoritative in the site's own Cloudflare account (separate from homelab Technitium/DYNU). Public records are managed there; the homelab external-dns (Technitium webhook) does NOT manage this zone.
- Internal resolution uses a `everlyera.com` Primary zone in Technitium, member of the `cluster-catalog.levangie.org` catalog, created 2026-08-04.
- `staging.everlyera.com` → `172.20.20.200` (k3s-prod Traefik LB), internal-only. No public record.
- The `everlyera.com` zone is unsigned; unknown records fall through to public resolvers (Cloudflare).

The site source and image workflow live in `jlevangi/everlyera.com`. This directory owns Kubernetes desired state.

## Required Vault keys

- `PAYLOAD_SECRET`
- `POSTGRES_PASSWORD`
- `DATABASE_URI` — complete URL-encoded PostgreSQL URI
- `MINIO_ROOT_USER`
- `MINIO_ROOT_PASSWORD`
- `S3_ACCESS_KEY_ID`
- `S3_SECRET_ACCESS_KEY`
- `IMGPROXY_KEY`
- `IMGPROXY_SALT`
- `GHCR_DOCKER_CONFIG_JSON` — Docker config JSON for private `ghcr.io/jlevangi/everlyera` pulls

The MinIO bootstrap hook creates the `everlyera-media` bucket and grants the S3 application identity bucket-scoped object access. MinIO root credentials are not used by the web or imgproxy Deployments.

## Validation

```bash
kubectl kustomize argocd/manifests/everlyera/overlays/stage
kubectl kustomize argocd/manifests/everlyera/overlays/prod
```

No ArgoCD Application is included yet. Adding `argocd/apps/stage/everlyera.yaml` is the separate approval gate that creates live staging resources. Production requires a fresh explicit approval and a release image tag.
