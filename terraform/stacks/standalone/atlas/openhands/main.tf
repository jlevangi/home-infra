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
}

variable "api_url" {
  description = "Atlas Proxmox API endpoint."
  type        = string
  default     = "https://172.20.20.6:8006/api2/json"
}

variable "token_id" {
  description = "Proxmox API token ID."
  type        = string
}

variable "token_secret" {
  description = "Proxmox API token secret."
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

module "node" {
  source = "../../../../modules/proxmox-cloudinit-nodes"

  vm_name_prefix    = "openhands"
  vm_names          = ["openhands"]
  vm_count          = 1
  vm_ids            = [303]
  target_nodes      = ["atlas"]
  template_name     = "debian12-server-template"
  proxmox_tags      = ["dev", "openhands", "standalone"]
  cpu_cores         = 4
  cpu_numa          = false
  memory            = 8192
  balloon           = 0
  vm_storage        = "local-lvm"
  cloudinit_storage = "local-lvm"
  os_disk_size      = "80G"
  nic_name          = "vmbr0"
  macaddr_prefix    = "76:5A:F3:03:00:0"
  ip_base           = "172.20.22."
  ip_offset         = 11
  subnet_mask       = "22"
  gateway           = "172.20.20.1"
  nameserver        = "172.20.20.4"
  search_domain     = "levangie.org"
  ssh_key           = var.ssh_key
  ci_user           = var.ci_user
  ci_password       = var.ci_password
  startup_order     = 8
}
