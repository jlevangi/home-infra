# Frigate Keycloak proxy recovery

**The proxy rollout changes Frigate auth behavior.** Frigate remains on port `8971`; direct unproxied access is not a recovery path. Kubernetes-managed Frigate and OAuth2 Proxy changes must be reverted through Git and the Frigate Argo CD application. Do not use a temporary public ingress or open the Frigate service to the LAN.

1. To roll back the desired auth behavior, revert the scoped Frigate manifest changes in Git (keeping unrelated user edits intact). Review the resulting diff before commit; syncing the Frigate application is a separate parent/operator action.
2. For local break-glass access, use a controlled, authenticated `kubectl port-forward` from a trusted workstation to the Frigate pod's **authenticated** port `8971`. Do not port-forward port `5000`. Stop the forward after recovery.
3. If the proxy is unhealthy, inspect OAuth2 Proxy logs and readiness, the Frigate deployment, the ExternalSecret `frigate-secrets` status (never its value), and Keycloak admin role mapper/user-role state. Keep viewer as the default; grant `frigate-admin` only to the intended user.
4. Never bypass identity checks with `--trusted-ip`, wildcard role assignment, or an alternate public route.
