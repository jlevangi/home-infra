variable "ssh_key" {
  description = "SSH public key for VM access"
  type        = string
  sensitive   = true
}

variable "proxmox_host" {
  description = "Proxmox target node for the dedicated GPU worker."
  type        = string
  default     = "atlas"
}

variable "vm_name" {
  description = "Hostname of the dedicated GPU worker VM."
  type        = string
  default     = "k3s-prod-worker-gpu-1"
}

variable "vm_id" {
  description = "Fixed VMID for the dedicated GPU worker."
  type        = number
  default     = 107
}

variable "template_name" {
  description = "Proxmox template name. Must exist on Atlas before apply."
  default     = "debian12-server-template"
}

variable "nic_name" {
  default = "vmbr0"
}

variable "vm_storage" {
  description = "Proxmox storage pool for OS disk + cloud-init drive."
  type        = string
  default     = "local-lvm"
}

variable "os_disk_size" {
  description = "GPU worker OS disk size."
  type        = string
  default     = "80G"
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
  description = "Atlas Proxmox API token ID (e.g. terraform@pam!tf-token)"
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

variable "ip_address" {
  description = "Static IP for the GPU worker node."
  type        = string
  default     = "172.20.20.107"
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

variable "mac_address" {
  description = "Reserved MAC address for the dedicated GPU worker."
  type        = string
  default     = "76:5A:F1:57:5A:07"
}

variable "gpu_pci_address" {
  description = "Atlas PCI address for the Quadro P4000."
  type        = string
  default     = "0000:03:00.0"
}

variable "gpu_audio_pci_address" {
  description = "Atlas PCI address for the Quadro P4000 HDMI audio function."
  type        = string
  default     = "0000:03:00.1"
}
