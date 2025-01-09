#!/bin/bash

###############################################################################
# Swarm Node Management Script
#
# This script manages Docker Swarm nodes by activating or draining them during
# system startup and shutdown. It supports both manager and worker nodes,
# handles GPU nodes, and ensures tasks are gracefully drained.
#
# Compatibility: Ubuntu systems with Docker Swarm.
#
# Author: [Your Name]
# Version: 2.2.3
###############################################################################
trap "" SIGPIPE
set -euo pipefail  # Enable strict error handling


# Default values (can be overridden in /etc/swarm-node-manager.conf)
VERBOSE=false
DEBUG=false
MODE=""
MANAGER_ADDRESSES=""
DOCKER_API_PORT=2375
IS_GPU_NODE=false
SIMULATION_MODE=false
TIMEOUT=90   # Default total wait time in seconds
INTERVAL=10  # Default interval between checks in seconds

# List of required commands
REQUIRED_COMMANDS=(
    "docker"
    "curl"
    "jq"
    "logger"
    "systemctl"
    "awk"
    "lspci"  # For GPU detection
)

# Load configuration from /etc/swarm-node-manager.conf if it exists
CONFIG_FILE="/etc/swarm-node-manager.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Check if the script is running on a supported OS
if [[ "$OSTYPE" != "linux-gnu"* ]]; then
    echo "WARNING: This script is designed for Linux systems. Detected OS: $OSTYPE"
    log "WARNING" "This script is designed for Linux systems. Detected OS: $OSTYPE"
fi

###############################################################################
# Logging function with timestamp and structured format
# Parameters:
#   $1 - Log level (DEBUG, INFO, WARNING, ERROR)
#   $2 - Log message
###############################################################################
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date --iso-8601=seconds)
    local syslog_level

    case "$level" in
        DEBUG) syslog_level="debug" ;;
        INFO) syslog_level="info" ;;
        WARNING) syslog_level="warn" ;;
        ERROR) syslog_level="err" ;;
        *) syslog_level="notice" ;;
    esac

    # Truncate the message to a safe length (e.g., 1024 characters) without a pipeline
    local truncated_message
    truncated_message=$(printf "%.1024s" "$message")

    local log_entry
    log_entry="[$timestamp][$level] $truncated_message"

    # Send log entry to syslog with truncated message
    logger -p "user.$syslog_level" -t "swarm_node_manager" "$log_entry"

    # Output log entry to console during startup and shutdown, ignore broken pipe errors
    if [[ -t 0 || "$INVOCATION_ID" != "" ]]; then
        echo "$log_entry" 2>/dev/null || true
    fi

    # Write log entry to /dev/console for visibility during shutdown, ignore broken pipe errors
    if [[ -w /dev/console ]]; then
        echo "$log_entry" > /dev/console 2>/dev/null || true
    fi
}


###############################################################################
# Debug function
# Parameters:
#   $* - Debug message
###############################################################################
debug() {
    if [[ "$DEBUG" == "true" ]]; then
        log "DEBUG" "$*"
    fi
}

###############################################################################
# Retry function with exponential backoff
# Parameters:
#   $@ - Command to execute
# Returns:
#   0 if the command succeeds, 1 otherwise
###############################################################################
retry() {
    debug "Entering function: retry with command: $*"
    local retries=5
    local count=0
    local delay=1
    local max_delay=60
    while true; do
        if "$@"; then
            break
        else
            if (( count < retries )); then
                ((count++))
                log "WARNING" "Command failed. Attempt $count/$retries. Retrying in $delay seconds..."
                sleep "$delay"
                delay=$((delay * 2))
                (( delay > max_delay )) && delay=$max_delay
            else
                log "ERROR" "Command failed after $retries attempts: $*"
                return 1
            fi
        fi
    done
    debug "Exiting function: retry"
}

###############################################################################
# Simplified function to check for required dependencies
# Parameters: None
# Returns:
#   Exits the script if any dependencies are missing
###############################################################################
check_dependencies() {
    debug "Entering function: check_dependencies"
    local missing_dependencies=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_dependencies+=("$cmd")
        fi
    done
    if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
        log "ERROR" "Missing dependencies: ${missing_dependencies[*]}"
        echo "Please install the following dependencies:"
        for dep in "${missing_dependencies[@]}"; do
            case "$dep" in
                docker) echo "  - Docker (https://docs.docker.com/engine/install/)" ;;
                curl) echo "  - curl (e.g., sudo apt install curl)" ;;
                jq) echo "  - jq (e.g., sudo apt install jq)" ;;
                logger) echo "  - logger (should be included in util-linux, e.g., sudo apt install util-linux)" ;;
                systemctl) echo "  - systemctl (part of systemd, usually included in most distributions)" ;;
                awk) echo "  - awk (e.g., sudo apt install gawk)" ;;
                lspci) echo "  - lspci (part of pciutils, e.g., sudo apt install pciutils)" ;;
            esac
        done
        exit 1
    fi
    debug "All dependencies are installed."
    debug "Exiting function: check_dependencies"
}

###############################################################################
# Function to check if Docker is running
# Parameters: None
# Returns:
#   Exits the script if Docker cannot be started
###############################################################################
check_docker_status() {
    debug "Entering function: check_docker_status"
    if ! systemctl is-active --quiet docker; then
        log "INFO" "Docker is not running. Attempting to start Docker..."
        if ! retry sudo systemctl start docker; then
            log "ERROR" "Failed to start Docker after multiple attempts."
            echo "Please ensure Docker is installed and can be started."
            exit 1
        fi
    fi
    debug "Docker is running."
    debug "Exiting function: check_docker_status"
}

###############################################################################
# Function to determine if the node is a manager
# Parameters: None
# Sets:
#   IS_MANAGER - true if the node is a manager, false otherwise
###############################################################################
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

###############################################################################
# Function to parse command-line arguments
# Parameters:
#   $@ - Command-line arguments
###############################################################################
parse_arguments() {
    while getopts ":hvdsm:a:p:gt:i:" opt; do
        case "$opt" in
            h) show_help ;;
            v) VERBOSE=true ;;
            d) DEBUG=true ;;
            s) SIMULATION_MODE=true ;;
            m) MODE="$OPTARG" ;;
            a) MANAGER_ADDRESSES="$OPTARG" ;;
            p) DOCKER_API_PORT="$OPTARG" ;;
            g) IS_GPU_NODE=true ;;
            t) TIMEOUT="$OPTARG" ;;
            i) INTERVAL="$OPTARG" ;;
            \?) log "ERROR" "Invalid option: -$OPTARG"; show_help ;;
            :) log "ERROR" "Option -$OPTARG requires an argument."; show_help ;;
        esac
    done
    shift $((OPTIND -1))
}

###############################################################################
# Function to detect GPU presence
# Parameters: None
# Sets:
#   IS_GPU_NODE - true if GPU is detected, false otherwise
###############################################################################
detect_gpu() {
    debug "Entering function: detect_gpu"
    if command -v lspci &>/dev/null; then
        if lspci | grep -i 'nvidia\|amd' &>/dev/null; then
            IS_GPU_NODE=true
            log "INFO" "Detected GPU on node '$(hostname)'."
        else
            log "INFO" "No GPU detected on node '$(hostname)'."
        fi
    else
        log "WARNING" "lspci command not found. Cannot detect GPU automatically."
    fi
    debug "Exiting function: detect_gpu"
}

###############################################################################
# Function to update node labels
# Parameters:
#   $1 - Node ID
#   $2 - Labels (JSON string)
# Returns:
#   0 if successful, 1 otherwise
###############################################################################
update_node_labels() {
    local node_id="$1"
    local labels="$2"
    debug "Entering function: update_node_labels for node_id: $node_id with labels: $labels"
    local manager
    local success=false

    get_manager_addresses

    for manager in "${MANAGER_NODES[@]}"; do
        debug "Attempting to update labels on manager: $manager"
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

        # Retrieve current role and availability
        node_role=$(echo "$node_spec" | jq -r '.Role')
        [[ -z "$node_role" || "$node_role" == "null" ]] && node_role="worker"
        node_availability=$(echo "$node_spec" | jq -r '.Spec.Availability')
        [[ -z "$node_availability" || "$node_availability" == "null" ]] && node_availability="active"

        # Merge existing labels with new labels
        node_labels=$(echo "$node_spec" | jq '.Spec.Labels')
        node_labels=$(echo "$node_labels" | jq --argjson new_labels "$labels" '. + $new_labels')
        debug "Updated node labels: $node_labels"

        # Prepare payload
        payload=$(construct_payload "$node_availability" "$node_role" "$node_labels")
        debug "Payload: $payload"

        # Send update request
        if send_update_request "$manager" "$node_id" "$node_version" "$payload"; then
            log "INFO" "Successfully updated labels on node '$node_id' via manager '$manager'."
            success=true
            break
        else
            log "WARNING" "Failed to update labels on node via manager '$manager'."
        fi
    done

    if [[ "$success" != "true" ]]; then
        log "ERROR" "Failed to update labels on node via all manager nodes."
        return 1
    fi

    debug "Exiting function: update_node_labels"
}

###############################################################################
# Function to get manager addresses
# Parameters: None
# Sets:
#   MANAGER_NODES - array of manager addresses
# Returns:
#   Exits the script if no manager addresses are found
###############################################################################
get_manager_addresses() {
    debug "Entering function: get_manager_addresses"
    if [[ -n "$MANAGER_ADDRESSES" ]]; then
        IFS=',' read -r -a MANAGER_NODES <<< "$MANAGER_ADDRESSES"
        debug "Using specified manager addresses: ${MANAGER_NODES[*]}"
    else
        # Attempt dynamic discovery
        readarray -t MANAGER_NODES < <(docker node ls --filter "role=manager" --format '{{.Hostname}}')
        debug "Discovered manager nodes: ${MANAGER_NODES[*]}"
        if [[ ${#MANAGER_NODES[@]} -eq 0 ]]; then
            log "ERROR" "No manager nodes found. Please specify manager addresses with the -a flag."
            exit 1
        fi
    fi
    debug "Exiting function: get_manager_addresses"
}

###############################################################################
# Function to retrieve node spec from manager
# Parameters:
#   $1 - Node ID
#   $2 - Manager address
# Returns:
#   Node specification JSON
###############################################################################
get_node_spec() {
    local node_id="$1"
    local manager="$2"
    local node_spec

    node_spec=$(curl -s --max-time 10 "http://$manager:$DOCKER_API_PORT/nodes/$node_id")
    if [[ -z "$node_spec" ]]; then
        log "WARNING" "Failed to retrieve node spec from manager $manager."
        return 1
    fi
    echo "$node_spec"
}

###############################################################################
# Function to send update request to manager
# Parameters:
#   $1 - Manager address
#   $2 - Node ID
#   $3 - Node version
#   $4 - Payload (JSON)
# Returns:
#   0 if successful, 1 otherwise
###############################################################################
send_update_request() {
    local manager="$1"
    local node_id="$2"
    local node_version="$3"
    local payload="$4"

    local response http_body http_status
    response=$(curl -s --max-time 10 -w "\n%{http_code}" -X POST "http://$manager:$DOCKER_API_PORT/nodes/$node_id/update?version=$node_version" \
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
        log "ERROR" "Failed to update node via manager $manager. HTTP status: $http_status"
        return 1
    fi
}

###############################################################################
# Function to construct payload for node update
# Parameters:
#   $1 - Availability
#   $2 - Role
#   $3 - Labels (JSON)
# Returns:
#   Payload JSON
###############################################################################
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

###############################################################################
# Function to update node (status or labels)
# Parameters:
#   $1 - Node ID
#   $2 - Availability (e.g., active, drain)
# Returns:
#   0 if successful, 1 otherwise
###############################################################################
update_node() {
    local node_id="$1"
    local availability="$2"
    debug "Entering function: update_node with node_id: $node_id and availability: $availability"
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

    debug "Exiting function: update_node"
}

###############################################################################
# Function to wait for tasks to drain with progress indicator
# Parameters:
#   $1 - Node ID
# Returns:
#   None
###############################################################################
wait_for_tasks_to_drain() {
    local node_id="$1"
    local manager="${MANAGER_NODES[0]}"
    local elapsed=0
    local running_tasks non_terminal_tasks tasks_response leftover_containers

    log "INFO" "Waiting for tasks to drain on node '$(hostname)'..."

    while (( elapsed < TIMEOUT )); do
        # Construct the filters JSON (compact form):
        local filters
        filters="$(jq -c -n --arg node "$node_id" '{"node": [$node]}')"
        debug "Will query Docker tasks with filters: $filters"

        # Use curl --get + --data-urlencode to properly handle JSON in the query
        tasks_response=$(
            curl --silent --show-error --get "http://$manager:$DOCKER_API_PORT/tasks" \
                --data-urlencode "filters=$filters" \
                --write-out "\nHTTP_CODE:%{http_code}\n" \
                --location --max-time 10
        )
        local curl_ec=$?

        # Separate the HTTP code from the body
        local http_body
        local http_code
        http_body="$(echo "$tasks_response" | sed -e '/^HTTP_CODE:/d')"
        http_code="$(echo "$tasks_response" | grep 'HTTP_CODE:' | cut -d: -f2)"

        if [[ $curl_ec -ne 0 ]]; then
            log "ERROR" "curl failed with exit code $curl_ec. Output: $tasks_response"
            log "WARNING" "Cannot query tasks. Proceeding with shutdown (simulation or otherwise)."
            break
        fi

        if [[ "$http_code" -ge 400 ]]; then
            log "ERROR" "Curl returned HTTP $http_code. Body: $http_body"
            # Decide if you want to exit or continue; we'll continue here
        fi

        debug "Response from tasks endpoint: $tasks_response"

        # Attempt to parse with jq. If jq fails, set counts to 0 so we don't exit the script.
        running_tasks="$(echo "$http_body" \
            | jq -r '[.[] | select(.Status.State == "running")] | length' 2>/dev/null || echo 0)"
        running_tasks="$(echo "$running_tasks" | tr -d '[:space:]')"

        non_terminal_tasks="$(echo "$http_body" \
            | jq -r '[.[] | select(.Status.State | inside("new pending assigned accepted ready preparing starting"))] | length' 2>/dev/null || echo 0)"
        non_terminal_tasks="$(echo "$non_terminal_tasks" | tr -d '[:space:]')"

        debug "running_tasks: $running_tasks, non_terminal_tasks: $non_terminal_tasks"

        if [[ "$running_tasks" -eq 0 && "$non_terminal_tasks" -eq 0 ]]; then
            log "INFO" "All tasks have been drained from node '$(hostname)'."
            break
        fi

        log "INFO" "Tasks still running on node '$(hostname)': $running_tasks running, $non_terminal_tasks non-terminal. Waiting..."
        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
    done

    if (( elapsed >= TIMEOUT )); then
        log "WARNING" "Timeout reached before all tasks drained on node '$(hostname)'. Proceeding with forced container removal."
        if [[ "$SIMULATION_MODE" == "true" ]]; then
            log "INFO" "Simulation mode: would force-stop leftover containers, but doing nothing here."
        else
            leftover_containers="$(docker ps -q)"
            if [[ -n "$leftover_containers" ]]; then
                log "INFO" "Forcing removal of leftover containers: $(docker ps --format '{{.Names}}')"
                echo "$leftover_containers" | xargs --no-run-if-empty docker rm -f
            else
                log "INFO" "No leftover containers found. Nothing to force-remove."
            fi
        fi
    else
        log "INFO" "All tasks have been drained successfully."
    fi
}


###############################################################################
# Function to handle startup mode
# Parameters: None
# Returns:
#   None
###############################################################################
handle_startup() {
    debug "Starting startup mode"

    # Detect GPU automatically if not set
    if [[ "$IS_GPU_NODE" == "false" ]]; then
        detect_gpu
    fi

    # If GPU node, ensure the gpu=true label is set
    if [[ "$IS_GPU_NODE" == "true" ]]; then
        if [[ "$IS_MANAGER" == "true" ]]; then
            if [[ "$SIMULATION_MODE" == "true" ]]; then
                log "INFO" "Simulation mode: Would add gpu=true label to manager node '$(hostname)'."
            else
                retry docker node update --label-add gpu=true "$(hostname)" || { log "ERROR" "Failed to add gpu=true label to manager node."; exit 1; }
                log "INFO" "Added gpu=true label to manager node '$(hostname)'."
            fi
        else
            node_id=$(docker info --format '{{.Swarm.NodeID}}')
            labels='{"gpu":"true"}'
            if [[ "$SIMULATION_MODE" == "true" ]]; then
                log "INFO" "Simulation mode: Would update node labels on node '$node_id'."
            else
                retry update_node_labels "$node_id" "$labels" || { log "ERROR" "Failed to update node labels."; exit 1; }
            fi
        fi
    fi
    if [[ "$IS_MANAGER" == "true" ]]; then
        debug "Node is manager"
        if [[ "$SIMULATION_MODE" == "true" ]]; then
            log "INFO" "Simulation mode: Would activate manager node '$(hostname)'."
        else
            retry docker node update --availability active "$(hostname)" || { log "ERROR" "Failed to activate manager node."; exit 1; }
            log "INFO" "Activated manager node '$(hostname)'."
        fi

        # Handle cold start by activating all drained nodes
        local DRAINED_NODES NODE_ID NODE_NAME
        DRAINED_NODES=$(docker node ls --filter "role=worker" --format '{{.ID}} {{.Availability}}' | awk '$2=="Drain"{print $1}')
        if [[ -n "$DRAINED_NODES" ]]; then
            debug "Drained nodes: $DRAINED_NODES"
            for NODE_ID in $DRAINED_NODES; do
                NODE_NAME=$(docker node inspect --format '{{.Description.Hostname}}' "$NODE_ID")
                if [[ "$SIMULATION_MODE" == "true" ]]; then
                    log "INFO" "Simulation mode: Would activate node '$NODE_NAME' (ID: $NODE_ID)."
                else
                    retry docker node update --availability active "$NODE_ID" || { log "ERROR" "Failed to activate node '$NODE_NAME'."; exit 1; }
                    log "INFO" "Activated node '$NODE_NAME' (ID: $NODE_ID)."
                fi
            done
        else
            debug "No drained nodes found."
        fi
    else
        debug "Node is worker"
        node_id=$(docker info --format '{{.Swarm.NodeID}}')
        if [[ "$SIMULATION_MODE" == "true" ]]; then
            log "INFO" "Simulation mode: Would update node '$node_id' to active."
        else
            retry update_node "$node_id" "active" || { log "ERROR" "Failed to update node to active."; exit 1; }
            log "INFO" "Activated worker node '$(hostname)'."
        fi
    fi
    debug "Completed startup mode"
}

###############################################################################
# Function to handle shutdown mode
# Parameters: None
# Returns:
#   None
###############################################################################
handle_shutdown() {
    debug "Starting shutdown mode"
    local node_id

    if [[ "$IS_MANAGER" == "true" ]]; then
        debug "Node is manager"
        if [[ "$SIMULATION_MODE" == "true" ]]; then
            log "INFO" "Simulation mode: Would drain manager node '$(hostname)'."
        else
            retry docker node update --availability drain "$(hostname)" || { log "ERROR" "Failed to drain manager node."; exit 1; }
            log "INFO" "Drained manager node '$(hostname)'."
        fi
        node_id=$(docker node inspect --format '{{.ID}}' "$(hostname)")
    else
        debug "Node is worker"
        node_id=$(docker info --format '{{.Swarm.NodeID}}')
        if [[ "$SIMULATION_MODE" == "true" ]]; then
            log "INFO" "Simulation mode: Would update node '$node_id' to drain."
        else
            retry update_node "$node_id" "drain" || { log "ERROR" "Failed to update node to drain."; exit 1; }
            log "INFO" "Drained worker node '$(hostname)'."
        fi
    fi

    if [[ "$SIMULATION_MODE" == "false" ]]; then
        # Graceful shutdown: wait for tasks to drain
        wait_for_tasks_to_drain "$node_id"
    else
        log "INFO" "Simulation mode: Would wait for tasks to drain on node '$node_id'."
    fi

    debug "Completed shutdown mode"
}

###############################################################################
# Display help information
# Parameters: None
# Returns:
#   Exits the script after displaying help
###############################################################################
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
                            Example: -a "manager1.example.com,manager2.example.com"
  -p, --port <port>         Specify the Docker API port (default: 2375).
  -g, --gpu-node            Indicate that this node is a GPU node.
  -s, --simulate            Run in simulation mode without making changes.
  -t, --timeout <seconds>   Set the timeout for draining tasks (default: 90).
  -i, --interval <seconds>  Set the interval between task checks (default: 10).

Examples:
  $0 -m startup -a "manager1.example.com" -p 2376
  $0 -m shutdown --simulate

EOF
    exit 0
}

###############################################################################
# Main script execution
# Parameters:
#   $@ - Command-line arguments
###############################################################################
main() {
    # Parse command-line arguments
    parse_arguments "$@"

    # Check for required commands
    check_dependencies

    # Validate MODE
    if [[ -z "$MODE" ]]; then
        log "ERROR" "Mode not specified. Use -m to set mode (startup/su or shutdown/sd)."
        echo "For example, use -m startup to activate the node on startup."
        show_help
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
            echo "Valid modes are startup or shutdown."
            show_help
            ;;
    esac

    # Validate DOCKER_API_PORT
    if ! [[ "$DOCKER_API_PORT" =~ ^[0-9]+$ ]] || [ "$DOCKER_API_PORT" -lt 1 ] || [ "$DOCKER_API_PORT" -gt 65535 ]; then
        log "ERROR" "Invalid port number: $DOCKER_API_PORT"
        echo "Port number must be an integer between 1 and 65535."
        exit 1
    fi

    # Only check Docker status if we're in 'startup' mode
    if [[ "$MODE" == "startup" ]]; then
        check_docker_status
    fi
    # Determine if the node is a manager
    check_if_manager

    # Handle the mode
    if [[ "$MODE" == "startup" ]]; then
        handle_startup
    elif [[ "$MODE" == "shutdown" ]]; then
        handle_shutdown
    fi
}

main "$@"
