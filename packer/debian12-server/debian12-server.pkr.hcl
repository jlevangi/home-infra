# Packer template for Debian 12 Server on Proxmox
# This creates a VM template with qemu-guest-agent and cloud-init pre-configured

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# Variables - override in variables.pkrvars.hcl or via command line
variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL"
}

variable "proxmox_username" {
  type        = string
  description = "Proxmox API username (e.g., root@pam or user@pve!token-id)"
}

variable "proxmox_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token"
}

variable "proxmox_node" {
  type        = string
  default     = "pve1"
  description = "Proxmox node to build on"
}

variable "iso_file" {
  type        = string
  default     = "local:iso/debian-12.8.0-amd64-netinst.iso"
  description = "Path to Debian ISO on Proxmox storage"
}

variable "vm_id" {
  type        = number
  default     = 9000
  description = "VM ID for the template"
}

variable "template_name" {
  type        = string
  default     = "debian12-server-template"
  description = "Name for the VM template"
}

variable "storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Storage pool for VM disk"
}

variable "ssh_username" {
  type        = string
  default     = "packer"
  description = "SSH username for provisioning"
}

variable "ssh_password" {
  type        = string
  sensitive   = true
  default     = "packer"
  description = "SSH password for provisioning"
}

source "proxmox-iso" "debian12" {
  # Proxmox connection
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = true
  node                     = var.proxmox_node

  # VM settings
  vm_id                = var.vm_id
  vm_name              = var.template_name
  template_description = "Debian 12 Server Template - Built with Packer"

  # ISO
  iso_file         = var.iso_file
  iso_storage_pool = "local"
  unmount_iso      = true

  # System
  qemu_agent      = true
  scsi_controller = "virtio-scsi-pci"
  os              = "l26"
  bios            = "seabios"

  # CPU & Memory
  cores  = 2
  memory = 2048

  # Network
  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Disk
  disks {
    disk_size    = "20G"
    storage_pool = var.storage_pool
    type         = "scsi"
    format       = "raw"
  }

  # Cloud-init drive
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  # Boot command for Debian preseed
  boot_command = [
    "<esc><wait>",
    "auto url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "hostname=debian-template ",
    "domain=local ",
    "interface=auto ",
    "netcfg/get_ipaddress= ",
    "netcfg/get_netmask= ",
    "netcfg/get_gateway= ",
    "netcfg/get_nameservers= ",
    "netcfg/confirm_static=true ",
    "<enter>"
  ]
  boot_wait = "5s"

  # HTTP server for preseed file
  http_directory = "http"

  # SSH settings for provisioning
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "20m"
}

build {
  sources = ["source.proxmox-iso.debian12"]

  # Install essential packages
  provisioner "shell" {
    inline = [
      "echo 'Installing essential packages...'",
      "sudo apt-get update",
      "sudo apt-get install -y qemu-guest-agent cloud-init curl wget gnupg2 ca-certificates",
      "sudo systemctl enable qemu-guest-agent",

      "echo 'Configuring cloud-init...'",
      "sudo systemctl enable cloud-init",

      "echo 'Cleaning up...'",
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",

      "echo 'Removing machine-id for proper cloning...'",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",

      "echo 'Clearing SSH host keys (will regenerate on first boot)...'",
      "sudo rm -f /etc/ssh/ssh_host_*",

      "echo 'Template preparation complete!'"
    ]
  }
}
