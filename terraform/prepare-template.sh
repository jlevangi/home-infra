#!/bin/bash
# Script to prepare a Debian/Ubuntu template for K3s cloud-init deployment
# Run this on your template VM before converting it to a template

echo "🚀 Preparing VM template for K3s cloud-init deployment..."

# Update system
echo "📦 Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install essential packages
echo "📦 Installing essential packages..."
apt-get install -y \
    cloud-init \
    qemu-guest-agent \
    curl \
    wget \
    sudo \
    openssh-server \
    ca-certificates \
    software-properties-common \
    apt-transport-https \
    gnupg \
    lsb-release

# Configure cloud-init
echo "☁️ Configuring cloud-init..."
cat > /etc/cloud/cloud.cfg.d/99-pve.cfg << EOF
# This file is generated from the template file
# /usr/share/cloud-init/templates/sources.list.debian.tmpl
datasource_list: [ConfigDrive, NoCloud]
EOF

# Enable services
echo "🔧 Enabling services..."
systemctl enable cloud-init
systemctl enable cloud-init-local
systemctl enable cloud-config
systemctl enable cloud-final
systemctl enable qemu-guest-agent
systemctl enable ssh

# Clean up for template
echo "🧹 Cleaning up for template conversion..."
# Remove SSH keys
rm -f /etc/ssh/ssh_host_*
rm -f /home/*/.ssh/authorized_keys
rm -f /root/.ssh/authorized_keys

# Remove logs
find /var/log -type f -delete
rm -rf /tmp/*
rm -rf /var/tmp/*

# Remove bash history
rm -f /root/.bash_history
rm -f /home/*/.bash_history

# Remove cloud-init artifacts
cloud-init clean --logs

# Remove machine ID
truncate -s 0 /etc/machine-id
rm /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Clear package cache
apt-get clean
apt-get autoremove -y

echo "✅ Template preparation complete!"
echo ""
echo "🔧 Next steps:"
echo "1. Shutdown this VM: sudo shutdown -h now"
echo "2. Convert to template in Proxmox UI"
echo "3. Update template name in variables.tf if different"
echo ""
echo "📋 Template should have:"
echo "- cloud-init package installed ✓"
echo "- qemu-guest-agent installed and enabled ✓"
echo "- SSH server enabled ✓"
echo "- Clean logs and SSH keys ✓"
