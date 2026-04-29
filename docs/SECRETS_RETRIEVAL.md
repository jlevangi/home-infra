# Secrets Retrieval Reference

Quick reference for retrieving credentials across all cluster services. Replace `{env}` with `prod`, `stage`, or `test` where applicable.

## Infrastructure Services

### Vault

```bash
# Root token
kubectl get secret vault-init -n vault-raft -o jsonpath='{.data.root-token}' | base64 -d; echo

# Unseal keys
kubectl get secret vault-init -n vault-raft -o json | jq -r '.data | to_entries[] | select(.key | startswith("unseal-key")) | "\(.key): \(.value | @base64d)"'
```

- **UI:** `https://vault.{domain}`
- **Login method:** Token (use root token above)

### ArgoCD

```bash
# Admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

- **UI:** `https://argocd.{domain}`
- **Username:** `admin`
- **Note:** Delete the initial admin secret after first login: `kubectl delete secret argocd-initial-admin-secret -n argocd`

### Grafana

```bash
# Credentials from Vault (via ExternalSecret)
kubectl get secret grafana-admin-credentials -n monitoring -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

- **UI:** `https://grafana.{domain}`
- **Vault path:** `kv/{env}/monitoring`
- **Vault keys:** `admin-user`, `admin-password`

### Longhorn

- **UI:** `https://longhorn.{domain}`
- **Auth:** No authentication (access controlled by network)

## Application Services

All application secrets are managed via Vault and synced by External Secrets Operator. Use the commands below to view the synced Kubernetes secrets, or access Vault directly.

### Bookstack

```bash
kubectl get secret bookstack-secrets -n bookstack -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

- **UI:** `https://bookstack.{domain}`
- **Vault path:** `kv/{env}/bookstack`
- **Vault keys:** `DB_PASS`, `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`, `APP_KEY`
- **Default login:** Bookstack default is `admin@admin.com` / `password` (change on first login)

### Vaultwarden

```bash
kubectl get secret vaultwarden-secrets -n vaultwarden -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

- **UI:** `https://vw.{domain}`
- **Admin panel:** `https://vw.{domain}/admin`
- **Vault path:** `kv/{env}/vaultwarden`
- **Vault keys:** `ADMIN_TOKEN`, `SMTP_HOST`, `SMTP_USERNAME`, `SMTP_PASSWORD`

### PocketID

```bash
kubectl get secret pocketid-secrets -n pocketid -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

- **UI:** `https://pocketid.{domain}`
- **Vault path:** `kv/{env}/pocketid`
- **Vault keys:** `encryption-key`

### Paperless

```bash
kubectl get secret paperless-secrets -n paperless -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

- **UI:** `https://paperless.{domain}`
- **Vault path:** `kv/{env}/paperless`
- **Vault keys:** `MARIADB_ROOT_PASSWORD`, `MARIADB_PASSWORD`, `PAPERLESS_SECRET_KEY`, `PAPERLESS_ADMIN_USER`, `PAPERLESS_ADMIN_PASSWORD`

### Microbin

```bash
kubectl get secret microbin-secrets -n microbin -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

- **UI:** `https://bin.{domain}`
- **Vault path:** `kv/{env}/microbin`
- **Vault keys:** `MICROBIN_ADMIN_USERNAME`, `MICROBIN_ADMIN_PASSWORD`

### Web Poker

```bash
kubectl get secret web-poker-secrets -n web-poker -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

- **UI:** `https://poker.{domain}`
- **Vault path:** `kv/{env}/web-poker`
- **Vault keys:** `DB_USER`, `DB_PASSWORD`, `DB_ROOT_PASSWORD`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`

## Monitoring Services

### Gatus

- **UI:** `https://status.{domain}`
- **Auth:** No authentication (public status page)

### Prometheus

- **Internal URL:** `http://prometheus-prometheus.monitoring.svc.cluster.local:9090`
- **Auth:** No authentication (not exposed externally)

## Environment Domains

| Environment | Domain | Example |
|-------------|--------|---------|
| Production | `levangie.dev` | `grafana.levangie.dev` |
| Staging | `stage.levangie.dev` | `grafana.stage.levangie.dev` |
| Test | `test.levangie.dev` | `grafana.test.levangie.dev` |

## Viewing All Vault Secrets

To list all secrets stored in Vault for an environment:

```bash
# Login to Vault first
export VAULT_ADDR="https://vault.{domain}"
vault login  # enter root token when prompted

# List all secret paths for an environment
vault kv list kv/{env}

# Read a specific secret
vault kv get kv/{env}/{app}
```

Or from within the cluster:

```bash
kubectl exec -n vault-raft vault-raft-0 -- vault kv list kv/{env}
kubectl exec -n vault-raft vault-raft-0 -- vault kv get kv/{env}/{app}
```

## Ansible Vault (Offline Secrets)

Some secrets are also stored in Ansible Vault files for cluster bootstrapping:

```bash
# View K3s secrets
ansible-vault view ansible/group_vars/k3s_cluster_vault.yml

# View LXC secrets
ansible-vault view ansible/group_vars/lxc_vault.yml

# Vault password file location: ~/.ansible_vault_pass
```
