variable "ssh_key" {
  description = "SSH public key for VM access"
  type        = string
  sensitive   = true
}

variable "proxmox_hosts" {
  description = "Proxmox target nodes per worker VM. All entries set to 'atlas' on this single-host cluster."
  type        = list(string)
  default     = ["atlas", "atlas", "atlas"]
}

variable "vm_name" {
  description = "Hostname prefix; VMs are named <vm_name>-<index>"
  type        = string
  default     = "k3s-stage-worker"
}

variable "vm_count" {
  description = "Number of worker VMs"
  type        = number
  default     = 3
}

variable "template_name" {
  description = "Proxmox template name. Must exist on Atlas before apply."
  default     = "debian12-server-template"
}

variable "nic_name" {
  default = "vmbr0"
}

variable "vm_storage" {
  description = "Proxmox storage pool for OS disk + cloud-init drive. tank = ZFS pool on Atlas."
  type        = string
  default     = "tank"
}

variable "data_disk_storage" {
  description = "Proxmox storage pool for the Longhorn data disk (scsi1). tank = ZFS pool on Atlas."
  type        = string
  default     = "tank"
}

variable "os_disk_size" {
  description = "Worker OS disk size. /var/lib/longhorn lives on data_disk, so OS disk only carries the OS + container images."
  type        = string
  default     = "80G"
}

variable "data_disk_size" {
  description = "Longhorn data disk size."
  type        = string
  default     = "200G"
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
  default     = "pierce"
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
  description = "Base IP fragment; worker IPs are <ip_base>(index+1) -> .111/.112/.113"
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
