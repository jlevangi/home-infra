# Packer template for Debian 13 Server on Proxmox
# This creates a VM template with qemu-guest-agent and cloud-init pre-configured

packer {
  required_plugins {
    proxmox = {
      version = "= 1.2.4"
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
  default     = "atlas"
  description = "Proxmox node to build on"
}

variable "iso_file" {
  type        = string
  default     = "local:iso/debian-13.7.0-amd64-netinst.iso"
  description = "Path to Debian ISO on Proxmox storage"
}

variable "vm_id" {
  type        = number
  default     = 9010
  description = "VM ID for the template"
}

variable "template_name" {
  type        = string
  default     = "debian13-server-template"
  description = "Name for the VM template"
}

variable "storage_pool" {
  type        = string
  default     = "tank"
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

variable "ci_user" {
  type        = string
  default     = "ansible"
  description = "Default cloud-init user baked into the image"
}

source "proxmox-iso" "debian13" {
  # Proxmox connection
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = true
  node                     = var.proxmox_node

  # VM settings
  vm_id                = var.vm_id
  vm_name              = var.template_name
  template_description = "Debian 13 Server Template - Built with Packer ${timestamp()}"
  tags                 = "debian13;template"

  # ISO
  boot_iso {
    type             = "scsi"
    iso_file         = var.iso_file
    iso_storage_pool = "local"
    unmount          = true
  }

  # System
  qemu_agent      = true
  scsi_controller = "virtio-scsi-single"
  os              = "l26"
  bios            = "seabios"
  cpu_type        = "host"
  serials         = ["socket"]

  # CPU & Memory
  cores  = 2
  memory = 2048

  # Network
  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Disk: kept small; clones grow root on first boot.
  disks {
    disk_size    = "10G"
    storage_pool = var.storage_pool
    type         = "scsi"
    format       = "raw"
    discard      = true
    ssd          = true
    io_thread    = true
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
  sources = ["source.proxmox-iso.debian13"]

  provisioner "shell" {
    inline = [
      "echo 'Installing essential packages...'",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent cloud-init cloud-guest-utils curl wget gnupg ca-certificates python3",

      "echo 'Configuring cloud-init...'",
      "printf 'datasource_list: [NoCloud, ConfigDrive]\\nsystem_info:\\n  default_user:\\n    name: ${var.ci_user}\\n' | sudo tee /etc/cloud/cloud.cfg.d/99-pve.cfg",

      "echo 'Enabling serial console...'",
      "sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"console=tty0 console=ttyS0,115200\"/' /etc/default/grub",
      "sudo update-grub",

      "echo 'Cleaning up...'",
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo cloud-init clean --logs --seed",
      "sudo rm -rf /var/lib/apt/lists/*",

      "echo 'Removing machine-id for proper cloning...'",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",

      "echo 'Clearing SSH host keys (will regenerate on first boot)...'",
      "sudo rm -f /etc/ssh/ssh_host_*",

      "sudo passwd -l ${var.ssh_username}",
      "sudo rm -f /etc/sudoers.d/packer",
      "echo 'Template preparation complete!'"
    ]
  }
}
