#!/bin/bash
# This script automates the creation and configuration of a child Macvlan interface on a parent network interface
# in Ubuntu systems using Netplan. It addresses the Docker Macvlan network limitation that prevents containers on a
# Macvlan network from connecting back to the host. By creating a child Macvlan interface on the host and configuring
# it with Netplan, this script enables bidirectional communication between the host and the containers on the Macvlan
# network. It is particularly useful for scenarios where host-container communication is required for tasks such as
# monitoring, logging, or management. The script uses networkd-dispatcher to ensure the Macvlan interface is correctly
# setup on network changes or system reboots.

# Function to display usage
usage() {
    echo "Usage: $0 <parent_interface> <macvlan_ip>"
    echo "Example: $0 enp6s21 10.40.0.40/22"
    exit 1
}

# Requires root privileges
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Check for required arguments
if [ $# -ne 2 ]; then
    echo "Error: Missing required arguments."
    usage
fi

# Assign arguments to variables
PARENT_INTERFACE=$1
MACVLAN_IP=$2

# Check for necessary tools
if ! command -v ip &> /dev/null || ! command -v netplan &> /dev/null; then
    echo "Required tools (ip or netplan) are not installed. Exiting."
    exit 1
fi

# Dispatcher script path
DISPATCHER_SCRIPT="/etc/networkd-dispatcher/routable.d/10-macvlan-interfaces.sh"

# Ensure the directory exists
mkdir -p "$(dirname "$DISPATCHER_SCRIPT")"

# Create the dispatcher script for Macvlan
cat <<EOF > "$DISPATCHER_SCRIPT"
#!/bin/bash
ip link add macvlan0 link $PARENT_INTERFACE type macvlan mode bridge
EOF

chmod +x "$DISPATCHER_SCRIPT"

# Function to update or create Netplan configuration
update_netplan() {
    local netplan_dir="/etc/netplan"
    local netplan_file="${netplan_dir}/99-macvlan0-config.yaml"

    # Netplan configuration for macvlan0
    cat <<EOF > "$netplan_file"
network:
  version: 2
  ethernets:
    macvlan0:
        addresses:
          - $MACVLAN_IP
EOF

    # Apply Netplan configuration
    netplan apply
}

# Apply Netplan configuration
update_netplan

echo "Macvlan interface setup completed with parent interface $PARENT_INTERFACE and IP $MACVLAN_IP."
