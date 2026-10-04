# Minio image provenance

Production uses `ghcr.io/jlevangi/home-infra-minio:RELEASE.2025-10-15T17-29-55Z`, pinned by digest in the Deployment.

Upstream release: https://github.com/minio/minio/releases/tag/RELEASE.2025-10-15T17-29-55Z
Source commit: `9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a`.

Upstream Docker Hub images and binary downloads are unavailable. Build the unmodified AGPL source; preserve LICENSE. The registry is private and uses the existing Vault-backed Everly Era pull credential.

```bash
git clone --depth=1 --branch RELEASE.2025-10-15T17-29-55Z https://github.com/minio/minio.git /tmp/minio-source
docker build -f argocd/manifests/everlyera-media/minio-build/Dockerfile -t ghcr.io/jlevangi/home-infra-minio:RELEASE.2025-10-15T17-29-55Z /tmp/minio-source
docker run --rm ghcr.io/jlevangi/home-infra-minio:RELEASE.2025-10-15T17-29-55Z --version
docker push ghcr.io/jlevangi/home-infra-minio:RELEASE.2025-10-15T17-29-55Z
```

Record the resulting digest before any rollout. Verify pull credentials with a disposable `--version` pod before replacing the stateful service. Keep a completed data backup and the previous image for rollback. Do not blindly downgrade after writing data with a newer release.
