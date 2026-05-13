output "vm_ips" {
  description = "IP addresses of the K3s control-plane nodes"
  sensitive   = true
  value = [
    for i, vm in proxmox_vm_qemu.cp :
    "${var.ip_base}${i + 4}"
  ]
}

output "vm_names" {
  description = "Names of the K3s CP nodes"
  sensitive   = true
  value       = proxmox_vm_qemu.cp[*].name
}

output "ansible_inventory" {
  description = "Ansible inventory snippet for the stage control-plane group"
  sensitive   = true
  value = {
    k3s_cluster_stage_master = {
      hosts = {
        for i, vm in proxmox_vm_qemu.cp :
        vm.name => {
          ansible_host = "${var.ip_base}${i + 4}"
          ansible_user = var.ci_user
        }
      }
    }
  }
}
