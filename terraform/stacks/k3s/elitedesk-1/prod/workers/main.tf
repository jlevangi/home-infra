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
  description = "elitedesk-1 Proxmox API token ID."
  type        = string
}

variable "token_secret" {
  description = "elitedesk-1 Proxmox API token secret."
  type        = string
  sensitive   = true
}

variable "ssh_key" {
  description = "SSH public key for VM access."
  type        = string
  sensitive   = true
}

variable "ci_user" {
  description = "Cloud-init username."
  type        = string
  default     = "ansible"
}

variable "ci_password" {
  description = "Cloud-init user password."
  type        = string
  sensitive   = true
}

variable "template_name" {
  description = "Proxmox template name on elitedesk-1."
  type        = string
  default     = "debian12-server-template-elitedesk-1"
}

variable "proxmox_tags" {
  type    = list(string)
  default = ["k3s", "prod"]
}

variable "nic_name" {
  type    = string
  default = "vmbr0"
}

variable "vm_storage" {
  description = "Storage pool for OS/cloud-init disks on elitedesk-1."
  type        = string
  default     = "local-lvm"
}

variable "data_disk_storage" {
  description = "Storage pool for the Longhorn data disk on elitedesk-1."
  type        = string
  default     = "local-lvm"
}

variable "subnet_mask" {
  type    = string
  default = "22"
}

variable "gateway" {
  type    = string
  default = "172.20.20.1"
}

variable "nameserver" {
  type    = string
  default = "172.20.20.4"
}

variable "search_domain" {
  type    = string
  default = "local"
}

resource "proxmox_vm_qemu" "worker" {
  name        = "k3s-prod-worker-4"
  vmid        = 108
  target_node = "elitedesk-1"
  tags        = join(";", sort(distinct(var.proxmox_tags)))
  description = "Managed by Terraform."

  clone      = var.template_name
  full_clone = true

  agent              = 1
  os_type            = "cloud-init"
  start_at_node_boot = true

  cpu {
    cores   = 12
    sockets = 1
    type    = "host"
  }

  memory  = 24576
  balloon = 0
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
    size       = "80G"
    type       = "disk"
    storage    = var.vm_storage
  }

  # Dedicated Longhorn data disk. Single-replica storage class, so this
  # doesn't need to match atlas's tank/flash split - see the Longhorn
  # single-replica migration notes.
  disk {
    discard   = true
    format    = "raw"
    replicate = false
    slot      = "scsi1"
    size      = "200G"
    type      = "disk"
    storage   = var.data_disk_storage
  }

  network {
    id      = 0
    model   = "virtio"
    bridge  = var.nic_name
    macaddr = "76:5A:F1:57:5A:08"
  }

  ipconfig0    = "ip=172.20.20.108/${var.subnet_mask},gw=${var.gateway}"
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

  startup_shutdown {
    order            = 4
    shutdown_timeout = -1
    startup_delay    = -1
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

output "worker_ip" {
  value = "172.20.20.108"
}
