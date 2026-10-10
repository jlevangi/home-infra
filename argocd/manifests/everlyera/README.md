# Everly Era

GitOps source for the Everly Era photography site.

## Environments

| Environment | Namespace | Host | Vault path | Image policy |
| --- | --- | --- | --- | --- |
| Stage | `everlyera-stage` | `staging.everlyera.com` | `prod/everlyera` (shared with prod for now) | immutable `main-<sha>` candidate |
| Prod | `everlyera` | `everlyera.com`, `www.everlyera.com` | `prod/everlyera` | immutable release tag before launch |

> **2026-10-10:** the public production site runs on Cloudflare Workers, D1 and R2.
> `overlays/prod` sets only `everlyera-web` to zero replicas; PostgreSQL and PVCs remain
> intact for rollback. Restore the website by removing that replica patch and syncing
> only `Deployment/everlyera-web`, then restore DNS if reverting the public cutover.
> k3s staging is also dormant; galleries and shared media are separate active applications.

## DNS (split-horizon)

- `everlyera.com` is authoritative in the site's own Cloudflare account (separate from homelab Technitium/DYNU). Public records are managed there; the homelab external-dns (Technitium webhook) does NOT manage this zone.
- Internal resolution uses a `everlyera.com` Primary zone in Technitium, member of the `cluster-catalog.levangie.org` catalog, created 2026-08-04.
- `staging.everlyera.com` → `172.20.20.200` (k3s-prod Traefik LB), internal-only. No public record.
- The zone is authoritative: missing records do not fall through. Internal apex/www A
  records now point to Cloudflare edges (`104.21.82.110`, `172.67.200.172`, TTL 300).
  `gallery` stays at `172.20.20.200`. Refresh edge overrides if public DNS answers change.

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
