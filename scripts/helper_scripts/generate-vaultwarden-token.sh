#!/bin/bash

# Script to generate a secure Vaultwarden admin token
# This generates an Argon2 hash that's more secure than a plain text token

echo "🔐 Vaultwarden Admin Token Generator"
echo "=================================="
echo ""

# Check if argon2 is available
if ! command -v argon2 &> /dev/null; then
    echo "❌ argon2 is not installed. Installing..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y argon2
    elif command -v yum &> /dev/null; then
        sudo yum install -y argon2
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y argon2
    else
        echo "Please install argon2 manually and re-run this script"
        exit 1
    fi
fi

# Generate a random token
echo "Generating random admin token..."
RANDOM_TOKEN=$(openssl rand -base64 48)
echo "Random token: $RANDOM_TOKEN"
echo ""

# Generate salt
SALT=$(openssl rand -base64 32)

# Generate Argon2 hash
echo "Generating secure Argon2 hash..."
ARGON2_HASH=$(echo -n "$RANDOM_TOKEN" | argon2 "$SALT" -e -id -k 19456 -t 2 -p 1)

echo ""
echo "✅ Generated Vaultwarden Admin Token:"
echo "======================================"
echo "Plain token (save this securely for manual access): $RANDOM_TOKEN"
echo ""
echo "Argon2 hash (use this in vault_vaultwarden_admin_token):"
echo "$ARGON2_HASH"
echo ""
echo "📝 Next steps:"
echo "1. Add the Argon2 hash to your vault file:"
echo "   ansible-vault edit ansible/group_vars/k3s_cluster_vault.yml"
echo ""
echo "2. Set: vault_vaultwarden_admin_token: \"$ARGON2_HASH\""
echo ""
echo "3. Save the plain token somewhere secure for initial admin access"
echo ""
echo "⚠️  Security note: The Argon2 hash is much more secure than a plain token"
