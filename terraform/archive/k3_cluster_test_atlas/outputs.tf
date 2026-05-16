output "vm_ips" {
  description = "IP addresses of the K3s worker nodes"
  sensitive   = true
  value = [
    for i, vm in proxmox_vm_qemu.terraform :
    "${var.ip_base}${i + 1}"
  ]
}

output "vm_names" {
  description = "Names of the K3s worker nodes"
  sensitive   = true
  value       = proxmox_vm_qemu.terraform[*].name
}

output "ansible_inventory" {
  description = "Ansible inventory snippet for the test worker group"
  sensitive   = true
  value = {
    k3s_cluster_test_workers = {
      hosts = {
        for i, vm in proxmox_vm_qemu.terraform :
        vm.name => {
          ansible_host = "${var.ip_base}${i + 1}"
          ansible_user = var.ci_user
        }
      }
    }
  }
}
