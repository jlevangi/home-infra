output "vm_names" {
  description = "Names of the Talos nodes."
  value       = module.vms.node_names
}

output "vm_ips" {
  description = "Static IPs assigned to each Talos node."
  value       = module.vms.node_ips
}

output "controlplane_endpoint" {
  description = "Kubernetes and Talos API endpoint."
  value       = local.cluster_endpoint
}

output "kubeconfig" {
  description = "Raw kubeconfig for the Talos cluster."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Raw talosconfig for talosctl."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
