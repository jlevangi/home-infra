#Set your public SSH key here
variable "ssh_key" {
  description = "SSH public key for VM access"
  type        = string
  sensitive   = true
  # No default - must be set in terraform.tfvars
}
#Establish which Proxmox host you'd like to spin a VM up on
variable "proxmox_hosts" {
  description = "List of Proxmox hosts"
  #type        = list(string) # Uncomment to use the list below when using shared storage.
  type = string
  #default     = ["pve2"] # Used to cycle through Proxmox Nodes. Will go: 1--> 2--> 3--> 1...
  default = "pve2"
}

# Specify VM Name(s)
variable "vm_name" {
  description = "Name of the VM(s) + -##"
  type        = string
  default     = "k3s-stage-worker"
}

# Specify the amount of VMs to be created.
variable "vm_count" {
  description = "Number of new VMs"
  type        = number
  default     = 3
}

#Specify which template name you'd like to use
variable "template_name" {
  default = "debian12-server-template"
}
#Establish which nic you would like to utilize
variable "nic_name" {
  default = "vmbr0"
}
#Establish the VLAN you'd like to use
variable "vlan_num" {
  default = "1"
}
#Provide the url of the host you would like the API to communicate on.
#It is safe to default to setting this as the URL for what you used
#as your `proxmox_host`, although they can be different
variable "api_url" {
  default = "https://172.20.20.12:8006/api2/json"
}
#Blank var for use by terraform.tfvars
variable "token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}
#Blank var for use by terraform.tfvars
variable "token_id" {
  description = "Proxmox API token ID"
  type        = string
}

# Cloud-init user configuration
variable "ci_user" {
  description = "Cloud-init username"
  type        = string
  default     = "ansible"
}

variable "ci_password" {
  description = "Cloud-init user password"
  type        = string
  sensitive   = true
  # No default - must be set in secrets.tfvars or terraform.tfvars
}

# Ansible vault password for decrypting secrets
variable "vault_password" {
  description = "Ansible vault password for decrypting k3s_cluster_vault.yml"
  type        = string
  sensitive   = true
  # No default - terraform will prompt for this when running apply
}

# Network configuration
variable "ip_base" {
  description = "Base IP address for the environment (e.g., '172.20.20.11' for staging)"
  type        = string
  # No default - must be set in terraform.tfvars
}

variable "subnet_mask" {
  description = "Subnet mask for the VMs"
  type        = string
  # No default - must be set in terraform.tfvars
}

variable "gateway" {
  description = "Gateway IP address"
  type        = string
  # No default - must be set in terraform.tfvars
}

variable "nameserver" {
  description = "DNS nameserver"
  type        = string
  # No default - must be set in terraform.tfvars
}

variable "search_domain" {
  description = "DNS search domain"
  type        = string
  # No default - must be set in terraform.tfvars
}
