output "vm_id" {
  description = "Proxmox VMID for OpenHands."
  value       = 303
}

output "vm_name" {
  description = "OpenHands VM name."
  value       = module.node.vm_names[0]
}

output "ip_address" {
  description = "Static IP address assigned to OpenHands."
  value       = "172.20.22.11"
}
