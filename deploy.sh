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
DISK_SIZE="25"         # Disk size in GB
ISO_PATH="/var/lib/libvirt/images/26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
VIRTIO_ISO_PATH="/var/lib/libvirt/images/virtio-win-0.1.266.iso"
AUTOUNATTEND_ISO="/var/lib/libvirt/images/autounattend.iso"
NETWORK_TYPE="default" # Network type (default or isolated)
GRAPHICS_PASSWORD=""   # SPICE graphics console password
DISK_PATH="/var/lib/libvirt/storage/${VM_NAME}.qcow2"
UEFI_LOADER="/usr/share/OVMF/OVMF_CODE.fd"  # Non-secure boot UEFI loader
UEFI_VARS="/var/lib/libvirt/nvram/${VM_NAME}_VARS.fd"
OS_VARIANT="win2k22"   # OS variant recognized by virt-install
CPU_MODEL="host-passthrough"  # Default CPU model

# Windows Version Variables
WIN_VERSION="2k25"     # Windows version for VirtIO drivers (e.g., 2k22, 2k25)
WIN_INDEX="2"          # Index of the Windows image in the ISO

# Logging
LOG_DIR="/usr/local/userland/logs"
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
  -d DISK_SIZE           Disk size in GB (default: 25)
  -i ISO_PATH            Path to the Windows Server ISO
  -v VIRTIO_ISO_PATH     Path to the VirtIO drivers ISO
  -a AUTOUNATTEND_ISO    Path to the Autounattend ISO
  -t NETWORK_TYPE        Network type (default or isolated, default: default)
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
    while getopts "n:r:c:d:i:v:a:t:p:m:w:x:u:h" opt; do
        case "$opt" in
            n) VM_NAME="$OPTARG" ;;
            r) RAM="$OPTARG" ;;
            c) VCPUS="$OPTARG" ;;
            d) DISK_SIZE="$OPTARG" ;;
            i) ISO_PATH="$OPTARG" ;;
            v) VIRTIO_ISO_PATH="$OPTARG" ;;
            a) AUTOUNATTEND_ISO="$OPTARG" ;;
            t) NETWORK_TYPE="$OPTARG" ;;
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
                echo -e "${RED}Invalid username. Use 3-32 chars, start with letter, alphanumeric, _, - only.${NC}"
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
    echo -n "$password" | iconv -t utf16le | base64
}

# Cleanup function to ensure resources are released
cleanup() {
    echo -e "${BLUE}Cleaning up...${NC}"
    if [[ -n "${loop_device:-}" ]]; then
        sudo umount "$virtio_mount" || true
        sudo losetup -d "$loop_device" || true
        rmdir "$virtio_mount" || true
    fi
    rm -rf "${temp_dir:-}" || true
    rm -f "$AUTOUNATTEND_ISO" || true
    rm -f "$DISK_PATH" || true
    echo -e "${GREEN}Cleanup completed.${NC}"
}

# Check for necessary files and permissions
validate_environment() {
    echo -e "${BLUE}Validating environment...${NC}"

    # Check if running as a non-root user
    if [[ $EUID -eq 0 ]]; then
        echo -e "${RED}Error:${NC} This script must not be run as root."
        exit 1
    fi

    # Check if required commands are available
    local required_cmds=("virt-install" "genisoimage" "cp" "mkdir" "qemu-img" "mount" "umount" "mktemp" "iconv" "losetup")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}Error:${NC} Required command '$cmd' is not installed."
            exit 1
        fi
    done

    # Validate file paths
    local files_to_check=("$ISO_PATH" "$VIRTIO_ISO_PATH" "$UEFI_LOADER")
    for file in "${files_to_check[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo -e "${RED}Error:${NC} Required file '$file' not found."
            exit 1
        fi
    done

    # Ensure Autounattend.xml and setup.ps1 exist
    if [[ ! -f "${SCRIPT_DIR}/Autounattend.xml" ]] || [[ ! -f "${SCRIPT_DIR}/setup.ps1" ]]; then
        echo -e "${RED}Error:${NC} Autounattend.xml or setup.ps1 not found in '$SCRIPT_DIR'."
        exit 1
    fi

    # Check if DISK_PATH already exists
    if [[ -f "$DISK_PATH" ]]; then
        echo -e "${YELLOW}Warning:${NC} Disk image '$DISK_PATH' already exists."
        while true; do
            read -p "Do you want to remove the existing image? (y/n): " choice
            case "$choice" in
                y|Y )
                    rm -f "$DISK_PATH"
                    echo -e "${GREEN}Existing disk image removed.${NC}"
                    break
                    ;;
                n|N )
                    echo -e "${RED}Error:${NC} Disk image '$DISK_PATH' already exists. Exiting."
                    exit 1
                    ;;
                * )
                    echo -e "${RED}Invalid choice. Please enter 'y' or 'n'.${NC}"
                    ;;
            esac
        done
    fi

    echo -e "${GREEN}Environment validation passed.${NC}"
}

# Prepare UEFI variables
prepare_uefi_vars() {
    echo -e "${BLUE}Preparing UEFI variables...${NC}"
    mkdir -p "$(dirname "$UEFI_VARS")"
    cp -f "$UEFI_LOADER" "$UEFI_VARS"
    echo -e "${GREEN}UEFI variables prepared at '$UEFI_VARS'.${NC}"
}

# Create Autounattend ISO with injected credentials
create_autounattend_iso() {
    echo -e "${BLUE}Creating Autounattend ISO...${NC}"

    temp_dir=$(mktemp -d)
    trap 'cleanup' EXIT

    # Copy Autounattend.xml and setup.ps1 to temp directory
    cp "${SCRIPT_DIR}/Autounattend.xml" "${SCRIPT_DIR}/setup.ps1" "$temp_dir/"

    # Inject hashed passwords and username into Autounattend.xml
    ADMIN_PASSWORD_HASH=$(generate_password_hash "$ADMIN_PASSWORD")
    USER_PASSWORD_HASH=$(generate_password_hash "$USER_PASSWORD")
    sed "s/BASE64_HASH_ADMIN/${ADMIN_PASSWORD_HASH}/g; s/BASE64_HASH_MCRAMER/${USER_PASSWORD_HASH}/g; s/USERNAME_PLACEHOLDER/${USERNAME}/g; s/USERNAME_PLACEHOLDER_DISPLAY/${USERNAME}/g; s/BASE64_HASH_USER/${USER_PASSWORD_HASH}/g" \
        "$temp_dir/Autounattend.xml" > "$temp_dir/Autounattend_final.xml"

    # Replace Autounattend.xml with the modified version
    mv "$temp_dir/Autounattend_final.xml" "$temp_dir/Autounattend.xml"

    # Create $WinPEDriver$ and Drivers directory structure
    mkdir -p "$temp_dir/\$WinPEDriver$\viostor"
    mkdir -p "$temp_dir/Drivers"

    # Mount VirtIO ISO and copy drivers
    virtio_mount=$(mktemp -d)
    loop_device=$(sudo losetup --find --show "$VIRTIO_ISO_PATH")
    if ! sudo mount "$loop_device" "$virtio_mount"; then
        echo -e "${RED}Error:${NC} Failed to mount VirtIO ISO at '$VIRTIO_ISO_PATH'."
        sudo losetup -d "$loop_device"
        exit 1
    fi

    # Copy drivers
    local driver_dirs=("viostor/w$WIN_VERSION/amd64" "NetKVM/w$WIN_VERSION/amd64" "viogpudo/w$WIN_VERSION/amd64")
    for dir in "${driver_dirs[@]}"; do
        if [[ -d "$virtio_mount/$dir" ]]; then
            cp -r "$virtio_mount/$dir/." "$temp_dir/\$WinPEDriver$\viostor/"
            echo -e "${GREEN}Drivers from '$dir' copied.${NC}"
        else
            echo -e "${YELLOW}Warning:${NC} Drivers not found for '$dir'."
        fi
    done

    # Unmount VirtIO ISO
    sudo umount "$virtio_mount"
    sudo losetup -d "$loop_device"
    rmdir "$virtio_mount"

    # Generate Autounattend ISO
    if ! genisoimage -o "$AUTOUNATTEND_ISO" -udf -input-charset utf8 "$temp_dir/"; then
        echo -e "${RED}Error:${NC} Failed to generate Autounattend ISO."
        exit 1
    fi
    echo -e "${GREEN}Autounattend ISO created at '$AUTOUNATTEND_ISO'.${NC}"
}

# Create disk image
create_disk_image() {
    echo -e "${BLUE}Creating disk image at '$DISK_PATH'...${NC}"
    if ! qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"; then
        echo -e "${RED}Error:${NC} Failed to create disk image."
        exit 1
    fi
    echo -e "${GREEN}Disk image created.${NC}"
}

# Create and install the virtual machine
create_vm() {
    echo -e "${BLUE}Creating virtual machine '$VM_NAME'...${NC}"

    virt-install \
        --name "$VM_NAME" \
        --memory "$RAM" \
        --vcpus "$VCPUS",cores="$VCPUS",threads=1,sockets=1 \
        --cpu "$CPU_MODEL" \
        --machine q35 \
        --os-variant "$OS_VARIANT" \
        --boot loader="$UEFI_LOADER",nvram="$UEFI_VARS" \
        --disk path="$DISK_PATH",size="$DISK_SIZE",format=qcow2,bus=virtio,cache=none,discard=unmap,detect_zeroes=unmap \
        --disk "$ISO_PATH",device=cdrom,boot_order=1 \
        --disk "$AUTOUNATTEND_ISO",device=cdrom,boot_order=2 \
        --disk "$VIRTIO_ISO_PATH",device=cdrom \
#        --network network="$NETWORK_TYPE",model=virtio-net-pci \
        --graphics spice${GRAPHICS_PASSWORD:+,password=$GRAPHICS_PASSWORD},listen=none \
        --video qxl \
        --channel spicevmc,target.type=virtio \
#        --sound none \
        --features kvm_hidden=on \
        --memorybacking hugepages=on \
        --noautoconsole \
        --wait -1 \
        --events on_reboot=restart \
        --metadata title="Windows Server $WIN_VERSION VM",description="Secure and performance-optimized deployment." \
        --check all=off \
        --qemu-commandline="-cpu host"
        --extra-args "console=ttyS0,115200n8"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error:${NC} VM creation failed."
        exit 1
    fi
    echo -e "${GREEN}Virtual machine '$VM_NAME' creation initiated.${NC}"
}

# Display completion message
completion_message() {
    echo -e "${GREEN}===== Deployment Completed Successfully: $(date) =====${NC}"
    echo "Virtual machine '$VM_NAME' has been created and is now being installed."
    echo "Manage the VM using virt-manager or connect via the SPICE protocol."
    echo "Log file located at '$LOG_FILE'."
    echo -e "${GREEN}===== Deployment Completed Successfully! =====${NC}"
}

###############################
# Main Script Execution       #
###############################

main() {
    init_logging
    parse_arguments "$@"
    prompt_credentials
    validate_environment
    prepare_uefi_vars
    create_autounattend_iso
    create_disk_image
    create_vm
    completion_message
}

# Error handling for main function
if ! main "$@"; then
    echo -e "${RED}An error occurred during the deployment process. Check '$LOG_FILE' for details.${NC}"
    exit 1
fi
