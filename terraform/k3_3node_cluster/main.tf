terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      version = "3.0.2-rc03"
    }
  }
  required_version = ">= 1.0"
}

provider "proxmox" {
  # References our vars.tf file to plug in the api_url 
  pm_api_url = var.api_url
  # References our secrets.tfvars file to plug in our token_id
  pm_api_token_id = var.token_id
  # References our secrets.tfvars to plug in our token_secret 
  pm_api_token_secret = var.token_secret
  # Default to `true` unless you have TLS working within your pve setup 
  pm_tls_insecure = true	# Added the following lines to enable verbose logging.
  pm_log_enable   = true
  pm_log_file     = "tf-plugin-proxmox.log"
  pm_debug = true
  pm_log_levels   = {
        _default        = "debug"
        _capturelog     = ""
	}
}

# Creates a proxmox_vm_qemu entity named "terraform"
resource "proxmox_vm_qemu" "terraform" {
#  name = var.vm_name
  name = "${var.vm_name}-${count.index + 1}"		    # VM Name + number created
  count = var.vm_count                              # Establishes how many instances will be created 
  # target_node = element(var.proxmox_hosts, count.index % length(var.proxmox_hosts)) Uncomment when using a list of Proxmox nodes using Shared Storage.
  target_node = var.proxmox_hosts

  # References our vars.tf file to plug in our template name
  clone = var.template_name
  # Creates a full clone, rather than linked clone 
  # https://pve.proxmox.com/wiki/VM_Templates_and_Clones
  full_clone  = "true"

  # VM Settings. `agent = 1` enables qemu-guest-agent
  agent = 1
  os_type = "cloud-init"
  
  # CPU configuration for v3.x
  cpu {
    cores = 2
    sockets = 1
    type = "host"
  }
  
  memory = 2048  # Reduced for K3s - can be increased if needed
  scsihw = "virtio-scsi-pci"
  bootdisk = "scsi0"
  
  disk {
    slot = "scsi0"  # Must be string format like 'scsi0' not numeric
    size = "20G"    # Reduced size for K3s
    type = "disk"   # Must be 'disk', 'cdrom', 'cloudinit', or 'ignore'
    storage = "local-lvm" # Name of storage local to the host you are spinning the VM up on
    # SSD and discard options may not be available in v3.x - removed for compatibility
    #iothread = 1
  }

  # Cloud-init drive - required for cloud-init to work properly
  disk {
    slot = "ide2"
    type = "cloudinit"
    storage = "local-lvm"
  }

  network {
    id = 0  # Required network ID for v3.x
    model = "virtio"
    bridge = var.nic_name
#    tag = var.vlan_num # This tag can be left off if you are not taking advantage of VLANs
    macaddr  = "76:5A:F1:57:5A:0${count.index + 1}"  # Updated MAC address pattern
  }

  # Updated IP configuration for K3s cluster
  ipconfig0 = "ip=172.20.20.10${count.index + 1}/24,gw=172.20.20.1"
  nameserver = "172.20.20.4"
  searchdomain = "local"

  # Cloud-init configuration
  sshkeys = var.ssh_key
  
  # Cloud-init user configuration
  ciuser = var.ci_user
  cipassword = var.ci_password
  
  # Enable automatic package upgrades via cloud-init
  ciupgrade = true

  lifecycle {
    ignore_changes = [
      network,
    ]
  }
}

# Null resource to run Ansible after all VMs are created
resource "null_resource" "k3s_deployment" {
  depends_on = [proxmox_vm_qemu.terraform]
  
  # Only run when all VMs are created
  count = var.vm_count == length(proxmox_vm_qemu.terraform) ? 1 : 0
  
  provisioner "local-exec" {
    command = "env && sleep 180 && cd ../../ && ANSIBLE_ROLES_PATH=./ansible/roles ANSIBLE_VAULT_PASSWORD_FILE=~/.ansible_vault_pass ansible-playbook -i ansible/k3s-inventory ansible/playbooks/k3s-deploy-roles.yml -v"
    working_dir = path.module
  }
  
  # Trigger re-run if any VM changes
  triggers = {
    vm_ids = join(",", proxmox_vm_qemu.terraform[*].id)
  }
}