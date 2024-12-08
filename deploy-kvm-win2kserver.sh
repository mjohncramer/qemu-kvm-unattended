#!/bin/bash

# =============================================================================
# Script Name: deploy-kvm-win2kserver.sh
# Description: Deploys a Windows Server virtual machine using KVM/QEMU.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

###############################
# Configuration Variables     #
###############################

# Default VM parameters (can be overridden via command-line arguments)
VM_NAME="winserver2025"
RAM="8192"             # Memory in MB
VCPUS="4"              # Number of CPU cores
DISK_SIZE="60"         # Disk size in GB
ISO_PATH="/var/lib/libvirt/boot/SERVER_2025_EVAL_x64FRE_en-us.iso"
VIRTIO_ISO_PATH="/var/lib/libvirt/boot/virtio-win.iso"
AUTOUNATTEND_ISO="/var/lib/libvirt/boot/autounattend.iso"
BRIDGE="virbr0"        # Network bridge
GRAPHICS_PASSWORD=""   # SPICE graphics console password
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
UEFI_LOADER="/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"  # Secure Boot UEFI loader
UEFI_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.ms.fd"  # Secure Boot UEFI vars
UEFI_VARS="/var/lib/libvirt/qemu/nvram/${VM_NAME}_VARS.fd"
OS_VARIANT="win2k25"   # OS variant optimized for Windows Server 2025
CPU_MODEL="host-passthrough"  # Default CPU model

# Windows Version Variables
WIN_VERSION="2k25"     # Windows version for VirtIO drivers (e.g., 2k22, 2k25)
WIN_INDEX="2"          # Index of the Windows image in the ISO

# Logging
LOG_DIR="/srv/logs/kvm_deployments"
LOG_FILE="${LOG_DIR}/${VM_NAME}_$(date +'%Y%m%d_%H%M%S').log"

# Script Directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###############################
# Function Definitions        #
###############################

# Initialize logging
init_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "${GREEN}===== Deployment Started: $(date) =====${NC}"
}

# Display usage information
usage() {
    cat <<EOF
${YELLOW}Usage:${NC} $0 [options]

${YELLOW}Options:${NC}
  -n VM_NAME             Name of the virtual machine (default: winserver2025)
  -r RAM                 Memory in MB (default: 8192)
  -c VCPUS               Number of CPU cores (default: 4)
  -d DISK_SIZE           Disk size in GB (default: 60)
  -i ISO_PATH            Path to the Windows Server ISO
  -v VIRTIO_ISO_PATH     Path to the VirtIO drivers ISO
  -a AUTOUNATTEND_ISO    Path to the Autounattend ISO (default: /var/lib/libvirt/boot/autounattend.iso)
  -b BRIDGE              Network bridge to use (default: virbr0)
  -p GRAPHICS_PASSWORD   Password for SPICE graphics console
  -m CPU_MODEL           CPU model (host, host-passthrough, etc.)
  -w WIN_VERSION         Windows version for VirtIO drivers (default: 2k25)
  -x WIN_INDEX           Windows image index in ISO (default: 2)
  -u USERNAME            Username for the local account (default: mcramer)
  -h                     Show this help message and exit

${YELLOW}Example:${NC}
  $0 -n myWinServer -r 16384 -c 8 -u johnDoe
EOF
    exit 1
}

# Parse command-line arguments
parse_arguments() {
    while getopts "n:r:c:d:i:v:a:b:p:m:w:x:u:h" opt; do
        case "$opt" in
            n) VM_NAME="$OPTARG" ;;
            r) RAM="$OPTARG" ;;
            c) VCPUS="$OPTARG" ;;
            d) DISK_SIZE="$OPTARG" ;;
            i) ISO_PATH="$OPTARG" ;;
            v) VIRTIO_ISO_PATH="$OPTARG" ;;
            a) AUTOUNATTEND_ISO="$OPTARG" ;;
            b) BRIDGE="$OPTARG" ;;
            p) GRAPHICS_PASSWORD="$OPTARG" ;;
            m) CPU_MODEL="$OPTARG" ;;
            w) WIN_VERSION="$OPTARG" ;;
            x) WIN_INDEX="$OPTARG" ;;
            u) USERNAME="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done
}

# Prompt for Username and Passwords
prompt_credentials() {
    echo -e "${BLUE}=== Credential Setup ===${NC}"

    # Prompt for Username if not provided via command-line
    if [[ -z "${USERNAME:-}" ]]; then
        while true; do
            read -p "Enter desired username for the local account: " USERNAME
            if [[ "$USERNAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]{2,31}$ ]]; then
                break
            else
                echo -e "${RED}Invalid username. Please use 3-32 characters, starting with a letter, and containing only letters, numbers, underscores, or hyphens.${NC}"
            fi
        done
    fi

    # Prompt for Administrator Password
    while true; do
        read -s -p "Enter Administrator password: " ADMIN_PASSWORD
        echo
        read -s -p "Confirm Administrator password: " ADMIN_PASSWORD_CONFIRM
        echo
        if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
            break
        else
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
        fi
    done

    # Prompt for Local User Password
    while true; do
        read -s -p "Enter password for user '$USERNAME': " USER_PASSWORD
        echo
        read -s -p "Confirm password for user '$USERNAME': " USER_PASSWORD_CONFIRM
        echo
        if [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]]; then
            break
        else
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
        fi
    done
}

# Generate Base64-Encoded Password Hash
generate_password_hash() {
    local password="$1"
    # Convert to UTF-16LE and then base64 encode
    echo -n "$password" | iconv -t utf16le | base64
}

# Check for necessary files and permissions
validate_environment() {
    echo -e "${BLUE}Validating environment...${NC}"

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error:${NC} This script must be run as root."
        exit 1
    fi

    # Check if required commands are available
    local required_cmds=("virt-install" "genisoimage" "cp" "mkdir" "qemu-img" "mount" "umount" "mktemp" "sudo" "iconv")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}Error:${NC} Required command '$cmd' is not installed."
            exit 1
        fi
    done

    # Validate file paths
    local files_to_check=("$ISO_PATH" "$VIRTIO_ISO_PATH" "$UEFI_LOADER" "$UEFI_VARS_TEMPLATE")
    for file in "${files_to_check[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo -e "${RED}Error:${NC} Required file '$file' not found."
            exit 1
        fi
    done

    # Ensure Autounattend.xml and setup.ps1 exist
    if [[ ! -f "${SCRIPT_DIR}/Autounattend.xml" ]] || [[ ! -f "${SCRIPT_DIR}/setup.ps1" ]]; then
        echo -e "${RED}Error:${NC} Autounattend.xml and/or setup.ps1 not found in '$SCRIPT_DIR'."
        exit 1
    fi

    # Check if DISK_PATH already exists
    if [[ -f "$DISK_PATH" ]]; then
        echo -e "${RED}Error:${NC} Disk image '$DISK_PATH' already exists."
        exit 1
    fi

    # Verify network bridge exists
    if ! ip link show "$BRIDGE" &>/dev/null; then
        echo -e "${RED}Error:${NC} Network bridge '$BRIDGE' does not exist."
        exit 1
    fi

    echo -e "${GREEN}Environment validation passed.${NC}"
}

# Prepare UEFI variables
prepare_uefi_vars() {
    echo -e "${BLUE}Preparing UEFI variables...${NC}"
    mkdir -p "$(dirname "$UEFI_VARS")"
    cp -f "$UEFI_VARS_TEMPLATE" "$UEFI_VARS"
    echo -e "${GREEN}UEFI variables prepared at '$UEFI_VARS'.${NC}"
}

# Create Autounattend ISO with injected credentials
create_autounattend_iso() {
    echo -e "${BLUE}Creating Autounattend ISO...${NC}"

    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    # Copy Autounattend.xml and setup.ps1 to temp directory
    cp "${SCRIPT_DIR}/Autounattend.xml" "${SCRIPT_DIR}/setup.ps1" "$temp_dir/"

    # Inject hashed passwords and username into Autounattend.xml
    sed "s/BASE64_HASH_ADMIN/${ADMIN_PASSWORD_HASH}/g; s/BASE64_HASH_MCRAMER/${USER_PASSWORD_HASH}/g; s/USERNAME_PLACEHOLDER/${USERNAME}/g; s/USERNAME_PLACEHOLDER_DISPLAY/${USERNAME}/g; s/BASE64_HASH_USER/${USER_PASSWORD_HASH}/g" \
        "$temp_dir/Autounattend.xml" > "$temp_dir/Autounattend_final.xml"

    # Replace Autounattend.xml with the modified version
    mv "$temp_dir/Autounattend_final.xml" "$temp_dir/Autounattend.xml"

    # Create $WinPEDriver$ and Drivers directory structure
    mkdir -p "$temp_dir/\$WinPEDriver$\viostor"
    mkdir -p "$temp_dir/Drivers"

    # Mount VirtIO ISO and copy drivers
    local virtio_mount
    virtio_mount=$(mktemp -d)
    mount -o loop "$VIRTIO_ISO_PATH" "$virtio_mount"

    # Copy storage drivers
    if [[ -d "$virtio_mount/viostor/${WIN_VERSION}/amd64" ]]; then
        cp -r "$virtio_mount/viostor/${WIN_VERSION}/amd64/." "$temp_dir/\$WinPEDriver$\viostor/"
        echo -e "${GREEN}Storage drivers copied.${NC}"
    else
        echo -e "${YELLOW}Warning:${NC} Storage drivers not found for version '$WIN_VERSION'."
    fi

    # Copy network drivers
    if [[ -d "$virtio_mount/NetKVM/${WIN_VERSION}/amd64" ]]; then
        cp -r "$virtio_mount/NetKVM/${WIN_VERSION}/amd64/." "$temp_dir/Drivers/"
        echo -e "${GREEN}Network drivers copied.${NC}"
    else
        echo -e "${YELLOW}Warning:${NC} Network drivers not found for version '$WIN_VERSION'."
    fi

    # Copy graphics drivers
    if [[ -d "$virtio_mount/qxl/${WIN_VERSION}/amd64" ]]; then
        cp -r "$virtio_mount/qxl/${WIN_VERSION}/amd64/." "$temp_dir/Drivers/"
        echo -e "${GREEN}Graphics drivers copied.${NC}"
    else
        echo -e "${YELLOW}Warning:${NC} Graphics drivers not found for version '$WIN_VERSION'."
    fi

    # Unmount VirtIO ISO
    umount "$virtio_mount"
    rmdir "$virtio_mount"

    # Generate Autounattend ISO
    genisoimage -o "$AUTOUNATTEND_ISO" -udf -input-charset utf8 "$temp_dir/"
    echo -e "${GREEN}Autounattend ISO created at '$AUTOUNATTEND_ISO'.${NC}"

    trap - EXIT
}

# Create disk image
create_disk_image() {
    echo -e "${BLUE}Creating disk image at '$DISK_PATH'...${NC}"
    qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"
    echo -e "${GREEN}Disk image created.${NC}"
}

# Optimize disk image for performance
optimize_disk_image() {
    echo -e "${BLUE}Optimizing disk image for performance...${NC}"
    qemu-img convert -O qcow2 "$DISK_PATH" "${DISK_PATH}.optimized.qcow2" \
        && mv "${DISK_PATH}.optimized.qcow2" "$DISK_PATH"
    echo -e "${GREEN}Disk image optimized.${NC}"
}

# Create and install the virtual machine
create_vm() {
    echo -e "${BLUE}Creating virtual machine '$VM_NAME'...${NC}"

    virt-install \
        --name "$VM_NAME" \
        --memory "$RAM" \
        --vcpus "$VCPUS",cores="$VCPUS",threads=1,sockets=1 \
        --cpu "$CPU_MODEL",hv_relaxed=on,hv_vapic,hv_time,hv_spinlocks=0x1fff \
        --machine type=q35,accel=kvm \
        --os-variant "$OS_VARIANT" \
        --boot loader="$UEFI_LOADER",loader_ro=yes,loader_type=pflash,nvram="$UEFI_VARS",secureboot=on \
        --disk path="$DISK_PATH",size="$DISK_SIZE",format=qcow2,bus=virtio,cache=none,discard=unmap,aio=threads,detect_zeroes=unmap \
        --disk "$ISO_PATH",device=cdrom,boot_order=1 \
        --disk "$AUTOUNATTEND_ISO",device=cdrom \
        --network bridge="$BRIDGE",model=virtio-net-pci \
        --graphics spice,gl=on${GRAPHICS_PASSWORD:+,password=$GRAPHICS_PASSWORD},listen=none \
        --video qxl \
        --channel spicevmc \
        --sound none \
        --tpm emulator,model=tpm-crb \
        --features kvm_hidden=on \
        --memorybacking hugepages=on \
        --noautoconsole \
        --wait -1 \
        --events on_reboot=restart \
        --metadata title="Windows Server $WIN_VERSION VM",description="Secure and performance-optimized deployment." \
        --check all=off \
        --parallel none

    echo -e "${GREEN}Virtual machine '$VM_NAME' creation initiated.${NC}"
}

# Display completion message
completion_message() {
    echo -e "${GREEN}===== Deployment Completed Successfully: $(date) =====${NC}"
    echo "Virtual machine '$VM_NAME' has been created and is now being installed."
    echo "Manage the VM using virt-manager or connect via the SPICE protocol."
    echo "Log file located at '$LOG_FILE'."
    echo -e "${GREEN}===== Deploymement Completed Sucessfully! =====${NC}"
}

###############################
# Main Script Execution       #
###############################

main() {
    init_logging
    parse_arguments "$@"
    prompt_credentials
    ADMIN_PASSWORD_HASH=$(generate_password_hash "$ADMIN_PASSWORD")
    USER_PASSWORD_HASH=$(generate_password_hash "$USER_PASSWORD")
    validate_environment
    prepare_uefi_vars
    create_autounattend_iso
    create_disk_image
    optimize_disk_image
    create_vm
    completion_message
}

main "$@"
