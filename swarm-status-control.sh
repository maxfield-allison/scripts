#!/bin/bash

# Swarm Node Management Script
# This script manages Docker Swarm nodes by activating or draining them.
# It supports Ubuntu systems with Docker Swarm version 24.0.7 or later.

# Default values
VERBOSE=false
DEBUG=false
MODE=""
MANAGER_ADDRESSES=""
DOCKER_API_PORT=2375
IS_GPU_NODE=false

# Load .env file if it exists
if [[ -f .env ]]; then
    export $(grep -v '^#' .env | xargs)
fi

# Logging function with timestamp
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    logger -t "swarm_node_manager" "[$level] $message"
    if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        echo "[$timestamp] [$level] $message"
    fi
}

# Debug function with timestamp
debug() {
    if [[ "$DEBUG" == "true" ]]; then
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] DEBUG: $*"
    fi
}

# Retry function with exponential backoff
retry() {
    debug "Entering function: retry with command: $*"
    local retries=5
    local count=0
    local delay=1
    local max_delay=60
    while true; do
        "$@" && break || {
            if (( count < retries )); then
                ((count++))
                log "WARNING" "Command failed. Attempt $count/$retries. Retrying in $delay seconds..."
                sleep $delay
                delay=$((delay * 2))
                (( delay > max_delay )) && delay=$max_delay
            else
                log "ERROR" "Command failed after $retries attempts."
                return 1
            fi
        }
    done
    debug "Exiting function: retry"
}

# Function to check for required dependencies
check_dependencies() {
    debug "Entering function: check_dependencies"
    local dependencies=("docker" "curl" "jq" "logger" "systemctl" "awk")
    local missing_dependencies=()
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_dependencies+=("$cmd")
        fi
    done
    if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
        echo "The following required commands are missing: ${missing_dependencies[*]}"
        echo "You can install them by running:"
        echo "sudo apt-get update && sudo apt-get install -y ${missing_dependencies[*]}"
        exit 1
    fi
    debug "All dependencies are installed."
    debug "Exiting function: check_dependencies"
}

# Function to check if Docker is running
check_docker_status() {
    debug "Entering function: check_docker_status"
    if ! systemctl is-active --quiet docker; then
        log "INFO" "Docker is not running. Attempting to start Docker..."
        retry sudo systemctl start docker
        if ! systemctl is-active --quiet docker; then
            log "ERROR" "Failed to start Docker."
            exit 1
        fi
    fi
    debug "Docker is running."
    debug "Exiting function: check_docker_status"
}

# Function to determine if the node is a manager
check_if_manager() {
    debug "Entering function: check_if_manager"
    if docker node ls &>/dev/null; then
        IS_MANAGER=true
        log "INFO" "Node '$(hostname)' is a manager node."
    else
        IS_MANAGER=false
        log "INFO" "Node '$(hostname)' is a worker node."
    fi
    debug "Node is manager: $IS_MANAGER"
    debug "Exiting function: check_if_manager"
}

# Function to get manager addresses
get_manager_addresses() {
    debug "Entering function: get_manager_addresses"
    if [[ -n "$MANAGER_ADDRESSES" ]]; then
        IFS=',' read -r -a MANAGER_NODES <<< "$MANAGER_ADDRESSES"
        debug "Using specified manager addresses: ${MANAGER_NODES[*]}"
    else
        # Attempt dynamic discovery
        MANAGER_NODES=($(docker node ls --filter "role=manager" --format '{{.Hostname}}'))
        debug "Discovered manager nodes: ${MANAGER_NODES[*]}"
        if [[ ${#MANAGER_NODES[@]} -eq 0 ]]; then
            log "ERROR" "No manager nodes found. Please specify manager addresses with the -a flag."
            exit 1
        fi
    fi
    debug "Exiting function: get_manager_addresses"
}

# Function to parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -m|--mode)
                MODE="$2"
                shift 2
                ;;
            -a|--manager-address)
                MANAGER_ADDRESSES="$2"
                shift 2
                ;;
            -p|--port)
                DOCKER_API_PORT="$2"
                shift 2
                ;;
            -g|--gpu-node)
                IS_GPU_NODE=true
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Function to retrieve node spec from manager
get_node_spec() {
    local node_id="$1"
    local manager="$2"
    local node_spec

    node_spec=$(curl -s "http://$manager:$DOCKER_API_PORT/nodes/$node_id")
    if [[ -z "$node_spec" ]]; then
        log "WARNING" "Failed to retrieve node spec from manager $manager."
        return 1
    fi
    echo "$node_spec"
}

# Function to send update request to manager
send_update_request() {
    local manager="$1"
    local node_id="$2"
    local node_version="$3"
    local payload="$4"

    local response http_body http_status
    response=$(curl -s -w "\n%{http_code}" -X POST "http://$manager:$DOCKER_API_PORT/nodes/$node_id/update?version=$node_version" \
        -H "Content-Type: application/json" \
        -d "$payload")

    # Separate response body and HTTP status code
    http_body=$(echo "$response" | head -n -1)
    http_status=$(echo "$response" | tail -n1)

    debug "HTTP status: $http_status"
    debug "Response from manager $manager: $http_body"

    if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
        return 0
    else
        return 1
    fi
}

# Function to construct payload for node update
construct_payload() {
    local availability="$1"
    local role="$2"
    local labels="$3"

    jq -n \
        --arg availability "$availability" \
        --arg role "$role" \
        --argjson labels "$labels" \
        '{Availability: $availability, Role: $role, Labels: $labels}'
}

# Function to update node (status or labels)
update_node() {
    local node_id="$1"
    local availability="$2"
    local manager
    local success=false

    get_manager_addresses

    for manager in "${MANAGER_NODES[@]}"; do
        debug "Attempting to update node on manager: $manager"
        # Get node spec
        node_spec=$(get_node_spec "$node_id" "$manager")
        if [[ $? -ne 0 ]]; then
            continue
        fi

        local node_version node_role node_labels node_availability
        node_version=$(echo "$node_spec" | jq '.Version.Index')
        if [[ -z "$node_version" || "$node_version" == "null" ]]; then
            log "WARNING" "Failed to retrieve node version from manager $manager."
            continue
        fi

        # Retrieve current role, labels, and availability
        node_role=$(echo "$node_spec" | jq -r '.Role')
        [[ -z "$node_role" || "$node_role" == "null" ]] && node_role="worker"
        node_labels=$(echo "$node_spec" | jq '.Spec.Labels')
        node_availability=$(echo "$node_spec" | jq -r '.Spec.Availability')
        [[ -z "$node_availability" || "$node_availability" == "null" ]] && node_availability="active"
        debug "Node role: $node_role"
        debug "Current node labels: $node_labels"

        # If availability is empty, use the node's current availability
        if [[ -z "$availability" ]]; then
            availability="$node_availability"
            debug "Using current node availability: $availability"
        fi

        # If GPU node, ensure gpu=true label is included
        if [[ "$IS_GPU_NODE" == "true" ]]; then
            node_labels=$(echo "$node_labels" | jq '. + {"gpu":"true"}')
            debug "Updated node labels with gpu=true: $node_labels"
        fi

        # Prepare payload
        payload=$(construct_payload "$availability" "$node_role" "$node_labels")
        debug "Payload: $payload"

        # Send update request
        if send_update_request "$manager" "$node_id" "$node_version" "$payload"; then
            log "INFO" "Successfully updated node on manager '$manager' for node '$node_id'."
            success=true
            break
        else
            log "WARNING" "Failed to update node on manager '$manager'."
        fi
    done

    if [[ "$success" != "true" ]]; then
        log "ERROR" "Failed to update node on all manager nodes."
        return 1
    fi
}

# Function to handle startup mode
handle_startup() {
    debug "Starting startup mode"
    if [[ "$IS_MANAGER" == "true" ]]; then
        debug "Node is manager"
        # Activate local node
        retry docker node update --availability active "$(hostname)"
        log "INFO" "Activated manager node '$(hostname)'."

        # Handle cold start by activating all drained nodes
        local DRAINED_NODES NODE_ID NODE_NAME
        DRAINED_NODES=$(docker node ls --filter "role=worker" --format '{{.ID}} {{.Availability}}' | awk '$2=="Drain"{print $1}')
        if [[ -n "$DRAINED_NODES" ]]; then
            debug "Drained nodes: $DRAINED_NODES"
            for NODE_ID in $DRAINED_NODES; do
                NODE_NAME=$(docker node inspect --format '{{.Description.Hostname}}' "$NODE_ID")
                retry docker node update --availability active "$NODE_ID"
                log "INFO" "Activated node '$NODE_NAME' (ID: $NODE_ID)."
            done
        else
            debug "No drained nodes found."
        fi
    else
        debug "Node is worker"
        node_id=$(docker info --format '{{.Swarm.NodeID}}')
        retry update_node "$node_id" "active"
    fi
    debug "Completed startup mode"
}

# Function to handle shutdown mode
handle_shutdown() {
    debug "Starting shutdown mode"
    if [[ "$IS_MANAGER" == "true" ]]; then
        debug "Node is manager"
        # Drain local node
        retry docker node update --availability drain "$(hostname)"
        log "INFO" "Drained manager node '$(hostname)'."
    else
        debug "Node is worker"
        node_id=$(docker info --format '{{.Swarm.NodeID}}')
        retry update_node "$node_id" "drain"
    fi

    # Graceful shutdown: wait for tasks to finish
    local TIMEOUT=120  # 2 minutes
    local INTERVAL=5
    local ELAPSED=0
    local TASKS
    while (( ELAPSED < TIMEOUT )); do
        TASKS=$(docker node ps --filter "desired-state=running" --format '{{.ID}}')
        debug "Running tasks: $TASKS"
        if [[ -z "$TASKS" ]]; then
            log "INFO" "All tasks on node '$(hostname)' have finished."
            break
        else
            log "INFO" "Waiting for tasks to finish on node '$(hostname)'..."
            sleep $INTERVAL
            ELAPSED=$((ELAPSED + INTERVAL))
        fi
    done
    if (( ELAPSED >= TIMEOUT )); then
        log "WARNING" "Timeout reached before all tasks finished on node '$(hostname)'."
    fi
    debug "Completed shutdown mode"
}

# Display help information
show_help() {
    cat << EOF
Usage: $0 [options]
Options:
  -h, --help                Show this help message and exit.
  -v, --verbose             Enable verbose logging.
  -d, --debug               Enable debug mode with detailed output.
  -m, --mode <startup|shutdown|su|sd>
                            Set the mode to startup or shutdown.
  -a, --manager-address <addresses>
                            Comma-separated list of manager addresses.
  -p, --port <port>         Specify the Docker API port (default: 2375).
  -g, --gpu-node            Indicate that this node is a GPU node.
EOF
    exit 0
}

# Main script execution

# Parse command-line arguments
parse_arguments "$@"

# Check for required commands
check_dependencies

# Validate MODE
if [[ -z "$MODE" ]]; then
    log "ERROR" "Mode not specified. Use -m to set mode (startup/su or shutdown/sd)."
    exit 1
fi

# Normalize MODE
case "$MODE" in
    startup|su)
        MODE="startup"
        ;;
    shutdown|sd)
        MODE="shutdown"
        ;;
    *)
        log "ERROR" "Invalid mode specified: $MODE"
        exit 1
        ;;
esac

# Check Docker status
check_docker_status

# Determine if the node is a manager
check_if_manager

# If GPU node, ensure the gpu=true label is set
if [[ "$IS_GPU_NODE" == "true" ]]; then
    if [[ "$IS_MANAGER" == "true" ]]; then
        # Manager nodes can update labels directly
        retry docker node update --label-add gpu=true "$(hostname)"
        log "INFO" "Added gpu=true label to manager node '$(hostname)'."
    else
        # Worker nodes need to use the Docker API
        node_id=$(docker info --format '{{.Swarm.NodeID}}')
        retry update_node "$node_id" ""
    fi
fi

# Main logic based on MODE
if [[ "$MODE" == "startup" ]]; then
    handle_startup
elif [[ "$MODE" == "shutdown" ]]; then
    handle_shutdown
fi
