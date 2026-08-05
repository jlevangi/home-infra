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

## Status: not yet deployed

`argocd-application.yaml` in this directory is **inert** — `root-prod` syncs
`argocd/apps/prod` only. Two prerequisites must clear first.

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

### Activate

```bash
git mv argocd/manifests/everlyera-media/argocd-application.yaml \
       argocd/apps/prod/everlyera-media.yaml
git commit -m "feat(everlyera): activate shared everlyera-media namespace" && git push
```

## Not covered here

Repointing `everlyera` / `everlyera-stage` at this MinIO and imgproxy, and removing the
per-namespace stacks, is a separate change. Nothing in this directory modifies
`argocd/manifests/everlyera/`.

## Validation

```bash
kubectl kustomize argocd/manifests/everlyera-media/overlays/prod
```
