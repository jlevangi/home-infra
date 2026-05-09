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

resource "proxmox_vm_qemu" "gpu_worker" {
  name        = var.vm_name
  vmid        = var.vm_id
  target_node = var.proxmox_host

  clone      = var.template_name
  full_clone = "true"

  agent   = 1
  os_type = "cloud-init"
  onboot  = true
  bios    = "ovmf"
  machine = "q35"

  cpu {
    cores   = 12
    sockets = 1
    type    = "host"
    numa    = true
  }

  memory   = 32768
  balloon  = 32768
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  efidisk {
    storage = var.vm_storage
    efitype = "4m"
  }

  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.vm_storage
  }

  disk {
    slot    = "scsi0"
    size    = var.os_disk_size
    type    = "disk"
    storage = var.vm_storage
  }

  # Longhorn data disk (mounted at /var/lib/longhorn by Ansible)
  disk {
    slot    = "scsi1"
    size    = var.data_disk_size
    type    = "disk"
    storage = var.data_disk_storage
  }

  pci {
    id     = "0"
    raw_id = var.gpu_pci_address
    pcie   = true
    rombar = true
  }

  pci {
    id     = "1"
    raw_id = var.gpu_audio_pci_address
    pcie   = true
    rombar = true
  }

  network {
    id      = 0
    model   = "virtio"
    bridge  = var.nic_name
    macaddr = var.mac_address
  }

  ipconfig0    = "ip=${var.ip_address}/${var.subnet_mask},gw=${var.gateway}"
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
