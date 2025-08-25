# Infrastructure Notes

## Service Naming Convention Issue

### Problem
Inconsistency between service names and namespaces when using Helm charts vs manual deployments:

- **Manual deployments**: service_name matches namespace (e.g., `bookstack` service in `bookstack` namespace)
- **Helm charts**: service_name often differs from namespace (e.g., `plex-media-server` service in `plex` namespace)

### Current Workaround
Modified `common/ingress.yaml.j2` template to use:
```yaml
namespace: {{ k8s_namespace | default(service_name) }}
```

### Apps Affected
- **bookstack**: ✅ service_name = namespace = "bookstack"
- **vaultwarden**: ✅ service_name = namespace = "vaultwarden" 
- **homepage**: ✅ service_name = namespace = "homepage"
- **plex**: ❌ service_name = "plex-media-server", namespace = "plex"

### Future Considerations
1. **Option A**: Always pass `k8s_namespace` explicitly for all apps
2. **Option B**: Standardize service names to match namespaces where possible
3. **Option C**: Keep current hybrid approach (works but inconsistent)

### Impact
- Current solution is backward compatible
- Future Helm chart deployments should explicitly set `k8s_namespace` variable
- Manual deployments can continue using service_name = namespace pattern

## Helm Deployment Automation

### Problem Solved
Deploying Helm charts required repetitive tasks and manual kubeconfig management.

### Solution
Created reusable automation:

1. **Reusable Template**: `ansible/roles/k3s-apps/tasks/shared/helm_app_deployment.yml`
   - Handles all common Helm deployment patterns
   - Includes proper kubeconfig usage
   - Manages namespace creation, storage limits, ingress setup
   - Provides consistent error handling and status reporting

2. **Helper Script**: `scripts/add_helm_app.sh`
   - Scaffolds new Helm apps in minutes
   - Creates all necessary files and configurations
   - Usage: `./scripts/add_helm_app.sh <app_name> <helm_repo_url> <chart_name> <app_url>`

### Key Lessons from Plex Deployment
- **Always use kubeconfig**: All kubectl/helm commands need `--kubeconfig=/etc/rancher/k3s/k3s.yaml` or `KUBECONFIG` env var
- **Namespace vs Service Name**: Helm charts often have different service names than namespace names
- **TLS Dependencies**: Ingress TLS requires cert-manager or should be disabled for HTTP-only access
- **Pod Selectors**: Different charts use different label selectors for pods

### Usage Examples
```bash
# Add a new Helm app
./scripts/add_helm_app.sh grafana https://grafana.github.io/helm-charts grafana/grafana https://grafana.test

# Deploy using the template (in Ansible task)
- include_tasks: ../shared/helm_app_deployment.yml
  vars:
    app_name: "grafana"
    helm_config: {...}
    app_config: {...}
```