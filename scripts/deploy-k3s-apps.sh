
#!/bin/bash
# Unified K3s apps deployment script
# Allows redeployment of apps to either cluster with verbosity and help options

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source environment functions
source "$SCRIPT_DIR/lib/environment-functions.sh"

# Ensure ansible/ansible.cfg is present and picked up by ansible-playbook.
require_ansible_config || exit 1

# Default values
TARGET_ENV=""
TARGET_CLUSTER=""
EXTRA_VARS=""
VERBOSITY=""
SHOW_HELP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
	case $1 in
		--prod|--production)
			TARGET_ENV="prod"
			shift
			;;
		--test)
			TARGET_ENV="test"
			shift
			;;
		--stage|--staging)
			TARGET_ENV="stage"
			shift
			;;
		--env)
			if [[ -n "$2" && "$2" != -* ]]; then
				TARGET_ENV="$2"
				shift 2
			else
				echo "❌ Error: --env requires an environment name"
				exit 1
			fi
			;;
		--env=*)
			TARGET_ENV="${1#--env=}"
			shift
			;;
		-v|--verbose)
			VERBOSITY="-v"
			shift
			;;
		-vv)
			VERBOSITY="-vv"
			shift
			;;
		-vvv)
			VERBOSITY="-vvv"
			shift
			;;
		--quiet|-q)
			VERBOSITY=""
			shift
			;;
		--help|-h)
			SHOW_HELP=true
			shift
			;;
		*)
			echo "Unknown option: $1"
			echo "Use --help for usage information"
			exit 1
			;;
	esac
done

# Show help if requested or no target specified
if [[ "$SHOW_HELP" == "true" ]] || [[ -z "$TARGET_ENV" ]]; then
	echo "Usage: $0 [ENVIRONMENT] [OPTIONS]"
	echo ""
	show_environment_help "$0"
	echo "Options:"
	echo "  -v, --verbose          Enable verbose output"
	echo "  -vv, -vvv              Enable more verbose output"
	echo "  -q, --quiet            Disable verbose output"
	echo "  -h, --help             Show this help message"
	echo ""
	if [[ -z "$TARGET_ENV" ]]; then
		echo ""
		echo "❌ Error: Target environment must be specified"
		exit 1
	else
		exit 0
	fi
fi

# Set up target-specific variables using environment functions
if ! setup_environment_vars "$TARGET_ENV"; then
  exit 1
fi

# Set up Ansible extra vars for target cluster
EXTRA_VARS="$EXTRA_VARS -e target_cluster=$TARGET_CLUSTER"

# Apply default verbosity if not explicitly set and environment has a default
if [[ -z "$VERBOSITY" && -n "$DEFAULT_VERBOSITY" ]]; then
  VERBOSITY="$DEFAULT_VERBOSITY"
fi

# Switch to the appropriate kubectl context
echo "🔄 Switching to $CLUSTER_NAME cluster context..."
if "$SCRIPT_DIR/helpers/k3s-context-manager.sh" switch "$KUBECTL_CONTEXT" 2>/dev/null; then
	echo "✅ Successfully switched to k3s-$KUBECTL_CONTEXT context"
else
	echo "⚠️  Warning: Failed to switch kubectl context to $KUBECTL_CONTEXT"
	echo "   Run '$SCRIPT_DIR/k3s-context-manager.sh setup' if cluster exists"
	echo "   Continuing with deployment..."
fi
echo ""

echo "$CLUSTER_EMOJI Deploying K3s $CLUSTER_NAME Apps..."
echo "📂 Using unified apps deployment playbook: k3s-deploy-apps.yml"
echo "🎯 Target: $CLUSTER_NAME cluster ($TARGET_CLUSTER)"
echo "🔊 Verbosity: $([ -n "$VERBOSITY" ] && echo "$VERBOSITY" || echo "Standard")"
echo ""

# Determine the correct path to ansible directory
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Get the appropriate inventory path for this environment
INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")

# Build ansible command with proper argument handling
ANSIBLE_CMD=(ansible-playbook -i "$INVENTORY_PATH" "$PROJECT_ROOT/ansible/playbooks/k3s-deploy-apps.yml" --vault-password-file ~/.ansible_vault_pass)

# Add verbosity if set
if [[ -n "$VERBOSITY" ]]; then
	ANSIBLE_CMD+=("$VERBOSITY")
fi

# Add extra vars if set
if [[ -n "$EXTRA_VARS" ]]; then
	ANSIBLE_CMD+=($EXTRA_VARS)
fi

# Execute the command
"${ANSIBLE_CMD[@]}"

RESULT=$?

echo ""
if [ $RESULT -eq 0 ]; then
	echo "✅ $CLUSTER_NAME apps deployment complete!"
else
	echo "❌ $CLUSTER_NAME apps deployment failed (exit code: $RESULT)"
	exit $RESULT
fi