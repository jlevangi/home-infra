#!/bin/bash
# LXC Container Deployment Script
# Deploys LXC containers on Proxmox using Ansible

# Determine script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Paths
DEFINITIONS_PATH="$PROJECT_ROOT/ansible/lxc_definitions/containers"
INVENTORY_PATH="$PROJECT_ROOT/ansible/inventories/lxc/hosts.yml"
PLAYBOOK_PATH="$PROJECT_ROOT/ansible/playbooks/lxc-deploy.yml"
VAULT_PASS_FILE="$HOME/.ansible_vault_pass"

# Default values
CONTAINER_NAME=""
VERBOSITY=""
SKIP_TEMPLATE=false
TEMPLATE_ONLY=false
LIST_ONLY=false
SHOW_HELP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print colored output
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_header() { echo -e "${CYAN}$1${NC}"; }

# Get list of available containers
get_available_containers() {
  if [[ -d "$DEFINITIONS_PATH" ]]; then
    find "$DEFINITIONS_PATH" -name "*.yml" -type f -exec basename {} .yml \; | sort
  fi
}

# Display available containers
show_containers() {
  print_header "📦 Available LXC Containers:"
  echo ""

  local containers=$(get_available_containers)
  if [[ -z "$containers" ]]; then
    print_warning "No container definitions found in $DEFINITIONS_PATH"
    return 1
  fi

  while IFS= read -r container; do
    local def_file="$DEFINITIONS_PATH/${container}.yml"
    local description=$(grep -E "^description:" "$def_file" 2>/dev/null | sed 's/description: *"\?\([^"]*\)"\?/\1/')
    local container_id=$(grep -E "^container_id:" "$def_file" 2>/dev/null | awk '{print $2}')
    local docker_enabled=$(grep -A1 "applications:" "$def_file" 2>/dev/null | grep "docker_installed:" | awk '{print $2}')

    echo -e "  ${GREEN}${container}${NC} (ID: ${container_id:-?})"
    [[ -n "$description" ]] && echo -e "    ${description}"
    [[ "$docker_enabled" == "true" ]] && echo -e "    🐳 Docker enabled"
    echo ""
  done <<< "$containers"
}

# Show help
show_help() {
  echo "Usage: $0 [CONTAINER_NAME] [OPTIONS]"
  echo ""
  echo "Deploy LXC containers on Proxmox using Ansible."
  echo ""
  echo "Arguments:"
  echo "  CONTAINER_NAME        Name of the container to deploy (from lxc_definitions/containers/)"
  echo ""
  echo "Options:"
  echo "  --list, -l            List available container definitions"
  echo "  --template-only       Only download/prepare the template, don't create container"
  echo "  --skip-template       Skip template preparation (assume template exists)"
  echo "  -v, --verbose         Enable verbose output"
  echo "  -vv, -vvv             Enable more verbose output"
  echo "  -h, --help            Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --list                    # List available containers"
  echo "  $0 nbn-srv                   # Deploy nbn-srv container"
  echo "  $0 nbn-srv -v                # Deploy with verbose output"
  echo "  $0 --template-only           # Just prepare the template"
  echo ""
}

# Interactive container selection
select_container() {
  local containers=$(get_available_containers)

  if [[ -z "$containers" ]]; then
    print_error "No container definitions found"
    exit 1
  fi

  print_header "📦 Select a container to deploy:"
  echo ""

  local i=1
  local container_array=()
  while IFS= read -r container; do
    container_array+=("$container")
    local def_file="$DEFINITIONS_PATH/${container}.yml"
    local description=$(grep -E "^description:" "$def_file" 2>/dev/null | sed 's/description: *"\?\([^"]*\)"\?/\1/')
    echo "  $i) $container"
    [[ -n "$description" ]] && echo "     $description"
    ((i++))
  done <<< "$containers"

  echo ""
  read -p "Enter selection (1-$((i-1))): " selection

  if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le $((i-1)) ]]; then
    CONTAINER_NAME="${container_array[$((selection-1))]}"
  else
    print_error "Invalid selection"
    exit 1
  fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --list|-l)
      LIST_ONLY=true
      shift
      ;;
    --template-only)
      TEMPLATE_ONLY=true
      shift
      ;;
    --skip-template)
      SKIP_TEMPLATE=true
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
    --help|-h)
      SHOW_HELP=true
      shift
      ;;
    -*)
      print_error "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
    *)
      CONTAINER_NAME="$1"
      shift
      ;;
  esac
done

# Show help if requested
if [[ "$SHOW_HELP" == "true" ]]; then
  show_help
  exit 0
fi

# List containers if requested
if [[ "$LIST_ONLY" == "true" ]]; then
  show_containers
  exit 0
fi

# Check for vault password file
if [[ ! -f "$VAULT_PASS_FILE" ]]; then
  print_error "Vault password file not found: $VAULT_PASS_FILE"
  exit 1
fi

# If no container specified, show interactive selection
if [[ -z "$CONTAINER_NAME" ]]; then
  show_containers
  echo ""
  select_container
fi

# Validate container definition exists
if [[ ! -f "$DEFINITIONS_PATH/${CONTAINER_NAME}.yml" ]]; then
  print_error "Container definition not found: ${CONTAINER_NAME}.yml"
  echo ""
  show_containers
  exit 1
fi

# Display deployment info
echo ""
print_header "🚀 LXC Container Deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_info "Container: $CONTAINER_NAME"
print_info "Playbook: $PLAYBOOK_PATH"
print_info "Inventory: $INVENTORY_PATH"
[[ -n "$VERBOSITY" ]] && print_info "Verbosity: $VERBOSITY"
[[ "$SKIP_TEMPLATE" == "true" ]] && print_info "Skipping template preparation"
[[ "$TEMPLATE_ONLY" == "true" ]] && print_info "Template only mode"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Build ansible command
ANSIBLE_CMD=(
  ansible-playbook
  -i "$INVENTORY_PATH"
  "$PLAYBOOK_PATH"
  --vault-password-file "$VAULT_PASS_FILE"
  -e "container_name=$CONTAINER_NAME"
)

# Add verbosity if set
if [[ -n "$VERBOSITY" ]]; then
  ANSIBLE_CMD+=("$VERBOSITY")
fi

# Add skip template flag if set
if [[ "$SKIP_TEMPLATE" == "true" ]]; then
  ANSIBLE_CMD+=(-e "skip_template=true")
fi

# Add template only flag if set
if [[ "$TEMPLATE_ONLY" == "true" ]]; then
  ANSIBLE_CMD+=(--tags "template")
fi

# Execute the command
print_info "Running: ${ANSIBLE_CMD[*]}"
echo ""

"${ANSIBLE_CMD[@]}"

RESULT=$?
DEFAULT_LXC_SSH_USER="${LXC_PRIMARY_USER:-${USER:-ansible}}"

echo ""
if [[ $RESULT -eq 0 ]]; then
  print_success "Container deployment complete!"
  echo ""
  print_info "To connect to your container:"
  echo "  ssh ${DEFAULT_LXC_SSH_USER}@<container-ip>"
  echo "  ssh ansible@<container-ip>"
else
  print_error "Container deployment failed (exit code: $RESULT)"
  exit $RESULT
fi
