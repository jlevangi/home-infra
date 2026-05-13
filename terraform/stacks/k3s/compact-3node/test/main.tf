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
  master_group = "k3s_cluster_test_master"
  worker_group = "k3s_cluster_test_workers"
  master_name  = module.nodes.vm_names[0]
  worker_names = slice(module.nodes.vm_names, 1, length(module.nodes.vm_names))
}

variable "api_url" {
  description = "Proxmox API endpoint."
  type        = string
  default     = "https://172.20.20.12:8006/api2/json"
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

variable "vault_password" {
  description = "Compatibility variable for existing tfvars files."
  type        = string
  sensitive   = true
  default     = null
}

variable "proxmox_hosts" {
  description = "Legacy compact-cluster Proxmox host placement."
  type        = list(string)
  default     = ["pve2"]
}

variable "vm_name_prefix" {
  description = "Hostname prefix for compact-cluster nodes."
  type        = string
  default     = "k3s-test-node"
}

variable "vm_count" {
  description = "Number of nodes in the compact cluster."
  type        = number
  default     = 3
}

variable "template_name" {
  description = "Proxmox template name."
  type        = string
  default     = "debian12-server-template"
}

variable "proxmox_tags" {
  description = "Proxmox tags applied to compact-cluster VMs."
  type        = list(string)
  default     = ["k3s", "test"]
}

variable "nic_name" {
  description = "Proxmox bridge interface."
  type        = string
  default     = "vmbr0"
}

variable "vm_storage" {
  description = "Storage pool for the OS disk and cloud-init drive."
  type        = string
  default     = "vm_data"
}

variable "cpu_cores" {
  description = "CPU cores per VM."
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
  default     = 0
}

variable "os_disk_size" {
  description = "OS disk size."
  type        = string
  default     = "40G"
}

variable "ip_base" {
  description = "Base IP fragment; node IPs become .121-.123."
  type        = string
  default     = "172.20.20.12"
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
  source = "../../../../modules/proxmox-cloudinit-nodes"

  vm_name_prefix = var.vm_name_prefix
  vm_count       = var.vm_count
  target_nodes   = var.proxmox_hosts
  template_name  = var.template_name
  proxmox_tags   = var.proxmox_tags
  cpu_cores      = var.cpu_cores
  memory         = var.memory
  balloon        = var.balloon
  vm_storage     = var.vm_storage
  os_disk_size   = var.os_disk_size
  nic_name       = var.nic_name
  macaddr_prefix = "76:5A:F2:57:5B:0"
  ip_base        = var.ip_base
  ip_offset      = 1
  subnet_mask    = var.subnet_mask
  gateway        = var.gateway
  nameserver     = var.nameserver
  search_domain  = var.search_domain
  ssh_key        = var.ssh_key
  ci_user        = var.ci_user
  ci_password    = var.ci_password
}
