output "vm_ip" {
  description = "IP address of the GPU worker node"
  sensitive   = true
  value       = var.ip_address
}

output "vm_name" {
  description = "Name of the GPU worker node"
  sensitive   = true
  value       = proxmox_vm_qemu.gpu_worker.name
}

output "ansible_inventory_host" {
  description = "Ansible inventory snippet for the GPU worker"
  sensitive   = true
  value = {
    (proxmox_vm_qemu.gpu_worker.name) = {
      ansible_host = var.ip_address
      ansible_user = var.ci_user
    }
  }
}
