# Everly Era — shared media namespace

One MinIO and one imgproxy serving the Everly Era website (`everlyera` namespace).

| Resource | Consumer |
| --- | --- |
| bucket `everlyera-media` | namespace `everlyera` (production) |
| `everlyera-imgproxy:8080` | `everlyera` web pods (server-side `/img/*`) |

Payload's `s3Storage` plugin deletes the S3 object when the media document is deleted, so
any future second environment must use its own bucket via `S3_BUCKET`, never share this one.

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
