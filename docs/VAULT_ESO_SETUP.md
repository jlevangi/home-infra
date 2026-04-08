# Vault + External Secrets Operator (ESO) Setup

This guide bootstraps HashiCorp Vault (in-cluster) with Kubernetes auth and External Secrets Operator (ESO).

Most of the setup is automated during cluster provisioning via Ansible (Vault init/unseal, auth config, and seeding app secrets). Manual steps are only needed if the automation is disabled or fails.

## Assumptions
- Vault is deployed via ArgoCD `vault` Application (namespace: `vault`).
- ESO is deployed via ArgoCD `external-secrets` Application (namespace: `external-secrets`).
- ClusterSecretStore is applied via ArgoCD `external-secrets-config` Application.
- Vault is running in dev/test mode for internal-only use (TLS disabled in chart values).

## 1) Deploy Vault + ESO (test cluster)
Switch to the test cluster and let ArgoCD sync:

```bash
./scripts/helpers/k3s-context-manager.sh switch test
```

Then sync the new ArgoCD apps via the ArgoCD UI or CLI.

If `k3s_configure_vault: true` (default), Ansible will automatically:
- Initialize and unseal Vault
- Enable KV v2 and Kubernetes auth
- Create the ESO policy and role
- Seed app secrets from Ansible Vault values

The automation stores the Vault root token and unseal keys in the `vault-init` Secret in the `vault` namespace for future unseals. Treat this Secret as highly sensitive.

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
