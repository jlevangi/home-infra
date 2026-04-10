# Traefik SSL Certificate Remediation Steps

## Overview
This document outlines the complete remediation steps required to fix Traefik SSL certificate issues where Let's Encrypt certificates were not being generated properly due to DNS resolution problems during ACME validation.

## Initial Problem
- Traefik was deployed but using default self-signed certificates
- Longhorn UI at `longhorn.levangie.dev` showed "Not Secure" with Traefik's default certificate
- ACME DNS challenge was failing because Traefik was using internal cluster DNS instead of external DNS servers

## Root Cause
Traefik's ACME DNS challenge was trying to validate certificates using the cluster's internal DNS (dns-1.levangie.org) instead of external DNS servers that can see Cloudflare's DNS records.

## Remediation Steps Performed

### 1. Initial Traefik Configuration Files Created

#### `/tmp/traefik-values.yaml`
```yaml
# Traefik 2 Configuration with SSL/ACME
deployment:
  replicas: 1
  # Init containers for ACME file permissions
  initContainers:
    - name: acme-init
      image: busybox:1.35
      command: 
        - sh
        - -c
        - |
          touch /data/acme.json
          chmod 600 /data/acme.json
          ls -la /data/acme.json
      securityContext:
        runAsUser: 65532
        runAsGroup: 65532
        runAsNonRoot: true
        allowPrivilegeEscalation: false
      volumeMounts:
        - name: traefik-certs
          mountPath: /data

service:
  enabled: true
  type: LoadBalancer
  annotations:
    metallb.universe.tf/loadBalancerIPs: "172.20.20.200"

ports:
  web:
    port: 80
    expose:
      default: true
    exposedPort: 80
  websecure:
    port: 443
    expose:
      default: true
    exposedPort: 443
    tls:
      enabled: true
  traefik:
    port: 9000
    expose:
      default: false
    exposedPort: 9000

api:
  dashboard: true
  insecure: false

providers:
  kubernetesCRD:
    enabled: true
  kubernetesIngress:
    enabled: true

globalArguments:
  - "--global.checknewversion=false"
  - "--global.sendanonymoususage=false"

additionalArguments:
  - "--providers.kubernetesingress.ingressclass=traefik"
  - "--metrics.prometheus=true"
  - "--entrypoints.websecure.http.tls=true"
  - "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
  - "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare"
  - "--certificatesresolvers.letsencrypt.acme.email=admin@levangie.org"
  - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
  - "--certificatesresolvers.letsencrypt.acme.caserver=https://acme-v02.api.letsencrypt.org/directory"

persistence:
  enabled: true
  name: traefik-certs
  size: 1Gi
  storageClass: longhorn
  path: /data
  annotations: {}

# External DNS resolution for ACME validation
dnsPolicy: "None"
dnsConfig:
  nameservers:
  - "1.1.1.1"
  - "8.8.8.8"
  options:
  - name: ndots
    value: "2"

# Environment variables for DNS provider
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

# Security context for ACME file management
securityContext:
  runAsUser: 65532
  runAsGroup: 65532
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL

# Pod security context for ACME file permissions
podSecurityContext:
  runAsNonRoot: true
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault
```

#### `/tmp/traefik-dns-secret.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: traefik-dns-secret
  namespace: traefik-system
type: Opaque
data:
  email: YWRtaW5AbGV2YW5naWUub3Jn
  api-token: MC45U3VucmZ3SUc2S1NlRWZtNnp5SXRtQktMVUNlclVyX2JvWHg0eA==
```

### 2. Helm Commands Executed

#### Uninstall existing Traefik (due to PVC immutability)
```bash
export KUBECONFIG=/tmp/k3s-prod-kubeconfig-fixed.yaml
/usr/local/bin/helm uninstall traefik -n traefik-system
```

#### Create DNS secret
```bash
kubectl apply -f /tmp/traefik-dns-secret.yaml
```

#### Install Traefik with new configuration
```bash
/usr/local/bin/helm install traefik traefik/traefik \
  --namespace traefik-system \
  --create-namespace \
  --values /tmp/traefik-values.yaml
```

### 3. DNS Policy Fix Applied

The critical fix was applying the DNS policy patch to ensure Traefik uses external DNS servers for ACME validation:

```bash
kubectl patch deployment traefik -n traefik-system --patch '{
  "spec": {
    "template": {
      "spec": {
        "dnsPolicy": "None",
        "dnsConfig": {
          "nameservers": ["1.1.1.1", "8.8.8.8"],
          "options": [{"name": "ndots", "value": "2"}]
        }
      }
    }
  }
}'
```

### 4. Volume Attachment Issues Resolved

During deployment, encountered PVC multi-attach errors. Resolution:
```bash
# Force delete old pods to release PVC
kubectl delete pod -n traefik-system <old-pod-name> --grace-period=0 --force

# Scale down old replicaset
kubectl scale replicaset <old-replicaset> -n traefik-system --replicas=0
```

### 5. Ingress Configuration Verified

Confirmed Longhorn ingress was properly configured:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
  name: longhorn-frontend-ingress
  namespace: longhorn-system
spec:
  ingressClassName: traefik
  rules:
  - host: longhorn.levangie.dev
    http:
      paths:
      - backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - longhorn.levangie.dev
    secretName: longhorn-ui-tls
```

## Verification Steps

### 1. Certificate Validation
```bash
# Check certificate details
openssl s_client -connect longhorn.levangie.dev:443 -servername longhorn.levangie.dev 2>/dev/null | openssl x509 -noout -issuer -subject -dates
```

Expected output:
```
issuer=C = US, O = Let's Encrypt, CN = R13
subject=CN = longhorn.levangie.dev
notBefore=Sep  5 00:37:30 2025 GMT
notAfter=Dec  4 00:37:29 2025 GMT
```

### 2. ACME Storage Verification
```bash
# Check ACME storage file
kubectl exec -n traefik-system <traefik-pod> -- ls -la /data/
```

Expected: `acme.json` file with substantial size (>10KB indicating certificate data)

### 3. Service Accessibility
```bash
# Test HTTPS access
curl -I https://longhorn.levangie.dev
```

Expected: HTTP/2 200 response with no certificate warnings

## Key Configuration Elements for Ansible Integration

### Required Group Variables
```yaml
# In group_vars/k3s_cluster.yml
traefik_tls_enabled: true
traefik_acme_enabled: true
traefik_acme_dns_provider: "cloudflare"
traefik_acme_email: "admin@levangie.org"
traefik_persistence_enabled: true
traefik_dns_policy: "None"  # Critical for ACME validation
traefik_external_nameservers:
  - "1.1.1.1"
  - "8.8.8.8"
```

### Critical DNS Configuration
The most important fix was the DNS policy configuration:
- `dnsPolicy: "None"` - Override cluster DNS
- External nameservers (1.1.1.1, 8.8.8.8) - Ensure ACME can reach Cloudflare DNS
- `ndots: 2` - DNS search optimization

### Secrets Management
- Cloudflare API credentials must be stored in `traefik-dns-secret`
- Email and API token must be base64 encoded in the secret
- Secret must be created before Traefik deployment

## Ansible Task Modifications Needed

1. **Add DNS secret creation task** before Traefik installation
2. **Include DNS policy configuration** in Helm values template
3. **Add certificate verification tasks** post-deployment
4. **Handle PVC cleanup** for Traefik upgrades (uninstall/reinstall vs upgrade)
5. **Add ACME storage validation** in health checks

## Result
- ✅ Let's Encrypt SSL certificate successfully generated
- ✅ Cloudflare DNS challenge working correctly
- ✅ Longhorn UI accessible with valid HTTPS certificate  
- ✅ Certificate auto-renewal configured
- ✅ ACME storage persistent across pod restarts