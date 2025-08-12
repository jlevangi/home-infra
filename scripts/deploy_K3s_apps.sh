
#!/bin/bash
# Unified K3s apps deployment script
# Allows redeployment of apps to either cluster with verbosity and help options

# Default values
TARGET_CLUSTER=""
EXTRA_VARS=""
VERBOSITY=""
SHOW_HELP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
	case $1 in
		--prod|--production)
			TARGET_CLUSTER="k3s_cluster"
			shift
			;;
		--test)
			TARGET_CLUSTER="k3s_test_cluster"
			VERBOSITY="-v"  # Default verbose for test
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
if [[ "$SHOW_HELP" == "true" ]] || [[ -z "$TARGET_CLUSTER" ]]; then
	echo "Usage: $0 --prod|--test [OPTIONS]"
	echo ""
	echo "Target Selection (required):"
	echo "  --prod, --production   Deploy apps to production cluster (k3s_cluster)"
	echo "  --test                 Deploy apps to test cluster (k3s_test_cluster)"
	echo ""
	echo "Options:"
	echo "  -v, --verbose          Enable verbose output"
	echo "  -vv, -vvv              Enable more verbose output"
	echo "  -q, --quiet            Disable verbose output"
	echo "  -h, --help             Show this help message"
	echo ""
	echo "Examples:"
	echo "  $0 --prod              # Deploy apps to production cluster"
	echo "  $0 --test -v           # Deploy apps to test cluster with verbose output"
	echo "  $0 --prod -q           # Deploy apps to production quietly"
	echo ""
	if [[ -z "$TARGET_CLUSTER" ]]; then
		echo ""
		echo "❌ Error: Target cluster must be specified (--prod or --test)"
		exit 1
	else
		exit 0
	fi
fi

# Set up target-specific variables
if [[ "$TARGET_CLUSTER" == "k3s_test_cluster" ]]; then
	EXTRA_VARS="$EXTRA_VARS -e target_cluster=k3s_test_cluster"
	CLUSTER_NAME="Test"
	CLUSTER_EMOJI="🧪"
else
	CLUSTER_NAME="Production"
	CLUSTER_EMOJI="🚀"
fi

echo "$CLUSTER_EMOJI Deploying K3s $CLUSTER_NAME Apps..."
echo "📂 Using unified apps deployment playbook: k3s-deploy-apps.yml"
echo "🎯 Target: $CLUSTER_NAME cluster ($TARGET_CLUSTER)"
echo "🔊 Verbosity: $([ -n "$VERBOSITY" ] && echo "$VERBOSITY" || echo "Standard")"
echo ""

ansible-playbook -i ../ansible/k3s-inventory ../ansible/playbooks/k3s-deploy-apps.yml \
	--vault-password-file ~/.ansible_vault_pass \
	$VERBOSITY \
	$EXTRA_VARS

RESULT=$?

echo ""
if [ $RESULT -eq 0 ]; then
	echo "✅ $CLUSTER_NAME apps deployment complete!"
else
	echo "❌ $CLUSTER_NAME apps deployment failed (exit code: $RESULT)"
	exit $RESULT
fi