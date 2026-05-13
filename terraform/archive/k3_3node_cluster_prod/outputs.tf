# Output the IP addresses of created VMs
output "vm_ips" {
  description = "IP addresses of the K3s nodes"
  sensitive   = true # Mark as sensitive since it references VM resources
  value = [
    for vm in proxmox_vm_qemu.terraform :
    "172.20.20.10${index(proxmox_vm_qemu.terraform, vm) + 1}"
  ]
}

# Output VM names
output "vm_names" {
  description = "Names of the K3s nodes"
  sensitive   = true # Mark as sensitive since it references VM resources
  value       = proxmox_vm_qemu.terraform[*].name
}

# Output for Ansible inventory
output "ansible_inventory" {
  description = "Ansible inventory format"
  sensitive   = true # Mark as sensitive since it references VM resources
  value = {
    k3s_master = {
      hosts = {
        (proxmox_vm_qemu.terraform[0].name) = {
          ansible_host = "172.20.20.101"
          ansible_user = "var.ci_user"
        }
      }
    }
    k3s_workers = {
      hosts = {
        for i, vm in slice(proxmox_vm_qemu.terraform, 1, length(proxmox_vm_qemu.terraform)) :
        vm.name => {
          ansible_host = "172.20.20.10${i + 2}"
          ansible_user = "var.ci_user"
        }
      }
    }
  }
}
