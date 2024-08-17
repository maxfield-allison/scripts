#!/bin/sh

# Function to print usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --clean      Force re-download of the image and recreate the VM template."
    echo "  -p, --pass       Set a custom password for the cloud-init user (default: 'password')."
    echo "  -i, --image      Specify a custom image URL for the VM template." 
    echo "  -s, --storage    Specify the storage location for the VM template (default: 'local')."
    echo "  -u, --username   Set a custom username for the cloud-init user (default: 'administrator')."
    echo "  -t, --timezone   Set a timezone (default: 'Europe/London')."
    echo "  -n, --name       Set the time of the VM (default: 'ubuntu-2204-template')."
    echo "  -d, --vmid       Set a specific VMID to use in your cluster (default: 9000)."
    echo "  -r, --resize     Set a specific size in M to increase the disk image by (default: 5GB+850M for Ubuntu 22.04 image)."
    echo "                   (if -r or --resize is set to 0 it will NOT increase the disk image)."
    echo "  -h, --help       Display this help message and exit."
    echo ""
    echo "This script creates a Proxmox VM template based on a specified image OR the default Ubuntu 22.04 Cloud Image."
}

# Default values
PASSWORD="password"
CLEAN=0
STORAGE="local"
IMAGE_URL="http://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-disk-kvm.img"
USERNAME="administrator"
TIMEZONE="Europe/London"
NAME="ubuntu-2204-template"
VMID=9000
RESIZE=-1

# Parse command line arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c|--clean) CLEAN=1 ;;
        -p|--pass) PASSWORD="$2"; shift ;;
        -i|--image) IMAGE_URL="$2"; shift ;;
        -s|--storage) STORAGE="$2"; shift ;;
        -u|--username) USERNAME="$2"; shift ;;
        -t|--timezone) TIMEZONE="$2"; shift ;;
        -n|--name) NAME="$2"; shift ;;
        -d|--vmid) VMID=$2; shift ;;
        -r|--resize) RESIZE=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; usage; exit 1 ;;
    esac
    shift
done

IMAGE_NAME=$(basename "$IMAGE_URL")

# Update system and install required tools
echo "Installing required tools..."
apt update -y && apt install -y nano wget curl libguestfs-tools

# Conditionally remove and re-download the image
if [ $CLEAN -eq 1 ] || [ ! -f "$IMAGE_NAME" ]; then
    echo "Removing old image and downloading a new one..."
    rm -fv "$IMAGE_NAME"
    echo "Downloading Image..."
    wget --inet4-only "$IMAGE_URL"
else
    echo "Image already exists. Skipping download..."
fi

# Destroy existing VM template if it exists
echo "Checking for existing VM template..."
if qm status $VMID >/dev/null 2>&1; then
    echo "Destroying existing VM template..."
    qm destroy $VMID --destroy-unreferenced-disks 1 --purge 1
else
    echo "No existing VM template found. Proceeding..."
fi

# Resize the image
if [ "$RESIZE" -eq -1 ]; then
    echo "Resizing the image by the default size of 5GB + 820M..."
    qemu-img resize "$IMAGE_NAME" +5G
    qemu-img resize "$IMAGE_NAME" +820M
elif [ "$RESIZE" -ne 0 ]; then
    echo "Resizing the image by ${RESIZE}M..."
    qemu-img resize "$IMAGE_NAME" +${RESIZE}M
else
    echo "Not resizing the image at all..."
fi

# Customize the image with qemu-guest-agent, timezone, and SSH settings
echo "Customizing the image..."
virt-customize -a "$IMAGE_NAME" \
    --install qemu-guest-agent,cloud-init \
    --timezone $TIMEZONE \
    --run-command 'sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
    --run-command 'sed -i "s/^#PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config' \
    --run-command 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && apt-get clean' \
    --run-command 'rm -rf /var/lib/apt/lists/*' \
    --run-command 'dd if=/dev/zero of=/EMPTY bs=1M || true' \
    --run-command 'rm -f /EMPTY' \
    --run-command 'cloud-init clean'


# Create the VM template
echo "Creating VM template..."
qm create $VMID --name "$NAME" --memory 4096 --cores 2 \
    --net0 virtio,bridge=vmbr0,firewall=1 \
    --bios ovmf --agent enabled=1 --ostype l26 --serial0 socket \
    --vga serial0 --machine q35 --scsihw virtio-scsi-single \
    --efidisk0 $STORAGE:$VMID,efitype=4m

# Import the image to VM and convert to QCOW2
echo "Importing image to VM and converting to QCOW2 format..."
IMPORT_OUTPUT=$(qm importdisk $VMID "$IMAGE_NAME" $STORAGE --format qcow2 2>&1)
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
qm set $VMID --scsi0 "$DISK_NAME"

# Set the boot disk
echo "Setting boot disk..."
qm set $VMID --boot c --bootdisk scsi0

# Add cloud-init drive
echo "Adding cloud-init drive..."
qm set $VMID --scsi1 $STORAGE:cloudinit

# Set user/password
echo "Setting cloud-init user and password..."
qm set $VMID --ciuser $USERNAME --cipassword $PASSWORD

# Convert VM to template
echo "Converting VM to template..."
QM_TEMPLATE_OUTPUT=$(qm template $VMID 2>&1)

# Check for errors and complete
if echo "$QM_TEMPLATE_OUTPUT" | grep -q "chattr: Operation not supported"; then
    echo "Note: 'chattr' operation not supported on this storage. This does not impact the template functionality."
else
    echo "VM template conversion completed successfully."
fi

echo "Template creation script completed."
