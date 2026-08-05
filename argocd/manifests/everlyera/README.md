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

`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` are no longer consumed in these two namespaces — they are read by the shared MinIO in `everlyera-media`. They stay in `prod/everlyera` because both namespaces use `dataFrom: extract` on the whole path and because the shared namespace's ExternalSecret sources them from here.

## Object storage and image proxy

MinIO and imgproxy are **not** deployed per namespace. Both environments consume the shared stack in the `everlyera-media` namespace (`argocd/manifests/everlyera-media/`) over cluster DNS:

| Key | Stage | Prod |
| --- | --- | --- |
| `S3_ENDPOINT` | `http://everlyera-minio.everlyera-media:9000` | same |
| `IMGPROXY_URL` | `http://everlyera-imgproxy.everlyera-media:8080` | same |
| `S3_BUCKET` | `everlyera-media-stage` | `everlyera-media` |

**The differing `S3_BUCKET` is load-bearing.** Payload's `s3Storage` plugin deletes the S3 object when a media document is deleted, and the two environments have separate Postgres databases, so a shared bucket would let a staging cleanup silently destroy a live production image. The stage value is set by a patch in `overlays/stage/kustomization.yaml`; the base default is the production bucket, so any new overlay must override it explicitly.

Postgres remains per-namespace by design — separate databases per environment.

## Validation

```bash
kubectl kustomize argocd/manifests/everlyera/overlays/stage
kubectl kustomize argocd/manifests/everlyera/overlays/prod
```

No ArgoCD Application is included yet. Adding `argocd/apps/stage/everlyera.yaml` is the separate approval gate that creates live staging resources. Production requires a fresh explicit approval and a release image tag.
