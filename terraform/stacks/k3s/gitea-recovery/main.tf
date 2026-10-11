terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc10"
    }
  }
}

provider "proxmox" {
  pm_api_url          = "https://172.20.20.6:8006/api2/json"
  pm_api_token_id     = var.token_id
  pm_api_token_secret = var.token_secret
  pm_tls_insecure     = true
  pm_log_enable       = false
  pm_debug            = false
}

variable "token_id" {
  type      = string
  sensitive = true
}
variable "token_secret" {
  type      = string
  sensitive = true
}
variable "ssh_key" {
  type = string
}

module "nodes" {
  source = "../../../modules/proxmox-cloudinit-nodes"

  vm_name_prefix     = "gitea-recovery"
  vm_count           = 1
  vm_ids             = [303]
  target_nodes       = ["elitedesk-1"]
  template_name      = "debian12-server-template-elitedesk-1"
  proxmox_tags       = ["k3s", "recovery"]
  start_at_node_boot = false
  cpu_cores          = 2
  cpu_numa           = false
  cpu_type           = "x86-64-v2-AES"
  memory             = 4096
  balloon            = 0
  vm_storage         = "local-lvm"
  os_disk_size       = "40G"
  nic_name           = "vmbr0"
  macaddr_prefix     = "02:47:49:54:45:0"
  ip_base            = "172.20.21.12"
  ip_offset          = 4
  subnet_mask        = "22"
  gateway            = "172.20.20.1"
  nameserver         = "172.20.20.4,172.20.20.5"
  search_domain      = "local"
  ssh_key            = var.ssh_key
  ci_user            = "ansible"
  ci_password        = null
}
