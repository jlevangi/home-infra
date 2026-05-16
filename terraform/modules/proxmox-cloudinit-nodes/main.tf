terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
    }
  }
}

resource "proxmox_vm_qemu" "this" {
  count       = var.vm_count
  name        = "${var.vm_name_prefix}-${count.index + 1}"
  target_node = element(var.target_nodes, count.index)
  tags        = length(var.proxmox_tags) > 0 ? join(";", sort(distinct(var.proxmox_tags))) : null
  description = "Managed by Terraform."

  clone      = var.template_name
  full_clone = true

  agent              = 1
  os_type            = "cloud-init"
  start_at_node_boot = var.start_at_node_boot

  cpu {
    cores   = var.cpu_cores
    sockets = var.cpu_sockets
    type    = var.cpu_type
    numa    = var.cpu_numa
  }

  memory   = var.memory
  balloon  = var.balloon
  scsihw   = var.scsihw
  bootdisk = var.bootdisk

  disk {
    format  = "raw"
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.vm_storage
  }

  disk {
    format  = "raw"
    replicate = false
    slot    = "scsi0"
    size    = var.os_disk_size
    type    = "disk"
    storage = var.vm_storage
  }

  dynamic "disk" {
    for_each = var.data_disk_enabled ? [1] : []
    content {
      format  = "raw"
      replicate = false
      slot    = "scsi1"
      size    = var.data_disk_size
      type    = "disk"
      storage = var.data_disk_storage
    }
  }

  network {
    id      = 0
    model   = "virtio"
    bridge  = var.nic_name
    macaddr = "${var.macaddr_prefix}${count.index + 1}"
  }

  ipconfig0    = "ip=${var.ip_base}${count.index + var.ip_offset}/${var.subnet_mask},gw=${var.gateway}"
  nameserver   = var.nameserver
  searchdomain = var.search_domain

  sshkeys    = var.ssh_key
  ciuser     = var.ci_user
  cipassword = var.ci_password
  ciupgrade  = false

  timeouts {
    create = var.create_timeout
    update = var.update_timeout
    delete = var.delete_timeout
  }

  startup_shutdown {
    order            = -1
    shutdown_timeout = -1
    startup_delay    = -1
  }

  lifecycle {
    ignore_changes = [
      network,
    ]
    replace_triggered_by = []
  }
}
