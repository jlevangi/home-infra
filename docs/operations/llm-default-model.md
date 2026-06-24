# LLM Default Model

Use this runbook when changing the in-cluster LLM model that automation
clients should use by default.

## Model Identity

Keep llama-swap model IDs honest. The model key and `--alias` in
`argocd/manifests/llama-cpp/base/config.yaml` should be the real model name,
for example `MiniMax-M2.7-UD-Q4_K_M`.

Do not rename the llama-swap model to a generic value such as `current_model`.
That hides the actual model in `/running`, logs, Prometheus labels, and
Grafana dashboards.

## Default Model For Automation Clients

Automation clients should read their default model from their own environment
instead of hardcoding a backend model name.

For n8n, the source of truth is:

- `argocd/manifests/n8n/base/configmap.yaml`
- key: `LLM_DEFAULT_MODEL`

n8n workflows that call the OpenAI-compatible llama-swap endpoint should use:

```js
model: $env.LLM_DEFAULT_MODEL
```

The n8n deployment already sets `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"`, so
workflow expressions can read `$env.LLM_DEFAULT_MODEL`.

## Changing The Default Model

1. Update `argocd/manifests/llama-cpp/base/config.yaml`.
   - Keep the real model name as the YAML key.
   - Keep `--alias` set to the same real model name.
   - Set `hooks.on_startup.preload` to that real model name.
   - Leave no `ttl` on the hot-loaded model so it inherits `globalTTL: 0`.

2. Update `argocd/manifests/n8n/base/configmap.yaml`.
   - Set `LLM_DEFAULT_MODEL` to the same real model name.

3. Commit and push the manifest changes.

4. Let ArgoCD reconcile `llama-cpp` and `n8n`.

5. Restart n8n if the ConfigMap change does not roll the pod immediately:

```bash
kubectl rollout restart deployment/n8n -n n8n
kubectl rollout status deployment/n8n -n n8n --timeout=300s
```

## Verification

Confirm ArgoCD is on the expected revision:

```bash
kubectl get application root-prod llama-cpp n8n -n argocd -o wide
```

Confirm n8n sees the default model:

```bash
kubectl exec -n n8n deploy/n8n -- printenv LLM_DEFAULT_MODEL
```

Confirm llama-swap reports the real loaded model name:

```bash
kubectl exec -n llama-cpp deploy/llama-cpp -c llama-swap -- \
  curl -sS http://127.0.0.1:8080/running
```

The `model` field should be the real model name, not `current_model`.

Confirm n8n workflows no longer hardcode old model names:

```bash
kubectl exec -i -n n8n deploy/n8n-postgres -- sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off' <<'SQL'
SELECT count(*) AS env_model_workflows
FROM workflow_entity
WHERE nodes::text LIKE '%model:$env.LLM_DEFAULT_MODEL%';

SELECT count(*) AS old_minimax_workflows
FROM workflow_entity
WHERE nodes::text LIKE '%MiniMax-M2.7-UD-Q4_K_M%';
SQL
```

## Current n8n Workflows

These active workflows are expected to use `$env.LLM_DEFAULT_MODEL`:

- `Alertmanager -> LLM -> ntfy` (processes **both warning and critical** alerts since 2026-06-24)
- `Changedetection -> LLM gate -> ntfy`
- `Paperless -> LLM classify -> rename + bill alert`

Paperless itself does not currently store a direct LLM model setting in its
Kubernetes manifests or application tables. Its LLM path is mediated through
the n8n Paperless workflow above.
