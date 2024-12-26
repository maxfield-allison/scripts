#!/bin/sh

# Function to print usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "      --vmid       VM ID for template creation (default 9000)"
    echo "  -f, --force      Force re-download of the Ubuntu image and recreate the VM template."
    echo "  -u, --username   Set a custom username for the cloud-init user (default: 'root')."
    echo "  -p, --pass       Set a custom password for the cloud-init user."
    echo "  -s, --sshkeys    Set SSH keys for the cloud-init user."
    echo "  -i, --image      Specify a custom image URL for the VM template."
    echo "  -s, --storage    Specify the storage location for the VM template (default: 'local')."
    echo "  -d, --disk-size  Specify disk size (default '32G')."
    echo "  -t, --timezone   Set a timezone (default: 'Europe/London')."
    echo "  -n, --name       Set the time of the VM"
    echo "  -c, --clean      Remove libguestfs-tools"
    echo "  -h, --help       Display this help message and exit."
    echo ""
    echo "This script creates a Proxmox VM template based on a specified or default Ubuntu Cloud Image."
}

set -e

# Default values
VMID="9000"
USERNAME="administrator"
PASSWORD="password"
SSHKEYS=""
FORCE=0
STORAGE="local"
IMAGE_SIZE="32G"
IMAGE_URL="http://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-disk-kvm.img"
TIMEZONE="Europe/London"
NAME=""
CLEAN=0

# Parse command line arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
           --vmid) VMID="$2"; shift ;;
        -f|--force) FORCE=1 ;;
        -u|--username) USERNAME="$2"; shift ;;
        -p|--pass) PASSWORD="$2"; shift ;;
        -k|--sshkeys) SSHKEYS="$2"; shift ;;
        -i|--image) IMAGE_URL="$2"; shift ;;
        -s|--storage) STORAGE="$2"; shift ;;
        -d|--disk-size) IMAGE_SIZE="$2"; shift ;;
        -t|--timezone) TIMEZONE="$2"; shift ;;
        -n|--name) NAME="$2"; shift ;;
        -c|--clean) CLEAN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; usage; exit 1 ;;
    esac
    shift
done

IMAGE_NAME=`basename "$IMAGE_URL"`

# Validate inputs
if [ -z "$PASSWORD" ] && [ -z "$SSHKEYS" ]; then
    echo "Error: cloud-init password or ssh keys muset be set"
    exit 1
fi

# Default template name
[ -z "$NAME" ] && NAME=`basename "$IMAGE_NAME" .qcow2`

# Update system and install required tools
if ! ( [ -x "`command -v vim`" ] && [ -x "`command -v wget`" ] && [ -x "`command -v curl`" ] && [ -x "`command -v virt-customize`" ] ); then
    echo "Installing required tools..."
    apt update -y && apt install -y vim wget curl libguestfs-tools
fi

# Conditionally remove and re-download the image
if [ $FORCE -eq 1 ] || [ ! -f "$IMAGE_NAME" ]; then
    echo "Removing old image and downloading a new one..."
    rm -fv "$IMAGE_NAME"
    echo "Downloading Ubuntu Cloud Image..."
    wget "$IMAGE_URL"
else
    echo "Image already exists. Skipping download..."
fi

# Destroy existing VM template if it exists
while  qm status $VMID >/dev/null 2>&1; do
    _destroy=0

    if [ $FORCE -eq 1 ]; then
        _destroy=1
    else
        read -p "Template $VMID already exists, do you want to replace it? y/[n] " _repl
        if [ -z "$_repl" ] || [ "$_repl" = "n" ] || [ "$_repl" = "N" ]; then
            read -p "Enter a new template ID: " VMID
        else
            _destroy=1
        fi
    fi

    if [ $_destroy -eq 1 ]; then
        echo "Destroying existing VM template..."
        qm destroy $VMID --destroy-unreferenced-disks 1 --purge 1
        break
    fi
done

# Resize the image
echo "Resizing the image..."
qemu-img resize "$IMAGE_NAME" "$IMAGE_SIZE"

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
    --run-command 'cloud-init clean' \
    --truncate '/etc/machine-id'


# Create the VM template
echo "Creating VM template..."
[ ! -z "$NAME" ] && NAME_OPT="--name"
qm create $VMID ${NAME:+--name $NAME} --machine q35 --ostype l26 --cpu host \
    --cores 2 --memory 1024 --balloon 1024 --onboot 1 --agent enabled=1 \
    --net0 virtio,bridge=vmbr0,firewall=1 \
    --bios ovmf --efidisk0 "$STORAGE:0,efitype=4m" \
    --serial0 socket --vga serial0 --scsihw virtio-scsi-single \

# Import the image to VM and convert to QCOW2
echo "Importing image into the VM..."
IMPORT_OUTPUT=`qm importdisk $VMID "$IMAGE_NAME" "$STORAGE" --format qcow2 2>&1`
DISK_NAME=`echo "$IMPORT_OUTPUT" | grep -i -o "imported disk '[^']*" | sed "s/imported disk '//" | sed 's/^unused0://'`

# Verify disk name was captured
if [ -z "$DISK_NAME" ]; then
    echo "Failed to capture the disk name from the import operation."
    exit 1
else
    echo "Imported disk name: $DISK_NAME"
fi

# Add the disk to VM
echo "Adding disk to VM template..."
qm set $VMID --scsi0 "$DISK_NAME,discard=on,ssd=1"

# Set the boot disk
echo "Setting boot disk..."
qm set $VMID --boot c --bootdisk scsi0

# Add cloud-init drive
echo "Adding cloud-init drive..."
qm set $VMID --scsi1 "$STORAGE:cloudinit"

# Set user/password/sshkeys
echo "Setting cloud-init user and password..."
if [ ! -f "$SSHKEYS" ] && [ -n "$SSHKEYS" ]; then
    echo "$SSHKEYS" > /tmp/sshkeys
    SSHKEYS=/tmp/sshkeys
fi
qm set $VMID --ciuser "$USERNAME" ${PASSWORD:+--cipassword "$PASSWORD"} ${SSHKEYS:+--sshkeys "$SSHKEYS"}
if [ ! -f "$SSHKEYS" ] && [ -n "$SSHKEYS" ]; then
    rm -f /tmp/sshkeys
fi

# Convert VM to template
echo "Converting VM to template..."
QM_TEMPLATE_OUTPUT=`qm template $VMID 2>&1`

# Check for errors and complete
if echo "$QM_TEMPLATE_OUTPUT" | grep -q "chattr: Operation not supported"; then
    echo "Note: 'chattr' operation not supported on this storage. This does not impact the template functionality."
else
    echo "VM template conversion completed successfully."
fi

# Remove unneded tools
if [ $CLEAN -eq 1 ]; then
    apt-get remove libguestfs-tools
    apt-get autoremove && apt-get clean
fi

echo "Template creation script completed."
