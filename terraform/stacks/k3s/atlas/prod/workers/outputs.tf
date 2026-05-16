output "vm_ips" {
  description = "IP addresses of the K3s production worker nodes."
  value       = concat(module.nodes.vm_ips, [var.gpu_worker_ip_address])
  sensitive   = true
}

output "vm_names" {
  description = "Names of the K3s production worker nodes."
  value       = concat(module.nodes.vm_names, [proxmox_vm_qemu.gpu_worker.name])
  sensitive   = true
}

output "ansible_inventory" {
  description = "Ansible inventory snippet for the production worker group."
  sensitive   = true
  value = {
    (local.inventory_group) = {
      hosts = merge(module.nodes.hosts, {
        (proxmox_vm_qemu.gpu_worker.name) = {
          ansible_host = var.gpu_worker_ip_address
          ansible_user = var.ci_user
          target_node  = proxmox_vm_qemu.gpu_worker.target_node
        }
      })
    }
  }
}
