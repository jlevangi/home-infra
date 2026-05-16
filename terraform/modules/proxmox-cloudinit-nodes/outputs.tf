locals {
  host_map = {
    for index, vm in proxmox_vm_qemu.this :
    vm.name => {
      ansible_host = "${var.ip_base}${index + var.ip_offset}"
      ansible_user = var.ci_user
      target_node  = vm.target_node
    }
  }
}

output "vm_names" {
  description = "Names of the created VMs."
  value       = proxmox_vm_qemu.this[*].name
}

output "vm_ips" {
  description = "IP addresses of the created VMs."
  value = [
    for index, _ in proxmox_vm_qemu.this :
    "${var.ip_base}${index + var.ip_offset}"
  ]
}

output "hosts" {
  description = "Inventory-ready host map keyed by VM name."
  value       = local.host_map
}
