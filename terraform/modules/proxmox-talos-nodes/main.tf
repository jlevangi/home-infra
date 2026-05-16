terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
    }
  }
}

resource "proxmox_vm_qemu" "this" {
  for_each = var.nodes

  name        = each.key
  target_node = each.value.target_node
  clone       = var.template_name
  full_clone  = true

  start_at_node_boot = var.start_at_node_boot

  agent     = 1
  skip_ipv6 = var.skip_ipv6

  cpu {
    cores   = var.cpu_cores
    sockets = var.cpu_sockets
    type    = var.cpu_type
  }

  memory   = var.memory
  scsihw   = var.scsihw
  bootdisk = var.bootdisk

  disk {
    slot    = "scsi0"
    size    = var.vm_disk_size
    type    = "disk"
    storage = var.vm_storage
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = var.nic_name
  }

  timeouts {
    create = var.create_timeout
    update = var.update_timeout
    delete = var.delete_timeout
  }

  lifecycle {
    ignore_changes = [
      network,
      disk,
    ]
  }
}
