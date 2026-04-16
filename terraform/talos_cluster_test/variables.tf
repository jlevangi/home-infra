# Proxmox connection
variable "api_url" {
  description = "Proxmox API URL"
  type        = string
  default     = "https://172.20.20.12:8006/api2/json"
}

variable "token_id" {
  description = "Proxmox API token ID"
  type        = string
}

variable "token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_hosts" {
  description = "Proxmox node to create VMs on"
  type        = string
  default     = "pve2"
}

# Template + naming
variable "template_name" {
  description = "Name of the Talos template VM to clone (produced by scripts/helpers/import-talos-template.sh)"
  type        = string
  default     = "talos-v1.12.6-template"
}

variable "vm_name" {
  description = "Base name for cluster VMs; nodes will be named <vm_name>-1..N"
  type        = string
  default     = "talos-test-node"
}

variable "cluster_name" {
  description = "Talos cluster name (used in machine secrets, kubeconfig, talosconfig)"
  type        = string
  default     = "talos-test"
}

# VM sizing
variable "vm_cores" {
  description = "CPU cores per node"
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "Memory in MB per node"
  type        = number
  default     = 4096
}

variable "vm_disk_size" {
  description = "Root disk size per node"
  type        = string
  default     = "20G"
}

variable "vm_storage" {
  description = "Proxmox storage for the VM disk"
  type        = string
  default     = "vm_data"
}

variable "nic_name" {
  description = "Proxmox bridge interface"
  type        = string
  default     = "vmbr0"
}

# Network
variable "ip_base" {
  description = "Base IP for the cluster (e.g. '172.20.20.13' -> nodes at .131/.132/.133)"
  type        = string
}

variable "controlplane_ip" {
  description = "Full static IP of the controlplane node (used as Talos / K8s API endpoint)"
  type        = string
}

variable "subnet_mask" {
  description = "Subnet prefix length"
  type        = string
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "nameserver" {
  description = "Upstream DNS server"
  type        = string
}

# Talos
variable "install_disk" {
  description = "Block device Talos should install/upgrade onto"
  type        = string
  default     = "/dev/sda"
}
