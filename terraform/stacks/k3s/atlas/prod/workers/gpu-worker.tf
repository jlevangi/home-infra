variable "gpu_worker_name" {
  description = "Hostname of the dedicated GPU worker VM."
  type        = string
  default     = "k3s-prod-worker-gpu-1"
}

variable "gpu_worker_vmid" {
  description = "Fixed VMID for the dedicated GPU worker."
  type        = number
  default     = 107
}

variable "gpu_worker_target_node" {
  description = "Proxmox target node for the dedicated GPU worker."
  type        = string
  default     = "atlas"
}

variable "gpu_worker_mac_address" {
  description = "Reserved MAC address for the dedicated GPU worker."
  type        = string
  default     = "76:5A:F1:57:5A:07"
}

variable "gpu_worker_ip_address" {
  description = "Static IP for the GPU worker node."
  type        = string
  default     = "172.20.20.107"
}

variable "gpu_worker_data_disk_size" {
  description = "Longhorn data disk size for the GPU worker."
  type        = string
  default     = "200G"
}

variable "gpu_worker_pci_address" {
  description = "Atlas PCI address for the working live GPU passthrough mapping."
  type        = string
  default     = "0000:03:00"
}

variable "gpu_worker_cpu_cores" {
  description = "CPU cores per socket for the GPU worker."
  type        = number
  default     = 24
}

variable "gpu_worker_cpu_sockets" {
  description = "CPU sockets for the GPU worker (NUMA-aware layout)."
  type        = number
  default     = 2
}

variable "gpu_worker_memory" {
  description = "Memory (MiB) for the GPU worker. 122880 MiB (120 GiB) is the current target now that llama-cpp is no longer serving very large MiniMax-class models. Memory hot-add does NOT work on this VM because hostpci0 (P4000 passthrough) pins the full allocation at start — changing this requires a VM reboot, and total host commit on atlas (322 GiB) needs to stay above the sum of every prod VM's memory."
  type        = number
  default     = 122880
}

variable "gpu_worker_balloon" {
  description = "Balloon target (MiB) for the GPU worker (matches memory; ballooning is effectively disabled because hostpci0 requires pinned memory)."
  type        = number
  default     = 122880
}

variable "gpu_worker_llm_disk_size" {
  description = "Dedicated LLM model storage disk size on the GPU worker."
  type        = string
  default     = "600G"
}

variable "gpu_worker_llm_disk_storage" {
  description = "Proxmox storage pool for the GPU worker LLM model disk. Uses the tank-backed VM disk mounted at /mnt/llm-tank."
  type        = string
  default     = "tank"
}

resource "proxmox_vm_qemu" "gpu_worker" {
  name        = var.gpu_worker_name
  vmid        = var.gpu_worker_vmid
  target_node = var.gpu_worker_target_node
  tags        = length(var.proxmox_tags) > 0 ? join(";", sort(distinct(var.proxmox_tags))) : null
  description = "Managed by Terraform."

  clone      = var.template_name
  full_clone = true

  agent              = 1
  os_type            = "cloud-init"
  start_at_node_boot = true
  bios               = "ovmf"
  machine            = "q35"

  cpu {
    cores   = var.gpu_worker_cpu_cores
    sockets = var.gpu_worker_cpu_sockets
    type    = "host"
    numa    = true
  }

  memory   = var.gpu_worker_memory
  balloon  = var.gpu_worker_balloon
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  efidisk {
    storage = var.vm_storage
    efitype = "4m"
  }

  disk {
    format  = "raw"
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.vm_storage
  }

  disk {
    discard    = true
    emulatessd = true
    format     = "raw"
    replicate  = true
    slot       = "scsi0"
    size       = var.os_disk_size
    type       = "disk"
    storage    = var.vm_storage
  }

  disk {
    format    = "raw"
    replicate = false
    slot      = "scsi1"
    size      = var.gpu_worker_data_disk_size
    type      = "disk"
    storage   = var.data_disk_storage
  }

  disk {
    format    = "raw"
    replicate = true
    slot      = "scsi2"
    size      = var.gpu_worker_llm_disk_size
    type      = "disk"
    storage   = var.gpu_worker_llm_disk_storage
  }

  pci {
    id     = 0
    raw_id = var.gpu_worker_pci_address
    pcie   = true
    rombar = true
  }

  network {
    id      = 0
    model   = "virtio"
    bridge  = var.nic_name
    macaddr = var.gpu_worker_mac_address
  }

  ipconfig0    = "ip=${var.gpu_worker_ip_address}/${var.subnet_mask},gw=${var.gateway}"
  nameserver   = var.nameserver
  searchdomain = var.search_domain

  sshkeys    = var.ssh_key
  ciuser     = var.ci_user
  cipassword = var.ci_password
  ciupgrade  = false

  timeouts {
    create = "30m"
    update = "15m"
    delete = "10m"
  }

  startup_shutdown {
    order            = 4
    shutdown_timeout = -1
    startup_delay    = -1
  }

  lifecycle {
    ignore_changes = [
      bootdisk,
      disk,
      network,
    ]
    replace_triggered_by = []
  }
}
