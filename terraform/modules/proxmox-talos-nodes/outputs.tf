output "node_names" {
  description = "Names of the created Talos VMs."
  value       = sort(keys(var.nodes))
}

output "node_ips" {
  description = "Static IPs assigned to each Talos node."
  value       = { for name, node in var.nodes : name => node.ip }
}

output "node_details" {
  description = "Per-node metadata including reported guest-agent IPs."
  value = {
    for name, vm in proxmox_vm_qemu.this :
    name => {
      ip                    = var.nodes[name].ip
      role                  = var.nodes[name].role
      target_node           = vm.target_node
      reported_ipv4_address = vm.default_ipv4_address
    }
  }
}
