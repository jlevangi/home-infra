variable "ssh_key" {
  description = "SSH public key for VM access"
  type        = string
  sensitive   = true
}

variable "proxmox_hosts" {
  description = "Proxmox target nodes per CP VM (cp-1 -> hosts[0], cp-2 -> hosts[1], cp-3 -> hosts[2]). Set all entries to the same value to land all VMs on one host."
  type        = list(string)
  default     = ["pve1", "pve2", "pve3"]
}

variable "vm_name" {
  description = "Hostname prefix; VMs are named <vm_name>-<index>"
  type        = string
  default     = "k3s-stage-cp"
}

variable "vm_count" {
  description = "Number of CP VMs"
  type        = number
  default     = 3
}

variable "template_name" {
  description = "Proxmox template name. Must exist on each target host (replicate template to pve1/pve2/pve3 before apply)."
  default     = "debian12-server-template"
}

variable "vm_storage" {
  description = "Proxmox storage pool for the VM disks. Default vm_data matches the existing SSD pool; set to local-lvm to land etcd/CP traffic on a dedicated NVMe pool isolated from Longhorn worker I/O."
  type        = string
  default     = "vm_data"
}

variable "nic_name" {
  default = "vmbr0"
}

variable "vlan_num" {
  default = "1"
}

variable "api_url" {
  default = "https://172.20.20.12:8006/api2/json"
}

variable "token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "token_id" {
  description = "Proxmox API token ID"
  type        = string
}

variable "ci_user" {
  description = "Cloud-init username"
  type        = string
  default     = "ansible"
}

variable "ci_password" {
  description = "Cloud-init user password"
  type        = string
  sensitive   = true
}

variable "vault_password" {
  description = "Ansible vault password for decrypting k3s_cluster_vault.yml"
  type        = string
  sensitive   = true
}

variable "ip_base" {
  description = "Base IP fragment; CP IPs are <ip_base>(index+4) -> .114/.115/.116"
  type        = string
}

variable "subnet_mask" {
  type = string
}

variable "gateway" {
  type = string
}

variable "nameserver" {
  type = string
}

variable "search_domain" {
  type = string
}
