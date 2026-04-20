# Vault And External Secrets

Use this document when Vault or External Secrets Operator bootstrap needs to be verified, re-run, or repaired. Most of the workflow is automated during cluster provisioning.

This guide bootstraps HashiCorp Vault (in-cluster) with Kubernetes auth and External Secrets Operator (ESO).

Most of the setup is automated during cluster provisioning via Ansible (Vault init/unseal, auth config, and seeding app secrets). Manual steps are only needed if the automation is disabled or fails.

## Assumptions
- Vault is deployed via ArgoCD `vault` Application (namespace: `vault`).
- ESO is deployed via ArgoCD `external-secrets` Application (namespace: `external-secrets`).
- ClusterSecretStore is applied via ArgoCD `external-secrets-config` Application.
- Vault is running in dev/test mode for internal-only use (TLS disabled in chart values).

## Current Automated Behavior

When `k3s_configure_vault: true`, the Ansible Vault role bootstraps:

- Vault init and unseal
- Kubernetes auth configuration
- the External Secrets policy and role
- seed secrets from Ansible Vault values

The automation stores the Vault root token and unseal keys in the `vault-init` secret in the `vault` namespace. Treat that secret as highly sensitive.

## ESO Version Rollout

Stage and test track the newer External Secrets Operator chart first. The `external-secrets` ArgoCD Application for those environments uses `targetRevision: 0.20.4` with `ServerSideApply=true`, and their manifests render `external-secrets.io/v1` custom resources.

Production intentionally remains on ESO `0.10.5` until the stage rollout is verified. Prod overlays patch `ClusterSecretStore` and `ExternalSecret` resources back to `external-secrets.io/v1beta1` so pushing shared `v1` base manifests does not change prod's ESO behavior.

To upgrade prod after stage is healthy:

1. Confirm `external-secrets` and `external-secrets-config` are synced and healthy in stage.
2. Confirm each stage `ExternalSecret` has `Ready=True` and the generated Kubernetes `Secret` objects were refreshed.
3. Change `argocd/apps/prod/external-secrets.yaml` to `targetRevision: 0.20.4`, add `namespaceOverride: external-secrets` to the Helm values, and add `ServerSideApply=true` under `syncOptions`.
4. Remove the prod `apiVersion: external-secrets.io/v1beta1` patches from the prod overlays.
5. Sync prod `external-secrets` first, then `external-secrets-config`, then the app manifests that contain `ExternalSecret` resources.

## 1) Deploy Vault + ESO

Switch to the target cluster and let ArgoCD sync:

```bash
./scripts/helpers/k3s-context-manager.sh switch test
```

Then sync the new ArgoCD apps via the ArgoCD UI or CLI.

## 2) Manual init/unseal (only if automation is disabled or failed)
Get the Vault pod name:

```bash
kubectl -n vault get pods
```

Initialize Vault (this outputs unseal keys + root token):

```bash
kubectl -n vault exec -it vault-0 -- vault operator init
```

Unseal Vault (run 3 times with different unseal keys):

```bash
kubectl -n vault exec -it vault-0 -- vault operator unseal
```

Login with the root token:

```bash
kubectl -n vault exec -it vault-0 -- vault login
```

## 3) Enable KV v2 secrets engine

```bash
kubectl -n vault exec -it vault-0 -- vault secrets enable -path=kv kv-v2
```

## 4) Enable Kubernetes auth for ESO

```bash
kubectl -n vault exec -it vault-0 -- vault auth enable kubernetes
```

Configure Kubernetes auth in Vault:

```bash
kubectl -n vault exec -it vault-0 -- sh -c '
  vault write auth/kubernetes/config \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
'
```

Create a policy for ESO:

```bash
kubectl -n vault exec -it vault-0 -- vault policy write external-secrets - <<'POLICY'
path "kv/data/prod/*" {
  capabilities = ["read"]
}
path "kv/data/stage/*" {
  capabilities = ["read"]
}
path "kv/data/test/*" {
  capabilities = ["read"]
}
POLICY
```

Create the Kubernetes auth role for ESO:

```bash
kubectl -n vault exec -it vault-0 -- vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h
```

## 5) Populate app secrets in Vault
Map the existing Ansible vault values into Vault KV:

```bash
# Vaultwarden
kubectl -n vault exec -it vault-0 -- vault kv put kv/test/vaultwarden \
  ADMIN_TOKEN='YOUR_ARGON2_HASH' \
  SMTP_HOST='smtp.example.com' \
  SMTP_USERNAME='smtp-user' \
  SMTP_PASSWORD='smtp-pass'

# Bookstack
kubectl -n vault exec -it vault-0 -- vault kv put kv/test/bookstack \
  DB_PASS='your-db-pass' \
  MYSQL_ROOT_PASSWORD='your-root-pass' \
  MYSQL_PASSWORD='your-db-pass' \
  APP_KEY='base64:your-app-key'

# PocketID
kubectl -n vault exec -it vault-0 -- vault kv put kv/test/pocketid \
  encryption-key='your-pocketid-key'
```

Repeat for `stage` and `prod` paths as needed.

## 6) Verify ESO sync

```bash
kubectl -n vaultwarden get externalsecrets,secrets
kubectl -n bookstack get externalsecrets,secrets
kubectl -n pocketid get externalsecrets,secrets
```

You should see Secrets created with the expected names:
- `vaultwarden-secrets`
- `bookstack-secrets`
- `pocketid-secret`

## Related Docs

- [GitOps And ArgoCD](../operations/gitops-and-argocd.md)
- [Production Cutover Checklist](../recovery/production-cutover-checklist.md)
