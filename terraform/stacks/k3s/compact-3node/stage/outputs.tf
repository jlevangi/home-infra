output "vm_ips" {
  description = "IP addresses of the compact staging cluster."
  value       = module.nodes.vm_ips
  sensitive   = true
}

output "vm_names" {
  description = "Names of the compact staging cluster nodes."
  value       = module.nodes.vm_names
  sensitive   = true
}

output "ansible_inventory" {
  description = "Ansible inventory snippet for the compact staging cluster."
  sensitive   = true
  value = {
    (local.master_group) = {
      hosts = {
        (local.master_name) = module.nodes.hosts[local.master_name]
      }
    }
    (local.worker_group) = {
      hosts = {
        for name in local.worker_names :
        name => module.nodes.hosts[name]
      }
    }
  }
}
