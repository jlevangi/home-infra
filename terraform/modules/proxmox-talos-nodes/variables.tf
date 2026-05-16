variable "nodes" {
  description = "Talos node map keyed by hostname."
  type = map(object({
    ip          = string
    role        = string
    target_node = string
  }))
}

variable "template_name" {
  description = "Talos template name to clone."
  type        = string
}

variable "start_at_node_boot" {
  description = "Whether the VM should start automatically when the Proxmox host boots."
  type        = bool
  default     = false
}

variable "cpu_cores" {
  description = "CPU cores per VM."
  type        = number
}

variable "cpu_sockets" {
  description = "CPU sockets per VM."
  type        = number
  default     = 1
}

variable "cpu_type" {
  description = "Proxmox CPU type."
  type        = string
  default     = "host"
}

variable "memory" {
  description = "Memory in MB."
  type        = number
}

variable "vm_disk_size" {
  description = "Root disk size."
  type        = string
}

variable "vm_storage" {
  description = "Storage pool for the Talos VM disk."
  type        = string
}

variable "scsihw" {
  description = "SCSI controller model."
  type        = string
  default     = "virtio-scsi-pci"
}

variable "bootdisk" {
  description = "Boot disk identifier."
  type        = string
  default     = "scsi0"
}

variable "nic_name" {
  description = "Proxmox bridge interface."
  type        = string
}

variable "skip_ipv6" {
  description = "Skip IPv6 discovery through the guest agent."
  type        = bool
  default     = true
}

variable "create_timeout" {
  description = "Terraform create timeout."
  type        = string
  default     = "30m"
}

variable "update_timeout" {
  description = "Terraform update timeout."
  type        = string
  default     = "15m"
}

variable "delete_timeout" {
  description = "Terraform delete timeout."
  type        = string
  default     = "10m"
}
