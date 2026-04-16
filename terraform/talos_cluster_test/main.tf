terraform {
  required_version = ">= 1.0"

  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc07"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.7"
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

# Cluster layout: 1 controlplane + 2 workers. Mirror of the Debian/K3s test
# cluster node count (k3s_3node_cluster_test) but running Talos + upstream
# K8s instead of K3s on Debian.
locals {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.controlplane_ip}:6443"

  nodes = {
    "${var.vm_name}-1" = { ip = "${var.ip_base}1", role = "controlplane" }
    "${var.vm_name}-2" = { ip = "${var.ip_base}2", role = "worker" }
    "${var.vm_name}-3" = { ip = "${var.ip_base}3", role = "worker" }
  }

  controlplane_nodes = { for k, v in local.nodes : k => v if v.role == "controlplane" }
  worker_nodes       = { for k, v in local.nodes : k => v if v.role == "worker" }

  # Allow `nameserver` tfvar to hold a single IP or a comma-separated list.
  nameservers = [for n in split(",", var.nameserver) : trimspace(n) if trimspace(n) != ""]

  # Per-node machine config patch: hostname, static IP, install disk.
  # Applied on top of the base controlplane/worker config produced by the
  # talos_machine_configuration data source below.
  node_patch = {
    for name, cfg in local.nodes : name => yamlencode({
      machine = {
        network = {
          hostname    = name
          nameservers = local.nameservers
          interfaces = [{
            deviceSelector = {
              driver = "virtio_net"
            }
            addresses = ["${cfg.ip}/${var.subnet_mask}"]
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
}

# --- Proxmox VMs ------------------------------------------------------------
# Cloned from the Talos template produced by
# scripts/helpers/import-talos-template.sh. Talos ignores cloud-init, so we
# deliberately omit ciuser/cipassword/sshkeys/ipconfig0/nameserver/searchdomain
# and the cloud-init ide2 drive — IP assignment happens via the Talos machine
# config patch below.
resource "proxmox_vm_qemu" "talos" {
  for_each = local.nodes

  name        = each.key
  target_node = var.proxmox_hosts
  clone       = var.template_name
  full_clone  = true

  # Test cluster: do not auto-start when the Proxmox host boots.
  start_at_node_boot = false

  agent = 1

  cpu {
    cores   = var.vm_cores
    sockets = 1
    type    = "host"
  }
  memory   = var.vm_memory
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  disk {
    slot    = "scsi0"
    size    = var.vm_disk_size
    type    = "disk"
    storage = var.vm_storage
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = var.nic_name
  }

  timeouts {
    create = "30m"
    update = "15m"
    delete = "10m"
  }

  lifecycle {
    # Clones may show spurious diffs on disk/network after first apply and
    # the qemu-agent-reported IP changes once the Talos static config takes
    # effect — ignore both to keep re-applies quiet.
    ignore_changes = [network, disk]
  }
}

# --- Talos secrets and per-role machine config -----------------------------
resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = local.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

data "talos_machine_configuration" "worker" {
  cluster_name     = local.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

# Talos client config (for `talosctl` once `terraform output -raw talosconfig`
# is redirected to a file).
data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for _, v in local.controlplane_nodes : v.ip]
  nodes                = [for _, v in local.nodes : v.ip]
}

# --- Apply machine config to each node -------------------------------------
# First boot: Talos comes up in maintenance mode, takes a DHCP lease, and
# reports its IP via qemu-guest-agent (bundled in the Talos template image).
# We reach it at that DHCP address to apply the real config, which includes
# the static IP patch from locals.node_patch above. After apply, Talos reboots
# into its configured state on the static IP.
resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.controlplane_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = proxmox_vm_qemu.talos[each.key].default_ipv4_address
  endpoint                    = proxmox_vm_qemu.talos[each.key].default_ipv4_address

  config_patches = [local.node_patch[each.key]]

  depends_on = [proxmox_vm_qemu.talos]

  lifecycle {
    # After the first apply, the node reboots to its static IP, so
    # default_ipv4_address changes. Don't trigger re-applies on that drift.
    ignore_changes = [node, endpoint]
  }
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = local.worker_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = proxmox_vm_qemu.talos[each.key].default_ipv4_address
  endpoint                    = proxmox_vm_qemu.talos[each.key].default_ipv4_address

  config_patches = [local.node_patch[each.key]]

  depends_on = [proxmox_vm_qemu.talos]

  lifecycle {
    ignore_changes = [node, endpoint]
  }
}

# --- Bootstrap etcd on the controlplane ------------------------------------
# Target the static controlplane IP — after the config apply above, the node
# is reachable there.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controlplane_ip
  endpoint             = var.controlplane_ip

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
  ]
}

# --- Fetch kubeconfig ------------------------------------------------------
# Resource (not data source) — the data source form is deprecated in
# siderolabs/talos v0.10+ and slated for removal in the next minor release.
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controlplane_ip
  endpoint             = var.controlplane_ip

  depends_on = [talos_machine_bootstrap.this]
}
