# Web Poker Images

These Dockerfiles build the upstream `alexander171294/web-poker` project into
four images that match the Kubernetes manifests under
`argocd/manifests/web-poker/`.

## Build Commands

```bash
docker build -f containers/web-poker/frontend/Dockerfile -t jlevangie/gamble-king:frontend-20260429-1 .
docker build -f containers/web-poker/backend/Dockerfile.api -t jlevangie/gamble-king:api-20260429-2 .
docker build -f containers/web-poker/backend/Dockerfile.orchestrator -t jlevangie/gamble-king:orchestrator-20260429-2 .
docker build -f containers/web-poker/backend/Dockerfile.room -t jlevangie/gamble-king:room-20260429-1 .
```

All four builds accept `--build-arg WEB_POKER_REF=<branch-or-tag>` and default
to `master`.

## Why The Overrides Exist

- The frontend is overridden to use same-origin API calls and hostname-based
  room websocket targets.
- The API server is overridden to support authenticated SMTP submission on port
  `587` with STARTTLS.
- The room server is overridden to advertise `poker.levangie.dev:443` instead
  of a raw pod or node IP.
