output "vm_names" {
  description = "Names of the Talos nodes (maps to Proxmox VM names)"
  value       = [for k, _ in local.nodes : k]
}

output "vm_ips" {
  description = "Static IPs assigned to each Talos node"
  value       = { for k, v in local.nodes : k => v.ip }
}

output "controlplane_endpoint" {
  description = "Kubernetes / Talos API endpoint"
  value       = local.cluster_endpoint
}

# Write to disk with:
#   terraform output -raw kubeconfig > ~/.kube/config-talos-test
output "kubeconfig" {
  description = "Raw kubeconfig for the Talos cluster"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

# Write to disk with:
#   terraform output -raw talosconfig > ~/.talos/config-talos-test
output "talosconfig" {
  description = "Raw talosconfig for talosctl"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
