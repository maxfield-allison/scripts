#!/bin/sh

# Define storage variable
STORAGE=nas

# Define the URL for the Linux image you want to download and use
IMAGE_URL="http://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-disk-kvm.img"

# Extract the image name from the URL for use in file operations
IMAGE_NAME=$(basename "$IMAGE_URL")

# Install necessary tools
echo "Checking tools"
apt update -y && apt install nano wget curl libguestfs-tools -y

# Remove old image
echo "Removing old image..."
rm -fv "$IMAGE_NAME"

# Check if VM 9000 exists before attempting to destroy it
if qm status 9000 >/dev/null 2>&1; then
    echo "Destroying existing VM 9000..."
    qm destroy 9000 --destroy-unreferenced-disks 1 --purge 1
else
    echo "VM 9000 does not exist. Skipping destroy command."
fi

# Download new image
echo "Downloading new image..."
wget --inet4-only "$IMAGE_URL"

# Add agent to image
echo "Customizing image: adding qemu-guest-agent..."
virt-customize -a "$IMAGE_NAME" --install qemu-guest-agent

# Set timezone
echo "Customizing image: setting timezone..."
virt-customize -a "$IMAGE_NAME" --timezone America/Chicago

# Set password auth to yes
echo "Customizing image: enabling password authentication..."
virt-customize -a "$IMAGE_NAME" --run-command 'sed -i s/^PasswordAuthentication.*/PasswordAuthentication\ yes/ /etc/ssh/sshd_config'

# Allow root login with ssh-key only
echo "Customizing image: setting root login policy..."
virt-customize -a "$IMAGE_NAME" --run-command 'sed -i s/^#PermitRootLogin.*/PermitRootLogin\ prohibit-password/ /etc/ssh/sshd_config'

# Increase image size
echo "Resizing image..."
qemu-img resize "$IMAGE_NAME" +5G 
qemu-img resize "$IMAGE_NAME" +820M

# Create VM
echo "Creating VM..."
qm create 9000 --name "ubuntu-2204-template" --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0,tag=20,firewall=1 --bios ovmf --agent enabled=1 --ostype l26 --serial0 socket --vga serial0 --machine q35 --scsihw virtio-scsi-pci

# Import image to VM and convert to QCOW2 during the import
echo "Importing image to VM and converting to QCOW2 format..."
IMPORT_OUTPUT=$(qm importdisk 9000 "$IMAGE_NAME" $STORAGE --format qcow2 2>&1)

# Extract the disk name from the import output, removing the 'unused0:' prefix
DISK_NAME=$(echo "$IMPORT_OUTPUT" | grep -oP "Successfully imported disk as \'\K[^']+" | sed 's/^unused0://')

# Check if the disk name was captured
if [ -z "$DISK_NAME" ]; then
    echo "Failed to capture the disk name from the import operation."
    exit 1
else
    echo "Imported disk name: $DISK_NAME"
fi

# Adding disk to VM using the captured disk name
echo "Disk to be added: $DISK_NAME"
qm set 9000 --scsi0 "$DISK_NAME"

# Set bootdisk to the newly added disk
echo "Setting boot disk..."
qm set 9000 --boot c --bootdisk scsi0

# Convert to template
echo "Converting VM to template..."
QM_TEMPLATE_OUTPUT=$(qm template 9000 2>&1)

# Check for known 'chattr' errors and provide guidance
if echo "$QM_TEMPLATE_OUTPUT" | grep -q "chattr: Operation not supported"; then
    echo "Note: The 'chattr' operation is not supported on the storage used. This is expected for certain filesystems (e.g., NFS) and does not impact the functionality of the VM template."
else
    echo "VM template conversion completed successfully."
fi

echo "Script completed."

