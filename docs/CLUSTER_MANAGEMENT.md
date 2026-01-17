# K3s Cluster Management Runbook

This document provides operational guidance for managing K3s clusters, including component deployment, troubleshooting, and manual operations.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Component Deployment](#component-deployment)
- [Infrastructure Components](#infrastructure-components)
- [Application Components](#application-components)
- [Health Checks](#health-checks)
- [Troubleshooting](#troubleshooting)
- [Manual Operations](#manual-operations)

---

## Quick Reference

### Common Operations

| Task | Command |
|------|---------|
| Deploy Traefik | `./scripts/deploy_component.sh --prod traefik` |
| Deploy MetalLB | `./scripts/deploy_component.sh --prod metallb` |
| Deploy Longhorn | `./scripts/deploy_component.sh --prod longhorn` |
| Deploy ArgoCD | `./scripts/deploy_component.sh --prod argocd` |
| Deploy single app | `./scripts/deploy_component.sh --prod bookstack` |
| Force redeploy | `./scripts/deploy_component.sh --prod traefik --force` |
| Dry run (show commands) | `./scripts/deploy_component.sh --prod traefik --dry-run` |
| List components | `./scripts/deploy_component.sh --list` |

### Switch Cluster Context

```bash
./scripts/k3s-context-manager.sh switch prod
./scripts/k3s-context-manager.sh switch test
./scripts/k3s-context-manager.sh switch stage
```

### Environment Summary

| Environment | Nodes | Traefik IP | Domain |
|-------------|-------|------------|--------|
| prod | 172.20.20.101-103 | 172.20.20.200 | levangie.dev |
| stage | 172.20.20.111-113 | 172.20.20.211 | stage.levangie.dev |
| test | 172.20.20.121-123 | 172.20.20.230 | test.levangie.dev |

---

## Component Deployment

### Using deploy_component.sh

The `deploy_component.sh` script provides targeted deployment of individual components:

```bash
# Syntax
./scripts/deploy_component.sh [ENVIRONMENT] COMPONENT [OPTIONS]

# Infrastructure components
./scripts/deploy_component.sh --prod traefik
./scripts/deploy_component.sh --prod metallb
./scripts/deploy_component.sh --prod longhorn
./scripts/deploy_component.sh --prod argocd

# Application components
./scripts/deploy_component.sh --prod bookstack
./scripts/deploy_component.sh --prod vaultwarden
./scripts/deploy_component.sh --prod homepage
./scripts/deploy_component.sh --prod pocketid
./scripts/deploy_component.sh --prod plex

# Options
--force       # Force redeploy even if already deployed
--dry-run     # Show commands without executing
-v/-vv/-vvv   # Verbosity levels
```

### Using Ansible Directly

For maximum control, run Ansible commands directly:

```bash
# Infrastructure components (use -e deploy_component)
ansible-playbook -i ansible/inventories/production/hosts.yml \
  ansible/playbooks/k3s-deploy-component.yml \
  -e deploy_component=traefik \
  -e target_cluster=k3s_cluster_prod \
  --vault-password-file ~/.ansible_vault_pass \
  -v

# Applications (use -e deploy_single_app)
ansible-playbook -i ansible/inventories/production/hosts.yml \
  ansible/playbooks/k3s-deploy-component.yml \
  -e deploy_single_app=bookstack \
  -e target_cluster=k3s_cluster_prod \
  --vault-password-file ~/.ansible_vault_pass \
  -v

# Force redeploy an infrastructure component
ansible-playbook -i ansible/inventories/production/hosts.yml \
  ansible/playbooks/k3s-deploy-component.yml \
  -e deploy_component=traefik \
  -e force_traefik_redeploy=true \
  -e target_cluster=k3s_cluster_prod \
  --vault-password-file ~/.ansible_vault_pass

# Force redeploy an app
ansible-playbook -i ansible/inventories/production/hosts.yml \
  ansible/playbooks/k3s-deploy-component.yml \
  -e deploy_single_app=homepage \
  -e "force_redeploy_apps=['homepage']" \
  -e target_cluster=k3s_cluster_prod \
  --vault-password-file ~/.ansible_vault_pass
```

---

## Infrastructure Components

### Traefik (Ingress Controller)

**Namespace:** `traefik-system`
**Dashboard URL:** `https://traefik.<domain>/dashboard/`

**Key Resources:**
- Deployment: `traefik`
- Service: `traefik` (LoadBalancer)
- IngressRoute: `traefik-dashboard`

**Health Check:**
```bash
# Check pods
kubectl get pods -n traefik-system

# Check service has external IP
kubectl get svc traefik -n traefik-system

# Get LoadBalancer IP
kubectl get svc traefik -n traefik-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Check dashboard IngressRoute
kubectl get ingressroute -n traefik-system

# Check ACME certificates
kubectl exec -n traefik-system deploy/traefik -- cat /data/acme.json | jq '.letsencrypt.Certificates | length'
```

**Redeploy:**
```bash
./scripts/deploy_component.sh --prod traefik --force
```

**Configuration Variables:**
- `traefik_loadbalancer_ip` - Static IP for LoadBalancer
- `traefik_dashboard_enabled` - Enable/disable dashboard
- `traefik_tls_enabled` - Enable TLS/HTTPS
- `traefik_acme_enabled` - Enable Let's Encrypt certificates

### MetalLB (Load Balancer)

**Namespace:** `metallb-system`

**Key Resources:**
- Deployment: `controller`
- DaemonSet: `speaker`
- IPAddressPool: `default-pool`
- L2Advertisement: `default`

**Health Check:**
```bash
# Check pods
kubectl get pods -n metallb-system

# Check IP pool
kubectl get ipaddresspool -n metallb-system -o yaml

# Check L2 advertisement
kubectl get l2advertisement -n metallb-system

# List all LoadBalancer services
kubectl get svc -A | grep LoadBalancer
```

**IP Pools:**
- Production: `172.20.20.200-172.20.20.210`
- Staging: `172.20.20.211-172.20.20.220`
- Test: `172.20.20.230-172.20.20.240`

**Redeploy:**
```bash
./scripts/deploy_component.sh --prod metallb --force
```

### Longhorn (Distributed Storage)

**Namespace:** `longhorn-system`
**UI Port-Forward:** `kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80`

**Key Resources:**
- Deployment: `longhorn-driver-deployer`, `longhorn-ui`
- DaemonSet: `longhorn-manager`
- StorageClass: `longhorn`

**Health Check:**
```bash
# Check all pods
kubectl get pods -n longhorn-system

# Check storage class
kubectl get sc longhorn

# Check volumes
kubectl get volumes.longhorn.io -n longhorn-system

# Check nodes
kubectl get nodes.longhorn.io -n longhorn-system

# Check backup target
kubectl get backuptarget -n longhorn-system
```

**Backup Commands:**
```bash
# List available backups
./scripts/list_backups.sh

# Check recurring jobs
kubectl get recurringjob -n longhorn-system
```

### ArgoCD (GitOps Controller)

**Namespace:** `argocd`
**UI URL:** `https://argocd.<domain>`

**Access:**
- URL: `https://argocd.levangie.dev` (prod) or `https://argocd.test.levangie.dev` (test)
- Username: `admin`
- Password: Run command below to retrieve

```bash
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

**Key Resources:**
- Deployment: `argocd-server`, `argocd-repo-server`, `argocd-applicationset-controller`
- StatefulSet: `argocd-application-controller`
- Service: `argocd-server`
- IngressRoute: `argocd-server`

**Health Check:**
```bash
# Check pods
kubectl get pods -n argocd

# Check services
kubectl get svc -n argocd

# Check ingress
kubectl get ingressroute -n argocd

# Check applications
kubectl get applications -A

# Check CRDs
kubectl get crd | grep argoproj
```

**Redeploy:**
```bash
./scripts/deploy_component.sh --prod argocd --force
```

**Configuration Variables:**
- `k3s_install_argocd` - Enable/disable ArgoCD deployment
- `argocd_ingress_enabled` - Enable/disable Traefik ingress
- `argocd_dex_enabled` - Enable/disable Dex SSO provider
- `argocd_notifications_enabled` - Enable/disable notifications

---

## Application Components

### General App Operations

```bash
# Check app status
kubectl get all -n <app-name>

# Get app logs
kubectl logs -n <app-name> deploy/<deployment-name>

# Check ingress
kubectl get ingress -n <app-name>

# Check PVCs
kubectl get pvc -n <app-name>

# Describe pod for issues
kubectl describe pod -n <app-name> -l app=<app-name>
```

### BookStack

**Namespace:** `bookstack`
**URL:** `https://bookstack.<domain>`

```bash
# Status
kubectl get pods -n bookstack

# App logs
kubectl logs -n bookstack deploy/bookstack

# Database logs
kubectl logs -n bookstack deploy/bookstack-mariadb

# Database shell
kubectl exec -it -n bookstack deploy/bookstack-mariadb -- mysql -u bookstack -p
```

### Vaultwarden

**Namespace:** `vaultwarden`
**URL:** `https://vw.<domain>`

```bash
# Status
kubectl get pods -n vaultwarden

# Logs
kubectl logs -n vaultwarden deploy/vaultwarden
```

### Homepage

**Namespace:** `homepage`
**URL:** `https://homepage.<domain>`

```bash
# Status (Helm-based)
helm status homepage -n homepage

# Pods
kubectl get pods -n homepage
```

---

## Health Checks

### Full Cluster Health

```bash
# Node status
kubectl get nodes -o wide

# All pods
kubectl get pods -A

# Services with external IPs
kubectl get svc -A | grep LoadBalancer

# Recent events (errors/warnings)
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Resource usage (requires metrics-server)
kubectl top nodes
kubectl top pods -A
```

### Quick Infrastructure Check

```bash
# One-liner to check all infrastructure
echo "=== Nodes ===" && kubectl get nodes && \
echo "=== Traefik ===" && kubectl get pods,svc -n traefik-system && \
echo "=== MetalLB ===" && kubectl get pods -n metallb-system && \
echo "=== Longhorn ===" && kubectl get pods -n longhorn-system | head -5
```

---

## Troubleshooting

### Traefik Issues

**Problem: Dashboard not accessible**
```bash
# Check Traefik is running
kubectl get pods -n traefik-system

# Check service has IP
kubectl get svc traefik -n traefik-system

# Check IngressRoute exists
kubectl get ingressroute traefik-dashboard -n traefik-system

# Check DNS record points to correct IP
nslookup traefik.<domain>

# Test direct access to LoadBalancer IP
curl -I http://<traefik-loadbalancer-ip>/dashboard/
```

**Problem: No external IP assigned**
```bash
# Check MetalLB is running
kubectl get pods -n metallb-system

# Check IP pool has available addresses
kubectl get ipaddresspool -n metallb-system -o yaml

# Check service annotations
kubectl describe svc traefik -n traefik-system
```

**Problem: SSL certificates not working**
```bash
# Check ACME storage
kubectl exec -n traefik-system deploy/traefik -- cat /data/acme.json | jq .

# Check DNS API secret
kubectl get secret cloudflare-api-token -n traefik-system

# Check Traefik logs for ACME errors
kubectl logs -n traefik-system deploy/traefik | grep -i acme
```

**Force Complete Rebuild:**
```bash
./scripts/deploy_component.sh --prod traefik --force
```

### MetalLB Issues

**Problem: Speaker pods crashing**
```bash
# Check logs
kubectl logs -n metallb-system -l component=speaker

# Check for network issues
kubectl get nodes -o wide
```

**Problem: Services stuck in Pending**
```bash
# Check IP pool exists and has addresses
kubectl get ipaddresspool -n metallb-system

# Check L2 advertisement
kubectl get l2advertisement -n metallb-system

# Redeploy MetalLB
./scripts/deploy_component.sh --prod metallb --force
```

### Longhorn Issues

**Problem: PVC stuck in Pending**
```bash
# Check events
kubectl describe pvc <pvc-name> -n <namespace>

# Check Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=50

# Check storage class
kubectl get sc longhorn -o yaml
```

**Problem: Volume degraded**
```bash
# Check volume status
kubectl get volumes.longhorn.io -n longhorn-system

# Access Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Open http://localhost:8080 and check volume health
```

### Application Issues

**Problem: App not accessible via ingress**
```bash
# Check ingress
kubectl get ingress -n <namespace>
kubectl describe ingress -n <namespace>

# Check service
kubectl get svc -n <namespace>

# Test direct service access
kubectl port-forward -n <namespace> svc/<service> 8080:<port>
# Then curl localhost:8080
```

**Problem: App pod not starting**
```bash
# Check events
kubectl describe pod -n <namespace> -l app=<app>

# Check previous logs
kubectl logs -n <namespace> deploy/<deployment> --previous

# Check PVC is bound
kubectl get pvc -n <namespace>
```

---

## Manual Operations

### Direct Helm Commands

```bash
# List all releases
helm list -A

# Traefik operations
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm list -n traefik-system
helm history traefik -n traefik-system

# Rollback Traefik to previous
helm rollback traefik -n traefik-system

# MetalLB
helm repo add metallb https://metallb.github.io/metallb
helm list -n metallb-system

# Longhorn
helm repo add longhorn https://charts.longhorn.io
helm list -n longhorn-system
```

### Emergency: Complete Traefik Reset

```bash
# 1. Uninstall via Helm
helm uninstall traefik -n traefik-system

# 2. Delete namespace (removes all resources)
kubectl delete namespace traefik-system

# 3. Wait for cleanup
kubectl get all -n traefik-system  # Should show nothing

# 4. Redeploy
./scripts/deploy_component.sh --prod traefik
```

### Emergency: Complete MetalLB Reset

```bash
helm uninstall metallb -n metallb-system
kubectl delete namespace metallb-system
./scripts/deploy_component.sh --prod metallb
```

### View Rendered Ansible Templates

To see what Ansible would generate without applying:

```bash
# Run with check mode and diff
ansible-playbook -i ansible/inventories/production/hosts.yml \
  ansible/playbooks/k3s-deploy-component.yml \
  --tags traefik \
  -e target_cluster=k3s_cluster_prod \
  --vault-password-file ~/.ansible_vault_pass \
  --check --diff
```

---

## Configuration Reference

### Key Variable Files

| File | Purpose |
|------|---------|
| `ansible/group_vars/k3s_cluster.yml` | Base config for all environments |
| `ansible/group_vars/k3s_cluster_prod.yml` | Production overrides |
| `ansible/group_vars/k3s_cluster_stage.yml` | Staging overrides |
| `ansible/group_vars/k3s_cluster_test.yml` | Test overrides |
| `ansible/group_vars/k3s_cluster_vault.yml` | Encrypted secrets |

### Traefik Configuration Variables

| Variable | Description |
|----------|-------------|
| `traefik_loadbalancer_ip` | Static IP for Traefik service |
| `traefik_dashboard_enabled` | Enable dashboard (true/false) |
| `traefik_tls_enabled` | Enable HTTPS (true/false) |
| `traefik_acme_enabled` | Enable Let's Encrypt (true/false) |
| `traefik_acme_dns_provider` | DNS provider for ACME (cloudflare) |

### Application Configuration

Apps are configured via `app_definitions` in `k3s_cluster.yml` and enabled per-environment via `enabled_apps` list.

Example to deploy only one app to test:
```bash
# Override enabled_apps for single deployment
./scripts/deploy_component.sh --test bookstack
```

---

## See Also

- [CLAUDE.md](/CLAUDE.md) - Repository overview and common commands
- [K3S-CLUSTER-MANAGEMENT.md](/docs/K3S-CLUSTER-MANAGEMENT.md) - Context switching details
- [LONGHORN-BACKUP-MIGRATION.md](/docs/LONGHORN-BACKUP-MIGRATION.md) - Backup procedures
