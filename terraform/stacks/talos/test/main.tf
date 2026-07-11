terraform {
  required_version = ">= 1.0"

  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc08"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.api_url
  pm_api_token_id     = var.token_id
  pm_api_token_secret = var.token_secret
  pm_tls_insecure     = true
  pm_log_enable       = true
  pm_log_file         = "tf-plugin-proxmox.log"
  pm_debug            = true
  pm_log_levels = {
    _default    = "debug"
    _capturelog = ""
  }
}

variable "api_url" {
  description = "Atlas Proxmox API endpoint."
  type        = string
  default     = "https://172.20.20.6:8006/api2/json"
}

variable "token_id" {
  description = "Atlas Proxmox API token ID."
  type        = string
}

variable "token_secret" {
  description = "Atlas Proxmox API token secret."
  type        = string
  sensitive   = true
}

variable "proxmox_hosts" {
  description = "Atlas target nodes used for Talos VMs."
  type        = list(string)
  default     = ["atlas"]
}

variable "template_name" {
  description = "Talos template name on Atlas."
  type        = string
  default     = "talos-v1.12.6-template"
}

variable "cluster_name" {
  description = "Talos cluster name."
  type        = string
  default     = "talos-test"
}

variable "controlplane_name_prefix" {
  description = "Hostname prefix for Talos control-plane nodes."
  type        = string
  default     = "talos-test-cp"
}

variable "worker_name_prefix" {
  description = "Hostname prefix for Talos worker nodes."
  type        = string
  default     = "talos-test-worker"
}

variable "controlplane_count" {
  description = "Number of control-plane nodes."
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker nodes."
  type        = number
  default     = 2
}

variable "vm_cores" {
  description = "CPU cores per Talos node."
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "Memory in MB per Talos node."
  type        = number
  default     = 4096
}

variable "vm_disk_size" {
  description = "Root disk size per Talos node."
  type        = string
  default     = "40G"
}

variable "vm_storage" {
  description = "Storage pool for Talos VM disks."
  type        = string
  default     = "tank"
}

variable "nic_name" {
  description = "Proxmox bridge interface."
  type        = string
  default     = "vmbr0"
}

variable "ip_base" {
  description = "Base IP fragment; Talos node IPs become .131+."
  type        = string
  default     = "172.20.20.13"
}

variable "subnet_mask" {
  description = "Subnet prefix length."
  type        = string
  default     = "22"
}

variable "gateway" {
  description = "Default gateway."
  type        = string
  default     = "172.20.20.1"
}

variable "nameserver" {
  description = "DNS nameserver or comma-separated list."
  type        = string
  default     = "172.20.20.4"
}

variable "install_disk" {
  description = "Block device Talos should install onto."
  type        = string
  default     = "/dev/sda"
}

variable "machine_config_apply_mode" {
  description = "How Talos config apply reaches nodes: reported or static."
  type        = string
  default     = "reported"

  validation {
    condition     = contains(["reported", "static"], var.machine_config_apply_mode)
    error_message = "machine_config_apply_mode must be either 'reported' or 'static'."
  }
}

variable "talos_longhorn_data_path" {
  description = "Host path Longhorn should use on Talos nodes."
  type        = string
  default     = "/var/mnt/longhorn"
}

variable "talos_longhorn_volume_name" {
  description = "Talos UserVolumeConfig name for the Longhorn data volume."
  type        = string
  default     = "longhorn"
}

variable "talos_longhorn_volume_disk_selector" {
  description = "CEL expression used by Talos UserVolumeConfig to select the disk."
  type        = string
  default     = ""
}

variable "talos_longhorn_volume_min_size" {
  description = "Minimum size for the Talos Longhorn user volume."
  type        = string
  default     = "2GiB"
}

variable "talos_longhorn_volume_max_size" {
  description = "Maximum size for the Talos Longhorn user volume."
  type        = string
  default     = "8GiB"
}

locals {
  nameservers                         = [for value in split(",", var.nameserver) : trimspace(value) if trimspace(value) != ""]
  talos_longhorn_volume_disk_selector = var.talos_longhorn_volume_disk_selector != "" ? var.talos_longhorn_volume_disk_selector : "disk.dev_path == '${var.install_disk}'"

  controlplane_nodes = {
    for index in range(var.controlplane_count) :
    format("%s-%d", var.controlplane_name_prefix, index + 1) => {
      ip          = format("%s%d", var.ip_base, index + 1)
      role        = "controlplane"
      target_node = element(var.proxmox_hosts, index)
    }
  }

  worker_nodes = {
    for index in range(var.worker_count) :
    format("%s-%d", var.worker_name_prefix, index + 1) => {
      ip          = format("%s%d", var.ip_base, var.controlplane_count + index + 1)
      role        = "worker"
      target_node = element(var.proxmox_hosts, var.controlplane_count + index)
    }
  }

  nodes              = merge(local.controlplane_nodes, local.worker_nodes)
  controlplane_names = sort(keys(local.controlplane_nodes))
  worker_names       = sort(keys(local.worker_nodes))
  controlplane_ip    = local.controlplane_nodes[local.controlplane_names[0]].ip
  cluster_endpoint   = "https://${local.controlplane_ip}:6443"

  node_network_patch = {
    for name, node in local.nodes : name => yamlencode({
      machine = {
        network = {
          nameservers = local.nameservers
          interfaces = [{
            deviceSelector = {
              driver = "virtio_net"
            }
            addresses = ["${node.ip}/${var.subnet_mask}"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.gateway
            }]
          }]
        }
        install = {
          disk = var.install_disk
        }
      }
    })
  }

  node_hostname_patch = {
    for name, _ in local.nodes : name => yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = name
    })
  }

  node_longhorn_kubelet_patch = {
    for name, _ in local.nodes : name => yamlencode({
      machine = {
        kubelet = {
          extraMounts = [{
            destination = var.talos_longhorn_data_path
            type        = "bind"
            source      = var.talos_longhorn_data_path
            options     = ["bind", "rshared", "rw"]
          }]
        }
      }
    })
  }

  node_longhorn_user_volume_patch = {
    for name, _ in local.nodes : name => yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = var.talos_longhorn_volume_name
      provisioning = {
        diskSelector = {
          match = local.talos_longhorn_volume_disk_selector
        }
        grow    = false
        minSize = var.talos_longhorn_volume_min_size
        maxSize = var.talos_longhorn_volume_max_size
      }
    })
  }
}

module "vms" {
  source = "../../../modules/proxmox-talos-nodes"

  nodes              = local.nodes
  template_name      = var.template_name
  start_at_node_boot = false
  cpu_cores          = var.vm_cores
  memory             = var.vm_memory
  vm_disk_size       = var.vm_disk_size
  vm_storage         = var.vm_storage
  nic_name           = var.nic_name
}

resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for name in local.controlplane_names : local.controlplane_nodes[name].ip]
  nodes                = [for name in sort(keys(local.nodes)) : local.nodes[name].ip]
}

resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.controlplane_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.machine_config_apply_mode == "static" ? each.value.ip : module.vms.node_details[each.key].reported_ipv4_address
  endpoint                    = var.machine_config_apply_mode == "static" ? each.value.ip : module.vms.node_details[each.key].reported_ipv4_address

  config_patches = [
    local.node_network_patch[each.key],
    local.node_longhorn_kubelet_patch[each.key],
    local.node_longhorn_user_volume_patch[each.key],
    local.node_hostname_patch[each.key],
  ]

  depends_on = [module.vms]
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = local.worker_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = var.machine_config_apply_mode == "static" ? each.value.ip : module.vms.node_details[each.key].reported_ipv4_address
  endpoint                    = var.machine_config_apply_mode == "static" ? each.value.ip : module.vms.node_details[each.key].reported_ipv4_address

  config_patches = [
    local.node_network_patch[each.key],
    local.node_longhorn_kubelet_patch[each.key],
    local.node_longhorn_user_volume_patch[each.key],
    local.node_hostname_patch[each.key],
  ]

  depends_on = [module.vms]
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_ip
  endpoint             = local.controlplane_ip

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
  ]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_ip
  endpoint             = local.controlplane_ip

  depends_on = [talos_machine_bootstrap.this]
}
