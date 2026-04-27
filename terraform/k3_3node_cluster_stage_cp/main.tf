terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc07"
    }
  }
  required_version = ">= 1.0"
}

provider "proxmox" {
  pm_api_url          = var.api_url
  pm_api_token_id     = var.token_id
  pm_api_token_secret = var.token_secret
  pm_tls_insecure     = true
  pm_log_enable       = true
  pm_log_file         = "tf-plugin-proxmox.log"
  pm_debug            = true
  pm_log_levels = {
    _default    = "debug"
    _capturelog = ""
  }
}

resource "proxmox_vm_qemu" "cp" {
  name        = "${var.vm_name}-${count.index + 1}"
  count       = var.vm_count
  target_node = element(var.proxmox_hosts, count.index)

  clone      = var.template_name
  full_clone = "true"

  agent   = 1
  os_type = "cloud-init"

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
    numa    = true
  }

  memory  = 8192
  balloon = 8192
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.vm_storage
  }

  disk {
    slot    = "scsi0"
    size    = "64G"
    type    = "disk"
    storage = var.vm_storage
  }

  network {
    id      = 0
    model   = "virtio"
    bridge  = var.nic_name
    macaddr = "76:5A:F2:57:5B:1${count.index + 1}"
  }

  ipconfig0    = "ip=${var.ip_base}${count.index + 4}/${var.subnet_mask},gw=${var.gateway}"
  nameserver   = var.nameserver
  searchdomain = var.search_domain

  sshkeys    = var.ssh_key
  ciuser     = var.ci_user
  cipassword = var.ci_password
  ciupgrade  = false

  timeouts {
    create = "30m"
    update = "15m"
    delete = "10m"
  }

  lifecycle {
    ignore_changes = [
      network,
    ]
    replace_triggered_by = []
  }
}
