# Everly Era

GitOps source for the Everly Era photography site.

## Environments

| Environment | Namespace | Host | Vault path | Image policy |
| --- | --- | --- | --- | --- |
| Stage | `everlyera-stage` | `staging.everlyera.com` | `prod/everlyera` (shared with prod for now) | immutable `main-<sha>` candidate |
| Prod | `everlyera` | `everlyera.com`, `www.everlyera.com` | `prod/everlyera` | immutable release tag before launch |

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
