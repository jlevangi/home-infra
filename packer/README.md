# Packer Templates

This directory contains Packer templates for building Proxmox VM templates.

## Prerequisites

1. Install Packer: https://developer.hashicorp.com/packer/downloads
2. Upload Debian ISO to Proxmox storage
3. Create a Proxmox API token for Packer

## Building the Debian 12 Server Template

```bash
cd packer/debian12-server

# Copy and configure variables
cp variables.pkrvars.hcl.example variables.pkrvars.hcl
# Edit variables.pkrvars.hcl with your Proxmox credentials

# Initialize Packer plugins
packer init debian12-server.pkr.hcl

# Build the template
packer build -var-file=variables.pkrvars.hcl debian12-server.pkr.hcl
```

## What's Included in the Template

The template includes:
- **qemu-guest-agent** - For Proxmox VM management
- **cloud-init** - For VM customization on first boot
- **SSH server** - For Ansible provisioning
- **Basic utilities** - curl, wget, gnupg2, ca-certificates, python3

## Template Preparation

The template is prepared for cloning:
- Machine ID is cleared (regenerates on clone)
- SSH host keys are removed (regenerate on first boot)
- Cloud-init is configured for customization

## Updating Templates

To update an existing template:
1. Update the Packer configuration
2. Change `vm_id` to a new ID or delete the old template
3. Re-run the build
4. Update Terraform to reference the new template name
