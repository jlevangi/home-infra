#!/usr/bin/env bash
# scripts/helpers/import-talos-template.sh
#
# Fetches a Talos Linux image from factory.talos.dev with the system
# extensions our Talos Proxmox clusters need (qemu-guest-agent,
# iscsi-tools, util-linux-tools) and imports it into Proxmox as a VM
# template that terraform/talos_cluster_test/ clones from.
#
# Re-run for new Talos versions with a distinct --vmid/--name so prior
# templates remain available for rollback. See the top of the file for
# every overridable setting.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults (every setting is overridable via env var or --flag).
TALOS_VERSION="${TALOS_VERSION:-v1.12.6}"
PROXMOX_HOST="${PROXMOX_HOST:-pve2}"
PROXMOX_SSH_USER="${PROXMOX_SSH_USER:-root}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-vm_data}"
PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9100}"
TEMPLATE_NAME="${TEMPLATE_NAME:-}"
IMAGE_VARIANT="${IMAGE_VARIANT:-nocloud-amd64.raw.xz}"

usage() {
    cat <<EOF
Usage: $0 [options]

Downloads a Talos Linux image (qemu-guest-agent + iscsi-tools +
util-linux-tools pre-baked) from factory.talos.dev and turns it into a
Proxmox VM template.

Options (env var shown in parentheses):
  --version <tag>   Talos version to pull      (TALOS_VERSION)      [$TALOS_VERSION]
  --host <host>     Proxmox SSH host           (PROXMOX_HOST)       [$PROXMOX_HOST]
  --user <user>     Proxmox SSH user           (PROXMOX_SSH_USER)   [$PROXMOX_SSH_USER]
  --storage <name>  Proxmox storage for disk   (PROXMOX_STORAGE)    [$PROXMOX_STORAGE]
  --bridge <name>   Proxmox network bridge     (PROXMOX_BRIDGE)     [$PROXMOX_BRIDGE]
  --vmid <id>       Template VM id             (TEMPLATE_VMID)      [$TEMPLATE_VMID]
  --name <name>     Template display name      (TEMPLATE_NAME)      [talos-<version>-template]
  --variant <file>  Factory image variant      (IMAGE_VARIANT)      [$IMAGE_VARIANT]
  -h, --help        Show this help and exit

Requires: passwordless SSH to <user>@<host>; curl and xz on the Proxmox host.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  TALOS_VERSION="$2"; shift 2 ;;
        --host)     PROXMOX_HOST="$2"; shift 2 ;;
        --user)     PROXMOX_SSH_USER="$2"; shift 2 ;;
        --storage)  PROXMOX_STORAGE="$2"; shift 2 ;;
        --bridge)   PROXMOX_BRIDGE="$2"; shift 2 ;;
        --vmid)     TEMPLATE_VMID="$2"; shift 2 ;;
        --name)     TEMPLATE_NAME="$2"; shift 2 ;;
        --variant)  IMAGE_VARIANT="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Fill in template name default now that --version may have changed.
: "${TEMPLATE_NAME:=talos-${TALOS_VERSION}-template}"

SSH_TARGET="${PROXMOX_SSH_USER}@${PROXMOX_HOST}"
SSH=(ssh -o StrictHostKeyChecking=accept-new "$SSH_TARGET")

echo -e "${BLUE}Building Talos factory schematic (qemu-guest-agent + iscsi-tools + util-linux-tools)${NC}"

SCHEMATIC_YAML='customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
'

SCHEMATIC_RESPONSE=$(
    curl -fsS -X POST \
        --data-binary "$SCHEMATIC_YAML" \
        https://factory.talos.dev/schematics
)

SCHEMATIC_ID=$(printf '%s' "$SCHEMATIC_RESPONSE" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$SCHEMATIC_ID" ]]; then
    echo -e "${RED}Could not parse schematic ID from factory response:${NC}" >&2
    printf '%s\n' "$SCHEMATIC_RESPONSE" >&2
    exit 1
fi
echo -e "${GREEN}Schematic ID: ${SCHEMATIC_ID}${NC}"

IMAGE_URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/${IMAGE_VARIANT}"
echo -e "${BLUE}Image URL: ${IMAGE_URL}${NC}"
echo -e "${BLUE}Target:    ${SSH_TARGET}  storage=${PROXMOX_STORAGE}  vmid=${TEMPLATE_VMID}  name=${TEMPLATE_NAME}${NC}"

# Fail fast on unreachable SSH or clobbered VMID.
if ! "${SSH[@]}" true 2>/dev/null; then
    echo -e "${RED}Cannot SSH to ${SSH_TARGET}. Configure passwordless SSH first.${NC}" >&2
    exit 1
fi

if "${SSH[@]}" "qm status ${TEMPLATE_VMID}" >/dev/null 2>&1; then
    echo -e "${RED}A VM with id ${TEMPLATE_VMID} already exists on ${PROXMOX_HOST}.${NC}" >&2
    echo -e "${YELLOW}  Use --vmid <new-id> to pick another slot, or destroy it:${NC}" >&2
    echo -e "${YELLOW}    ssh ${SSH_TARGET} qm destroy ${TEMPLATE_VMID}${NC}" >&2
    exit 1
fi

TMP_REMOTE="/tmp/talos-${TALOS_VERSION}-${SCHEMATIC_ID:0:8}"
COMPRESSED_REMOTE="${TMP_REMOTE}/${IMAGE_VARIANT}"
RAW_REMOTE="${TMP_REMOTE}/talos.raw"

echo -e "${BLUE}Downloading image on the Proxmox host (no local transfer)${NC}"
"${SSH[@]}" "mkdir -p '$TMP_REMOTE' && curl -fSL --retry 3 -o '$COMPRESSED_REMOTE' '$IMAGE_URL'"

case "$IMAGE_VARIANT" in
    *.raw.xz)
        echo -e "${BLUE}Decompressing .xz${NC}"
        "${SSH[@]}" "xz -dk -c '$COMPRESSED_REMOTE' > '$RAW_REMOTE'"
        DISK_IMAGE="$RAW_REMOTE"
        ;;
    *.qcow2)
        DISK_IMAGE="$COMPRESSED_REMOTE"
        ;;
    *)
        echo -e "${RED}Unsupported IMAGE_VARIANT '${IMAGE_VARIANT}'. Use *.raw.xz or *.qcow2.${NC}" >&2
        exit 1
        ;;
esac

echo -e "${BLUE}Creating template VM ${TEMPLATE_VMID} (${TEMPLATE_NAME})${NC}"
"${SSH[@]}" "qm create ${TEMPLATE_VMID} \
    --name '${TEMPLATE_NAME}' \
    --memory 2048 \
    --cores 2 \
    --cpu host \
    --net0 virtio,bridge=${PROXMOX_BRIDGE} \
    --scsihw virtio-scsi-pci \
    --ostype l26 \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0"

echo -e "${BLUE}Importing disk into '${PROXMOX_STORAGE}'${NC}"
"${SSH[@]}" "qm importdisk ${TEMPLATE_VMID} '${DISK_IMAGE}' ${PROXMOX_STORAGE}"

# Attach imported disk, set boot order, convert to template.
echo -e "${BLUE}Attaching disk and finalizing template${NC}"
"${SSH[@]}" "qm set ${TEMPLATE_VMID} --scsi0 ${PROXMOX_STORAGE}:vm-${TEMPLATE_VMID}-disk-0"
"${SSH[@]}" "qm set ${TEMPLATE_VMID} --boot order=scsi0"
"${SSH[@]}" "qm template ${TEMPLATE_VMID}"

echo -e "${BLUE}Cleaning up temp files on ${PROXMOX_HOST}${NC}"
"${SSH[@]}" "rm -rf '$TMP_REMOTE'" || true

echo ""
echo -e "${GREEN}Template ready: ${TEMPLATE_NAME} (vmid ${TEMPLATE_VMID}) on ${PROXMOX_HOST}${NC}"
echo -e "${YELLOW}Next:${NC} set 'template_name = \"${TEMPLATE_NAME}\"' in terraform/talos_cluster_test/terraform.tfvars"
