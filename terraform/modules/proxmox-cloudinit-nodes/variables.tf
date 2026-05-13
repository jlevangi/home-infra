variable "vm_name_prefix" {
  description = "Hostname prefix; VMs are named <vm_name_prefix>-<index>."
  type        = string
}

variable "vm_count" {
  description = "Number of VMs to create."
  type        = number
}

variable "target_nodes" {
  description = "Proxmox target nodes. If shorter than vm_count, Terraform cycles through the list."
  type        = list(string)
}

variable "template_name" {
  description = "Proxmox template name to clone."
  type        = string
}

variable "proxmox_tags" {
  description = "Proxmox VM tags applied to every node in the stack."
  type        = list(string)
  default     = []
}

variable "start_at_node_boot" {
  description = "Whether the VM should start automatically when the Proxmox host boots."
  type        = bool
  default     = true
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

variable "cpu_numa" {
  description = "Whether to enable NUMA."
  type        = bool
  default     = true
}

variable "memory" {
  description = "Memory in MB."
  type        = number
}

variable "balloon" {
  description = "Balloon memory in MB."
  type        = number
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

variable "vm_storage" {
  description = "Storage pool for the OS disk and cloud-init drive."
  type        = string
}

variable "os_disk_size" {
  description = "OS disk size."
  type        = string
}

variable "data_disk_enabled" {
  description = "Whether to create a second data disk."
  type        = bool
  default     = false
}

variable "data_disk_size" {
  description = "Data disk size when data_disk_enabled is true."
  type        = string
  default     = null
}

variable "data_disk_storage" {
  description = "Storage pool for the second data disk when enabled."
  type        = string
  default     = null
}

variable "nic_name" {
  description = "Proxmox bridge interface."
  type        = string
}

variable "macaddr_prefix" {
  description = "MAC prefix including the last separator and any shared nibble, for example 76:5A:F2:57:5B:0."
  type        = string
}

variable "ip_base" {
  description = "Base IP fragment; the final octet is assembled by appending ip_offset + index."
  type        = string
}

variable "ip_offset" {
  description = "1-based numeric suffix offset appended to ip_base for the first VM."
  type        = number
}

variable "subnet_mask" {
  description = "Subnet prefix length."
  type        = string
}

variable "gateway" {
  description = "Default gateway."
  type        = string
}

variable "nameserver" {
  description = "DNS nameserver or comma-separated list supported by Proxmox cloud-init."
  type        = string
}

variable "search_domain" {
  description = "DNS search domain."
  type        = string
}

variable "ssh_key" {
  description = "SSH public key for VM access."
  type        = string
  sensitive   = true
}

variable "ci_user" {
  description = "Cloud-init username."
  type        = string
}

variable "ci_password" {
  description = "Cloud-init user password."
  type        = string
  sensitive   = true
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
