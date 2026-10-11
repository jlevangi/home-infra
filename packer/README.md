# Packer Templates

This directory contains Packer templates for building Proxmox VM templates.

## Prerequisites

Packer 1.16.1 is the tested CLI version; the Debian 13 template pins the `github.com/hashicorp/proxmox` plugin to 1.2.4. The default ISO is Debian 13.7.0 (Trixie); upload `debian-13.7.0-amd64-netinst.iso` to Proxmox `local:iso` first.

For test builds, set a unique `vm_id` (and a distinct `template_name`) in the variable file to avoid existing templates. Do not overwrite the production template during testing.
1. Install Packer 1.16.1: https://developer.hashicorp.com/packer/downloads
2. Upload Debian 13.7.0 ISO to Proxmox `local:iso`
3. Create a Proxmox API token for Packer

## Building the Debian 13 Server Template

```bash
cd packer/debian13-server

# Copy and configure variables
cp variables.pkrvars.hcl.example variables.pkrvars.hcl
# Edit variables.pkrvars.hcl with your Proxmox credentials

# Initialize Packer plugins
packer init debian13-server.pkr.hcl

# Build the template
packer build -var-file=variables.pkrvars.hcl debian13-server.pkr.hcl
```

## What's Included in the Template

The template includes:
- **qemu-guest-agent** - For Proxmox VM management
- **cloud-init** - For VM customization on first boot
- **SSH server** - For Ansible provisioning
- **Basic utilities** - curl, wget, gnupg2, ca-certificates, python3

The installer reboots into Debian after installation so Packer can connect over SSH and provision the image. Packer's Proxmox plugin then shuts the VM down cleanly before converting it to a template.

The disk is a single ext4 root partition (no swap, no LVM) on a 10G template disk. Cloud-init's growpart expands root to the clone's disk size on first boot. The default cloud-init user is `ansible`; Terraform's `ciuser` still overrides it per VM. GRUB logs to both the VGA console and `ttyS0`, and the template has a serial socket, so boot failures can be captured with `qm terminal`. The temporary `packer` bootstrap account is password-locked and its temporary sudoers grant is removed during provisioning.

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
