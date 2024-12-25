#!/bin/bash

# VM specific parameters
VM_NAME="WindowsServer2025"
ISO_PATH="/var/lib/libvirt/images/26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
VIRTIO_ISO_PATH="/var/lib/libvirt/images/virtio-win-0.1.266.iso"
UEFI_LOADER="/usr/share/OVMF/OVMF_CODE.fd"
ORIGIN_UEFI_VARS="/usr/share/OVMF/OVMF_VARS.fd"  # Assuming this is the default location
UEFI_VARS="/var/lib/libvirt/nvram/${VM_NAME}_VARS.fd"

# Additional variables for modularity
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
DISK_SIZE="40"
MEMORY="4096"
VCPUS="2"
OS_VARIANT="win2k22"
NETWORK_TYPE="user"
VIDEO_TYPE="qxl"
GRAPHICS_PASSWORD=""  # Set to desired password or leave empty for no password

# Logging setup
LOG_DIR="/usr/local/userland/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${VM_NAME}_$(date +'%Y%m%d_%H%M%S').log"

# Copy UEFI variables file if it doesn't exist
if [ ! -f "$UEFI_VARS" ]; then
    mkdir -p "$(dirname "$UEFI_VARS")"
    cp "$ORIGIN_UEFI_VARS" "$UEFI_VARS"
    echo "Copied UEFI variables file from $ORIGIN_UEFI_VARS to $UEFI_VARS" >> "$LOG_FILE"
else
    echo "UEFI variables file already exists at $UEFI_VARS" >> "$LOG_FILE"
fi

# Script to run virt-install
echo "Starting VM installation for ${VM_NAME} at $(date)" >> "$LOG_FILE"
virt-install \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --vcpus "$VCPUS" \
  --os-variant "$OS_VARIANT" \
  --disk path="$DISK_PATH",size="$DISK_SIZE",bus=virtio,format=qcow2 \
  --cdrom "$ISO_PATH" \
  --disk "$VIRTIO_ISO_PATH",device=cdrom \
  --network "$NETWORK_TYPE" \
  --video "$VIDEO_TYPE" \
  --graphics spice${GRAPHICS_PASSWORD:+,password=$GRAPHICS_PASSWORD},listen=none \
  --machine q35 \
  --boot uefi,loader="$UEFI_LOADER",nvram="$UEFI_VARS" \
  --noautoconsole \
  --connect qemu:///session \
  >> "$LOG_FILE" 2>&1

# Check if installation command succeeded
if [ $? -eq 0 ]; then
    echo "Installation command for ${VM_NAME} completed successfully at $(date)" >> "$LOG_FILE"
else
    echo "Installation command for ${VM_NAME} failed at $(date)" >> "$LOG_FILE"
fi

echo "Log file saved at: $LOG_FILE"
