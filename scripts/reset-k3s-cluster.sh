
#!/bin/bash
# Unified K3s cluster reset script
# Allows target selection and verbosity

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source environment functions
source "$SCRIPT_DIR/environment-functions.sh"

# Default values
TARGET_ENV=""
TARGET_CLUSTER=""
EXTRA_VARS=""
VERBOSITY=""
SHOW_HELP=false
FORCE_CLEANUP=false

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
		--force)
			FORCE_CLEANUP=true
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
	show_environment_help "$0" "Reset"
	echo "Options:"
	echo "  -v, --verbose          Enable verbose output"
	echo "  -vv, -vvv              Enable more verbose output"
	echo "  -q, --quiet            Disable verbose output"
	echo "  --force                DESTRUCTIVE: Also remove Longhorn storage data"
	echo "  -h, --help             Show this help message"
	echo ""
	echo "⚠️  WARNING: This will completely reset the selected cluster!"
	echo "           All applications and configurations will be removed."
	echo ""
	echo "🔥 --force option will also:"
	echo "           - Permanently delete ALL Longhorn storage data"
	echo "           - Remove ALL persistent volumes and application data"
	echo "           - This cannot be undone!"
	echo ""
	if [[ -z "$TARGET_ENV" ]]; then
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

# Add force cleanup option if enabled
if [[ "$FORCE_CLEANUP" == "true" ]]; then
  EXTRA_VARS="$EXTRA_VARS -e k3s_force_longhorn_cleanup=true"
fi

# Apply default verbosity if not explicitly set and environment has a default
if [[ -z "$VERBOSITY" && -n "$DEFAULT_VERBOSITY" ]]; then
  VERBOSITY="$DEFAULT_VERBOSITY"
fi

# Switch to the appropriate kubectl context
echo "🔄 Switching to $CLUSTER_NAME cluster context..."
if "$SCRIPT_DIR/k3s-context-manager.sh" switch "$KUBECTL_CONTEXT" 2>/dev/null; then
	echo "✅ Successfully switched to k3s-$KUBECTL_CONTEXT context"
else
	echo "⚠️  Warning: Failed to switch kubectl context to $KUBECTL_CONTEXT"
	echo "   Run '$SCRIPT_DIR/k3s-context-manager.sh setup' if cluster exists"
	echo "   Continuing with reset..."
fi
echo ""

echo "$CLUSTER_EMOJI Resetting K3s $CLUSTER_NAME Cluster..."
echo "📂 Using reset playbook: k3s-reset.yml"
echo "🎯 Target: $CLUSTER_NAME cluster ($TARGET_CLUSTER)"
echo "🔊 Verbosity: $([ -n "$VERBOSITY" ] && echo "$VERBOSITY" || echo "Standard")"
echo "💥 Force cleanup: $([ "$FORCE_CLEANUP" == "true" ] && echo "ENABLED (Longhorn data will be destroyed)" || echo "Disabled (Longhorn data preserved)")"
echo ""
echo "⚠️  WARNING: This will destroy the entire $CLUSTER_NAME cluster!"
echo "           All applications and configurations will be lost."
if [[ "$FORCE_CLEANUP" == "true" ]]; then
  echo ""
  echo "🔥 FORCE MODE ENABLED:"
  echo "           ALL LONGHORN STORAGE DATA WILL BE PERMANENTLY DELETED!"
  echo "           THIS INCLUDES ALL PERSISTENT VOLUMES AND APPLICATION DATA!"
fi
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "❌ Reset cancelled by user"
    exit 0
fi
echo ""

# Determine the correct path to ansible directory
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Get the appropriate inventory path for this environment
INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")

# Build ansible command with proper argument handling
ANSIBLE_CMD=(ansible-playbook -i "$INVENTORY_PATH" "$PROJECT_ROOT/ansible/playbooks/k3s-reset.yml" --vault-password-file ~/.ansible_vault_pass)

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
	echo "✅ $CLUSTER_NAME cluster reset complete!"
else
	echo "❌ $CLUSTER_NAME cluster reset failed (exit code: $RESULT)"
	exit $RESULT
fi