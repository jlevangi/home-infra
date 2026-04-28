# Traefik SSL

Use this reference for the current Traefik ACME setup. The repo is configured for cluster-level TLS termination through Traefik with Cloudflare DNS challenge support.

This document outlines the complete implementation of SSL certificates using Traefik with Let's Encrypt ACME and Cloudflare DNS challenge for cluster-level SSL termination.

## Overview

The current implementation provides automatic certificate generation and renewal at the cluster level. Traefik handles TLS termination and stores ACME state in persistent storage.

### Architecture

```
Internet → DNS (Cloudflare) → Traefik LoadBalancer → SSL Termination → Applications
```

- **DNS**: Cloudflare manages DNS records and DNS-01 ACME challenge
- **Traefik**: Ingress controller with ACME client for Let's Encrypt
- **Let's Encrypt**: Certificate Authority providing free SSL certificates
- **Applications**: Receive decrypted HTTP traffic from Traefik

## Required Components

### 1. Ansible Vault Variables

Add these variables to your `ansible/group_vars/k3s_cluster_vault.yml`:

```yaml
# Cloudflare API credentials for DNS challenge
vault_cloudflare_email_address: "your-email@example.com"
vault_cloudflare_dns_api_key: "your-cloudflare-api-key"
```

**How to obtain Cloudflare API credentials:**
1. Log in to Cloudflare Dashboard
2. Go to **My Profile** → **API Tokens**
3. Create token with **Zone:DNS:Edit** permissions for your domain
4. Use the **Global API Key** or create a **Custom API Token**

### 2. Traefik Configuration (`ansible/roles/k3s/templates/traefik-values.yaml.j2`)

#### Essential ACME Configuration

```yaml
# Enable TLS and ACME
additionalArguments:
  - "--entrypoints.websecure.http.tls=true"
  - "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
  - "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare"
  - "--certificatesresolvers.letsencrypt.acme.email={{ traefik_acme_email | default('admin@yourdomain.com') }}"
  - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
  - "--certificatesresolvers.letsencrypt.acme.caserver=https://acme-v02.api.letsencrypt.org/directory"

# Cloudflare DNS credentials
env:
  - name: CF_API_EMAIL
    valueFrom:
      secretKeyRef:
        name: traefik-dns-secret
        key: email
  - name: CF_DNS_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: traefik-dns-secret
        key: api-token

# Critical: File permissions for ACME
securityContext:
  fsGroup: 65532
  runAsUser: 65532
  runAsGroup: 65532

# Critical: Init container for ACME file permissions
initContainers:
  - name: fix-permissions
    image: busybox
    command: ['sh', '-c', 'touch /data/acme.json && chmod 600 /data/acme.json && chown 65532:65532 /data/acme.json']
    securityContext:
      runAsUser: 0
    volumeMounts:
      - name: data
        mountPath: /data

# Persistent storage for certificates
persistence:
  enabled: true
  name: traefik-certs
  size: 1Gi
  storageClass: longhorn
  path: /data

# External DNS resolution (critical for ACME validation)
dnsPolicy: "None"
dnsConfig:
  nameservers:
  - "1.1.1.1"
  - "8.8.8.8"
  options:
  - name: ndots
    value: "2"
```

### 3. Ingress Template (managed per-app under `argocd/manifests/<app>/`)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ service_name }}-ingress
  namespace: {{ k8s_namespace | default(service_name) }}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    # Critical: Reference to ACME certificate resolver
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  ingressClassName: traefik
  # Critical: TLS configuration for automatic certificate generation
  tls:
  - hosts:
    - {{ app_url | regex_replace('https?://','') }}
    secretName: {{ service_name }}-tls
  rules:
  - host: {{ app_url | regex_replace('https?://','') }}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: {{ service_name }}
            port:
              number: {{ service_port | int }}
```

### 4. Cluster Configuration Variables

In your environment-specific group vars (e.g., `k3s_cluster_test.yml`):

```yaml
# Enable SSL/TLS features
traefik_tls_enabled: true
traefik_acme_enabled: true
traefik_persistence_enabled: true

# ACME configuration
traefik_acme_email: "admin@yourdomain.com"
traefik_acme_dns_provider: "cloudflare"

# Traefik LoadBalancer IP
traefik_loadbalancer_ip: "172.20.20.230"  # Your cluster's external IP
```

## Implementation Steps

### Step 1: Configure Ansible Vault

```bash
# Edit the encrypted vault file
ansible-vault edit ansible/group_vars/k3s_cluster_vault.yml

# Add Cloudflare credentials:
vault_cloudflare_email_address: "your-email@cloudflare.com"
vault_cloudflare_dns_api_key: "your-cloudflare-api-token"
```

### Step 2: Update Traefik Configuration

1. **Edit** `ansible/roles/k3s/templates/traefik-values.yaml.j2`
2. **Add** ACME configuration (see template above)
3. **Ensure** init container for file permissions is included
4. **Configure** external DNS resolution

### Step 3: Update Ingress Templates

1. **Edit** the per-app Ingress manifest under `argocd/manifests/<app>/`
2. **Add** TLS section with certificate resolver annotation
3. **Ensure** `ingressClassName: traefik` is set

### Step 4: Configure DNS

1. **Create A record** for cluster: `k3s-test.yourdomain.com → 172.20.20.230`
2. **Create CNAME records** for applications:
   - `test.vw.yourdomain.com → k3s-test.yourdomain.com`
   - `test.bookstack.yourdomain.com → k3s-test.yourdomain.com`
   - etc.

### Step 5: Deploy Cluster

```bash
# Deploy the cluster with updated configuration
./scripts/deploy-k3s-cluster.sh --test

# Applications (with SSL-enabled ingress) are reconciled by ArgoCD from
# argocd/apps/test on `main`.
```

### Step 6: Verify Implementation

```bash
# Check certificate details
openssl s_client -connect test.vw.yourdomain.com:443 -servername test.vw.yourdomain.com < /dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates

# Should show:
# subject=CN = test.vw.yourdomain.com
# issuer=C = US, O = Let's Encrypt, CN = R12
# notBefore=...
# notAfter=... (90 days from issue date)
```

## Troubleshooting

### Common Issues and Solutions

#### 1. ACME Permission Denied

**Symptom**: `unable to get ACME account: open /data/acme.json: permission denied`

**Solution**: Ensure init container and security context are properly configured:
```yaml
securityContext:
  fsGroup: 65532
  runAsUser: 65532
  runAsGroup: 65532

initContainers:
  - name: fix-permissions
    image: busybox
    command: ['sh', '-c', 'touch /data/acme.json && chmod 600 /data/acme.json && chown 65532:65532 /data/acme.json']
    securityContext:
      runAsUser: 0
```

#### 2. DNS Resolution Timeout

**Symptom**: `lookup dns-1.levangie.org. on 10.43.0.10:53: no such host`

**Solution**: Configure external DNS resolution:
```yaml
dnsPolicy: "None"
dnsConfig:
  nameservers:
  - "1.1.1.1"

## Related Docs

- [Cluster Operations](../operations/cluster-operations.md)
- [GitOps And ArgoCD](../operations/gitops-and-argocd.md)
  - "8.8.8.8"
```

#### 3. Cloudflare TXT Record Conflicts

**Symptom**: `An identical record already exists. (81058)`

**Solution**: Clean up existing `_acme-challenge` TXT records in Cloudflare DNS

#### 4. Certificate Not Generated

**Symptom**: Still seeing Traefik default certificate

**Solution**: Check ingress annotations and TLS configuration:
```yaml
annotations:
  traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
tls:
  - hosts:
    - your-domain.com
    secretName: your-app-tls
```

### Verification Commands

```bash
# Check Traefik pods
kubectl get pods -n traefik-system

# Check ACME logs
kubectl logs -n traefik-system -l app.kubernetes.io/name=traefik --tail=50

# Check ACME file
kubectl exec -n traefik-system <traefik-pod> -- ls -la /data/acme.json

# Check ingress configuration
kubectl describe ingress <ingress-name> -n <namespace>

# Test SSL certificate
curl -vI https://your-domain.com
```

## Security Considerations

1. **API Token Permissions**: Use minimal Cloudflare API permissions (Zone:DNS:Edit only)
2. **Vault Encryption**: Keep Cloudflare credentials encrypted in Ansible Vault
3. **Certificate Storage**: ACME certificates stored in persistent volume with proper permissions
4. **Network Security**: DNS resolution uses external servers to avoid internal DNS leaks

## Automatic Certificate Renewal

Let's Encrypt certificates are automatically renewed by Traefik:
- **Certificate Lifetime**: 90 days
- **Renewal Trigger**: Traefik checks for renewal ~30 days before expiration
- **Renewal Process**: Automatic via ACME protocol
- **Zero Downtime**: Certificates updated without service interruption

## Maintenance

### Regular Tasks

1. **Monitor certificate expiration**: Set up alerts for certificate expiry
2. **Check ACME logs**: Periodically review Traefik logs for ACME errors
3. **Verify DNS records**: Ensure DNS configuration remains correct
4. **Update API tokens**: Rotate Cloudflare API credentials periodically

### Emergency Procedures

**If certificates fail to renew:**
1. Check Traefik logs for ACME errors
2. Verify Cloudflare API credentials are still valid
3. Ensure DNS records are correct
4. Restart Traefik deployment if necessary:
   ```bash
   kubectl rollout restart deployment traefik -n traefik-system
   ```

## Configuration Files Summary

| File | Purpose | Key Changes |
|------|---------|-------------|
| `k3s_cluster_vault.yml` | Cloudflare API credentials | Added `vault_cloudflare_*` variables |
| `traefik-values.yaml.j2` | Traefik ACME configuration | Added ACME, DNS, security context |
| `ingress.yaml.j2` | SSL-enabled ingress template | Added TLS section and certresolver |
| `k3s_cluster_test.yml` | Environment SSL settings | Enabled `traefik_*_enabled` flags |

This implementation provides enterprise-grade SSL certificate management with automatic renewal and secure credential handling.
