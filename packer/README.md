# Packer Templates

This directory contains Packer templates for building Proxmox VM templates.

## Prerequisites

Packer 1.16.1 is the tested CLI version; the Debian 12 template pins the `github.com/hashicorp/proxmox` plugin to 1.2.4. The default ISO is Debian 12.13.0 (Bookworm); upload `debian-12.13.0-amd64-netinst.iso` to Proxmox `local:iso` first.

For test builds, set a unique `vm_id` (and a distinct `template_name`) in the variable file to avoid existing templates. Do not overwrite the production template during testing.
1. Install Packer 1.16.1: https://developer.hashicorp.com/packer/downloads
2. Upload Debian 12.13.0 ISO to Proxmox `local:iso`
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

The installer reboots into Debian after installation so Packer can connect over SSH and provision the image. Packer's Proxmox plugin then shuts the VM down cleanly before converting it to a template.

The disk still uses LVM. Root does not grow automatically after a larger clone disk is attached. The temporary `packer` bootstrap account is password-locked and its temporary sudoers grant is removed during provisioning.

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
