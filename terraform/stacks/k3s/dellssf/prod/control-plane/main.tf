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
  description = "dell-sff Proxmox API endpoint."
  type        = string
  default     = "https://172.20.20.14:8006/api2/json"
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

# cp-3 predates the move to the 'ansible' cloud-init user; it was built with
# 'pierce'. Kept as-is so this stack matches the live VM instead of planning a
# cloud-init rewrite on a running control-plane node.
variable "ci_user" {
  type    = string
  default = "pierce"
}

variable "ci_password" {
  type      = string
  sensitive = true
}

variable "template_name" {
  type    = string
  default = "debian12-server-template"
}

# cp-3's disks landed on ssd2 during the atlas -> dellssf live migration;
# dell-sff's local-lvm thin pool is only ~54G and too small for a 40G node.
variable "vm_storage" {
  type    = string
  default = "ssd2"
}

resource "proxmox_vm_qemu" "cp" {
  name        = "k3s-prod-cp-3"
  vmid        = 100
  target_node = "dellssf"
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
    macaddr = "76:5A:F1:57:5A:13"
  }

  ipconfig0    = "ip=172.20.20.106/22,gw=172.20.20.1"
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

  # clone/full_clone are create-time only. cp-3 was imported into this stack
  # after being live-migrated from atlas, so the provider cannot read them back
  # and would otherwise plan a destroy/recreate of a running control-plane node.
  lifecycle {
    ignore_changes = [
      bootdisk,
      clone,
      disk,
      full_clone,
      network,
    ]
  }
}

output "cp_ip" {
  value = "172.20.20.106"
}
