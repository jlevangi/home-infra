terraform {
  required_version = ">= 1.0"

  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc07"
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
  inventory_group = "k3s_cluster_test_master"
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
  description = "Atlas target nodes per control-plane VM."
  type        = list(string)
  default     = ["atlas", "atlas"]
}

variable "vm_name_prefix" {
  description = "Hostname prefix for control-plane nodes."
  type        = string
  default     = "k3s-test-cp"
}

variable "vm_count" {
  description = "Number of control-plane VMs."
  type        = number
  default     = 1
}

variable "vm_ids" {
  description = "Fixed Proxmox VMIDs for control-plane VMs."
  type        = list(number)
  default     = [121]
}

variable "template_name" {
  description = "Proxmox template name."
  type        = string
  default     = "debian12-server-template"
}

variable "proxmox_tags" {
  description = "Proxmox tags applied to control-plane VMs."
  type        = list(string)
  default     = ["k3s", "test"]
}

variable "nic_name" {
  description = "Proxmox bridge interface."
  type        = string
  default     = "vmbr0"
}

variable "vm_storage" {
  description = "Storage pool for control-plane disks."
  type        = string
  default     = "ssd3"
}

variable "cpu_cores" {
  description = "CPU cores per control-plane VM."
  type        = number
  default     = 4
}

variable "memory" {
  description = "Memory in MB."
  type        = number
  default     = 8192
}

variable "balloon" {
  description = "Balloon memory in MB."
  type        = number
  default     = 8192
}

variable "os_disk_size" {
  description = "OS disk size."
  type        = string
  default     = "40G"
}

variable "ip_base" {
  description = "Base IP fragment; CP IPs become .124-.125."
  type        = string
  default     = "172.20.21.12"
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
  nic_name       = var.nic_name
  macaddr_prefix = "76:5A:F2:57:5B:1"
  ip_base        = var.ip_base
  ip_offset      = 4
  subnet_mask    = var.subnet_mask
  gateway        = var.gateway
  nameserver     = var.nameserver
  search_domain  = var.search_domain
  ssh_key        = var.ssh_key
  ci_user        = var.ci_user
  ci_password    = var.ci_password
}
