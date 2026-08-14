terraform {
  required_version = ">= 1.0"

  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc08"
    }
  }
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

variable "api_url" {
  description = "elitedesk-1 Proxmox API endpoint."
  type        = string
  default     = "https://172.20.20.7:8006/api2/json"
}

variable "token_id" {
  type = string
}

variable "token_secret" {
  type      = string
  sensitive = true
}

variable "ssh_key" {
  type      = string
  sensitive = true
}

variable "ci_user" {
  type    = string
  default = "ansible"
}

variable "ci_password" {
  type      = string
  sensitive = true
}

variable "template_name" {
  type    = string
  default = "debian12-server-template-elitedesk-1"
}

variable "vm_storage" {
  type    = string
  default = "local-lvm"
}

resource "proxmox_vm_qemu" "cp" {
  name        = "k3s-prod-cp-4"
  vmid        = 111
  target_node = "elitedesk-1"
  tags        = "k3s;prod"
  description = "Managed by Terraform."

  clone      = var.template_name
  full_clone = true

  agent              = 1
  os_type            = "cloud-init"
  start_at_node_boot = true

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
  }

  memory  = 8192
  balloon = 8192
  scsihw  = "virtio-scsi-pci"

  disk {
    format  = "raw"
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.vm_storage
  }

  disk {
    discard    = true
    emulatessd = true
    format     = "raw"
    replicate  = false
    slot       = "scsi0"
    size       = "40G"
    type       = "disk"
    storage    = var.vm_storage
  }

  network {
    id      = 0
    model   = "virtio"
    bridge  = "vmbr0"
    macaddr = "76:5A:F1:57:5A:14"
  }

  ipconfig0    = "ip=172.20.20.111/22,gw=172.20.20.1"
  nameserver   = "172.20.20.4"
  searchdomain = "local"

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
      bootdisk,
      clone,
      disk,
      network,
    ]
  }
}

output "cp_ip" {
  value = "172.20.20.111"
}
