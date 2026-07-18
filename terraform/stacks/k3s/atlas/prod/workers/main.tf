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

locals {
  inventory_group = "k3s_cluster_prod_workers"
}

variable "api_url" {
  description = "Atlas Proxmox API endpoint."
  type        = string
  default     = "https://172.20.20.6:8006/api2/json"
}

variable "token_id" {
  description = "Atlas Proxmox API token ID."
  type        = string
}

variable "token_secret" {
  description = "Atlas Proxmox API token secret."
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

variable "vault_password" {
  description = "Compatibility variable for existing tfvars files."
  type        = string
  sensitive   = true
  default     = null
}

variable "proxmox_hosts" {
  description = "Atlas target nodes per worker VM."
  type        = list(string)
  default     = ["atlas", "atlas", "atlas"]
}

variable "vm_name_prefix" {
  description = "Hostname prefix for worker nodes."
  type        = string
  default     = "k3s-prod-worker"
}

variable "vm_count" {
  description = "Number of worker VMs."
  type        = number
  default     = 3
}

variable "vm_ids" {
  description = "Fixed Proxmox VMIDs for worker VMs."
  type        = list(number)
  default     = [101, 103, 105]
}

variable "template_name" {
  description = "Proxmox template name."
  type        = string
  default     = "debian12-server-template"
}

variable "proxmox_tags" {
  description = "Proxmox tags applied to worker VMs."
  type        = list(string)
  default     = ["k3s", "prod"]
}

variable "nic_name" {
  description = "Proxmox bridge interface."
  type        = string
  default     = "vmbr0"
}

variable "vm_storage" {
  description = "Storage pool for the OS disk and cloud-init drive."
  type        = string
  default     = "flash"
}

variable "data_disk_storage" {
  description = "Storage pool for the Longhorn data disk."
  type        = string
  default     = "tank"
}

variable "cpu_cores" {
  description = "CPU cores per worker VM."
  type        = number
  default     = 12
}

variable "memory" {
  description = "Memory in MB."
  type        = number
  default     = 24576
}

variable "balloon" {
  description = "Balloon memory in MB."
  type        = number
  default     = 0
}

variable "os_disk_size" {
  description = "OS disk size."
  type        = string
  default     = "80G"
}

variable "data_disk_size" {
  description = "Longhorn data disk size."
  type        = string
  default     = "300G"
}

variable "flash_disk_storage" {
  description = "Storage pool for the current flash-backed Longhorn disk."
  type        = string
  default     = "flash"
}

variable "flash_disk_size" {
  description = "Current flash-backed Longhorn disk size."
  type        = string
  default     = "250G"
}

variable "ip_base" {
  description = "Base IP fragment; worker IPs become .101-.103."
  type        = string
  default     = "172.20.20.10"
}

variable "subnet_mask" {
  description = "Subnet prefix length."
  type        = string
  default     = "22"
}

variable "gateway" {
  description = "Default gateway."
  type        = string
  default     = "172.20.20.1"
}

variable "nameserver" {
  description = "DNS nameserver."
  type        = string
  default     = "172.20.20.4"
}

variable "search_domain" {
  description = "DNS search domain."
  type        = string
  default     = "local"
}

module "nodes" {
  source = "../../../../../modules/proxmox-cloudinit-nodes"

  vm_name_prefix = var.vm_name_prefix
  vm_count       = var.vm_count
  vm_ids         = var.vm_ids
  target_nodes   = var.proxmox_hosts
  template_name  = var.template_name
  proxmox_tags   = var.proxmox_tags
  cpu_cores      = var.cpu_cores
  memory         = var.memory
  balloon        = var.balloon
  vm_storage     = var.vm_storage
  os_disk_size   = var.os_disk_size
  # Tank-backed Longhorn disk (scsi2). Pairs with the longhorn-tank disk-mount
  # task and longhorn-tank StorageClass — see plans/i-need-some-serious-ancient-adleman.md.
  # Note: existing VMs (101/103/105) had this added live via `qm set`; the
  # proxmox module's lifecycle.ignore_changes prevents Terraform from touching
  # disks on existing VMs, so this block only takes effect on fresh deploys.
  data_disk_enabled  = true
  data_disk_size     = "250G"
  data_disk_storage  = var.data_disk_storage
  data_disk_slot     = "scsi2"
  flash_disk_enabled = true
  flash_disk_size    = var.flash_disk_size
  flash_disk_storage = var.flash_disk_storage
  nic_name           = var.nic_name
  macaddr_prefix     = "76:5A:F1:57:5A:0"
  ip_base            = var.ip_base
  ip_offset          = 1
  subnet_mask        = var.subnet_mask
  gateway            = var.gateway
  nameserver         = var.nameserver
  search_domain      = var.search_domain
  ssh_key            = var.ssh_key
  ci_user            = var.ci_user
  ci_password        = var.ci_password
  startup_order      = 4
}
