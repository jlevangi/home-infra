variable "ssh_key" {
  description = "SSH public key for VM access"
  type        = string
  sensitive   = true
}

variable "proxmox_hosts" {
  description = "Proxmox target nodes per CP VM. All entries set to 'atlas' on this single-host cluster."
  type        = list(string)
  default     = ["atlas", "atlas"]
}

variable "vm_name" {
  description = "Hostname prefix; VMs are named <vm_name>-<index>"
  type        = string
  default     = "k3s-test-cp"
}

variable "vm_count" {
  description = "Number of CP VMs"
  type        = number
  default     = 2
}

variable "template_name" {
  description = "Proxmox template name. Must exist on Atlas before apply."
  default     = "debian12-server-template"
}

variable "nic_name" {
  default = "vmbr0"
}

variable "vm_storage" {
  description = "Proxmox storage pool for VM disks. local-lvm = SSD-backed thin LVM on Atlas."
  type        = string
  default     = "tank"
}

variable "vlan_num" {
  default = "1"
}

variable "api_url" {
  description = "Atlas Proxmox API endpoint."
  default     = "https://172.20.20.6:8006/api2/json"
}

variable "token_secret" {
  description = "Atlas Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "token_id" {
  description = "Atlas Proxmox API token ID"
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
  description = "Base IP fragment; CP IPs are <ip_base>(index+4) -> .124/.125"
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
