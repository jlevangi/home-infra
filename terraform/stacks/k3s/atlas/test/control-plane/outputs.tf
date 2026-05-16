output "vm_ips" {
  description = "IP addresses of the K3s test control-plane nodes."
  value       = module.nodes.vm_ips
  sensitive   = true
}

output "vm_names" {
  description = "Names of the K3s test control-plane nodes."
  value       = module.nodes.vm_names
  sensitive   = true
}

output "ansible_inventory" {
  description = "Ansible inventory snippet for the test control-plane group."
  sensitive   = true
  value = {
    (local.inventory_group) = {
      hosts = module.nodes.hosts
    }
  }
}
