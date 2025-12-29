# Required Vault Credentials for SSL Implementation

## Missing Cloudflare Credentials

The SSL implementation requires the following variables to be added to your Ansible Vault file:
`ansible/group_vars/k3s_cluster_vault.yml`

```yaml
# Cloudflare API credentials for DNS challenge
vault_cloudflare_email_address: "your-email@cloudflare.com"
vault_cloudflare_dns_api_key: "your-cloudflare-api-token"
```

## How to Add These Credentials

1. **Edit the encrypted vault file:**
   ```bash
   ansible-vault edit ansible/group_vars/k3s_cluster_vault.yml
   ```

2. **Add the two variables above** with your actual Cloudflare credentials

## How to Obtain Cloudflare Credentials

1. **Log in to Cloudflare Dashboard**
2. **Go to My Profile → API Tokens**
3. **Create Custom Token with permissions:**
   - Zone:DNS:Edit for your domain
   - Zone:Zone:Read for your domain
4. **Copy the API Token** and use as `vault_cloudflare_dns_api_key`
5. **Use your Cloudflare email** as `vault_cloudflare_email_address`

## Test the Configuration

Once added, you can test with any environment:
```bash
# Deploy test environment with SSL
./scripts/deploy_k3s_cluster.sh --test

# Deploy applications with SSL-enabled ingress  
./scripts/deploy_k3s_apps.sh --test
```

## Verification

SSL certificates should be automatically generated and show:
```bash
openssl s_client -connect your-app.levangie.dev:443 -servername your-app.levangie.dev < /dev/null 2>/dev/null | openssl x509 -noout -issuer

# Should show: issuer=C = US, O = Let's Encrypt, CN = R12
```

## Environment Support

All three environments are now configured for SSL:
- **Production**: `*.levangie.dev` (no prefix)
- **Stage**: `*.stage.levangie.dev`  
- **Test**: `*.test.levangie.dev`