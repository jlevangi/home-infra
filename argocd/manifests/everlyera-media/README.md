# Everly Era — shared media namespace

One MinIO and one imgproxy serving the Everly Era website.

| Resource | Consumer |
| --- | --- |
| bucket `everlyera-media` | namespace `everlyera` (production) |
| bucket `everlyera-media-stage` | namespace `everlyera-stage` (dormant, scaled to 0) |
| `everlyera-imgproxy:8080` | both |

**Two buckets, not one.** Payload's `s3Storage` plugin deletes the S3 object when the
media document is deleted, so a shared bucket would let a stage cleanup delete a live
production image. Isolation comes from each environment's `S3_BUCKET`; one S3 identity is
granted access to both.

`base/external-secret.yaml` reads the MinIO, S3, and imgproxy material directly from
`kv/prod/everlyera`, deliberately: the `IMGPROXY_KEY`/`IMGPROXY_SALT` and
`S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY` here must stay byte-identical to what the web pods
sign and upload with. A duplicated copy that drifted would invalidate every published signed
`/img/*` URL with no error until a browser got a 403.

## Buckets, user, and policy

Buckets, the S3 user, and the `everlyera-media` policy live on the MinIO PVC. There is no
bootstrap Job (its pinned `minio/mc` image was pulled upstream). After restoring MinIO onto
an empty volume, recreate them once by hand with `mc` (`mc mb`, `mc admin user add`, then
`mc admin policy create` + `attach`) using the policy JSON from
`base/configmap-minio-policy.yaml`.

## Validation

```bash
kubectl kustomize argocd/manifests/everlyera-media/overlays/prod
```
