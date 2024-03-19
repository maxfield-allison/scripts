#!/bin/sh

# Variables
STORAGE="nas"
IMAGE_URL="http://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-disk-kvm.img"
IMAGE_NAME=$(basename "$IMAGE_URL")

# Update system and install required tools
echo "Installing required tools..."
apt update -y && apt install -y nano wget curl libguestfs-tools

# Remove previous image if exists
echo "Removing old image if it exists..."
rm -fv "$IMAGE_NAME"

# Destroy existing VM template if it exists
echo "Checking for existing VM template..."
if qm status 9000 >/dev/null 2>&1; then
    echo "Destroying existing VM template..."
    qm destroy 9000 --destroy-unreferenced-disks 1 --purge 1
else
    echo "No existing VM template found. Proceeding..."
fi

# Download the Ubuntu Cloud Image
echo "Downloading Ubuntu Cloud Image..."
wget --inet4-only "$IMAGE_URL"

# Customize the image with qemu-guest-agent, timezone, and SSH settings
echo "Customizing the image..."
virt-customize -a "$IMAGE_NAME" \
    --install qemu-guest-agent,cloud-init \
    --timezone America/Chicago \
    --run-command 'sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
    --run-command 'sed -i "s/^#PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config' \
    --run-command 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && apt-get clean' \
    --run-command 'rm -rf /var/lib/apt/lists/*' \
    --run-command 'cloud-init clean'

# Resize the image
echo "Resizing the image..."
qemu-img resize "$IMAGE_NAME" +5G
qemu-img resize "$IMAGE_NAME" +820M

# Create the VM template
echo "Creating VM template..."
qm create 9000 --name "ubuntu-2204-template" --memory 4096 --cores 2 \
    --net0 virtio,bridge=vmbr1,tag=20,firewall=0 \
    --net1 virtio,bridge=vmbr1,tag=40,firewall=0 \
    --net2 virtio,bridge=vmbr1,tag=443,firewall=0 \
    --net3 virtio,bridge=vmbr5,tag=5,firewall=0 \
    --bios ovmf --agent enabled=1 --ostype l26 --serial0 socket \
    --vga serial0 --machine q35 --scsihw virtio-scsi-pci

# Import the image to VM and convert to QCOW2
echo "Importing image to VM and converting to QCOW2 format..."
IMPORT_OUTPUT=$(qm importdisk 9000 "$IMAGE_NAME" $STORAGE --format qcow2 2>&1)
DISK_NAME=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as \'\K[^']+" | sed 's/^unused0://')

# Verify disk name was captured
if [ -z "$DISK_NAME" ]; then
    echo "Failed to capture the disk name from the import operation."
    exit 1
else
    echo "Imported disk name: $DISK_NAME"
fi

# Add the disk to VM
echo "Adding disk to VM template..."
qm set 9000 --scsi0 "$DISK_NAME"

# Set the boot disk
echo "Setting boot disk..."
qm set 9000 --boot c --bootdisk scsi0

# Convert VM to template
echo "Converting VM to template..."
QM_TEMPLATE_OUTPUT=$(qm template 9000 2>&1)

# Check for errors and complete
if echo "$QM_TEMPLATE_OUTPUT" | grep -q "chattr: Operation not supported"; then
    echo "Note: 'chattr' operation not supported on this storage. This does not impact the template functionality."
else
    echo "VM template conversion completed successfully."
fi

echo "Template creation script completed."
