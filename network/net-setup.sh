#!/bin/bash

# Script to create multiple Docker networks from a YAML configuration file,
# supporting optional parameters for each network type.
# Also sets up iptables rules for inter-network communication.
# Requires 'yq' (YAML processor).
#
# This version includes a conditional debug mode controlled by the --debug flag,
# a --network flag to only apply iptables rules for existing networks,
# and a --help flag for usage instructions.

# --- Usage Function ---
show_usage() {
  echo "Usage: $0 [--help] [--debug] [--network] <path_to_yaml_config_file>"
  echo ""
  echo "Options:"
  echo "  --help          Display this help message and exit."
  echo "  --debug         Enable debug output for detailed execution tracing."
  echo "  --network       Skip Docker network creation. Only apply iptables rules"
  echo "                  for networks defined in the YAML that already exist."
  echo ""
  echo "Arguments:"
  echo "  <path_to_yaml_config_file>  The path to your Docker network configuration YAML file (e.g., networks.yaml)."
  echo ""
  echo "Examples:"
  echo "  $0 networks.yaml                   # Create networks and apply iptables rules."
  echo "  $0 --debug networks.yaml           # Same as above, with debug output."
  echo "  $0 --network networks.yaml         # Only apply iptables rules for existing networks."
  echo "  $0 --debug --network networks.yaml # Same as above, with debug output."
  echo ""
  echo "Prerequisites:"
  echo "  - Docker must be installed and running."
  echo "  - 'yq' (YAML processor) must be installed. (See https://github.com/mikefarah/yq for installation)."
  echo ""
  echo "Important Notes:"
  echo "  - This script requires 'sudo' privileges to execute Docker and iptables commands."
  echo "  - For 'macvlan' and 'ipvlan' networks, 'parent_interface', 'subnet', and 'gateway' are mandatory."
  echo "    Ensure these match your physical network configuration."
}

# --- Argument Parsing ---
DEBUG_MODE=0
NETWORK_ONLY_MODE=0
CONFIG_FILE=""

# Parse flags and arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --help)
            show_usage
            exit 0
            ;;
        --debug)
            DEBUG_MODE=1
            echo "DEBUG: Debug mode enabled."
            ;;
        --network)
            NETWORK_ONLY_MODE=1
            if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Network-only mode enabled. Skipping network creation."; fi
            ;;
        -*) # Unknown option
            echo "Error: Unknown option '$1'"
            show_usage
            exit 1
            ;;
        *) # Positional argument (config file)
            if [ -z "$CONFIG_FILE" ]; then
                CONFIG_FILE="$1"
            else
                echo "Error: Too many arguments. Configuration file already specified as '${CONFIG_FILE}'."
                show_usage
                exit 1
            fi
            ;;
    esac
    shift # Process next argument
done

# --- Check for yq installation ---
if ! command -v yq >/dev/null 2>&1; then
  echo "Error: 'yq' command not found."
  echo "This script requires 'yq' to parse the YAML configuration file."
  echo "Please install yq (e.g., via snap, brew, or download from https://github.com/mikefarah/yq/releases)."
  exit 1
fi

# Check if a configuration file is provided
if [ -z "$CONFIG_FILE" ]; then
  echo "Error: Configuration file not provided."
  show_usage
  exit 1
fi

# Check if the configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Configuration file '${CONFIG_FILE}' not found."
  exit 1
fi

echo "--- Starting Docker Network Setup ---"
echo "Reading configurations from: ${CONFIG_FILE}"
echo ""

# Declare an array to store network configurations for the iptables pass
# Format: "NAME;TYPE;PARENT_INTERFACE;SUBNET;GATEWAY;IP_RANGE;HOST_INTERFACE;MODE;ALLOWED_NETWORKS_CSV"
declare -a NETWORK_DEFINITIONS_FOR_IPTABLES

# --- Pass 1: Create Networks (unless in network-only mode) ---
if [ "$NETWORK_ONLY_MODE" -eq 0 ]; then
  echo "--- Pass 1: Creating Docker Networks ---"
  # Use yq to iterate through the networks array in the YAML file
  while IFS=';' read -r NAME_JSON TYPE_JSON PARENT_INTERFACE_JSON SUBNET_JSON GATEWAY_JSON IP_RANGE_JSON HOST_INTERFACE_JSON MODE_JSON ALLOWED_NETWORKS_JSON; do

    # Strip quotes and convert 'null' to empty strings for all fields
    NAME=$(echo "$NAME_JSON" | sed 's/^"//;s/"$//;s/null//')
    TYPE=$(echo "$TYPE_JSON" | sed 's/^"//;s/"$//;s/null//')
    PARENT_INTERFACE=$(echo "$PARENT_INTERFACE_JSON" | sed 's/^"//;s/"$//;s/null//')
    SUBNET=$(echo "$SUBNET_JSON" | sed 's/^"//;s/"$//;s/null//')
    GATEWAY=$(echo "$GATEWAY_JSON" | sed 's/^"//;s/"$//;s/null//')
    IP_RANGE=$(echo "$IP_RANGE_JSON" | sed 's/^"//;s/"$//;s/null//')
    HOST_INTERFACE=$(echo "$HOST_INTERFACE_JSON" | sed 's/^"//;s/"$//;s/null//')
    MODE=$(echo "$MODE_JSON" | sed 's/^"//;s/"$//;s/null//')
    ALLOWED_NETWORKS_CSV=$(echo "$ALLOWED_NETWORKS_JSON" | sed 's/^"//;s/"$//;s/null//')

    # Trim leading/trailing whitespace again, just in case
    NAME=$(echo "$NAME" | xargs)
    TYPE=$(echo "$TYPE" | xargs)
    PARENT_INTERFACE=$(echo "$PARENT_INTERFACE" | xargs)
    SUBNET=$(echo "$SUBNET" | xargs)
    GATEWAY=$(echo "$GATEWAY" | xargs)
    IP_RANGE=$(echo "$IP_RANGE" | xargs)
    HOST_INTERFACE=$(echo "$HOST_INTERFACE" | xargs)
    MODE=$(echo "$MODE" | xargs)
    ALLOWED_NETWORKS_CSV=$(echo "$ALLOWED_NETWORKS_CSV" | xargs)

    # Basic validation: Name and Type are mandatory
    if [ -z "$NAME" ]; then
      echo "Error: Network name is missing in a configuration entry. Skipping this entry."
      echo ""
      continue
    fi
    if [ -z "$TYPE" ]; then
      echo "Error: Network type is missing for network '${NAME}'. Skipping network creation for '${NAME}'."
      echo ""
      continue
    fi

    echo "Attempting to create network: ${NAME} (Type: ${TYPE})"

    # Check if network already exists before attempting to create
    if docker network inspect "$NAME" >/dev/null 2>&1; then
      echo "Network '${NAME}' already exists. Skipping creation."
      # Still add to NETWORK_DEFINITIONS_FOR_IPTABLES for potential rule application
      NETWORK_DEFINITIONS_FOR_IPTABLES+=("${NAME};${TYPE};${PARENT_INTERFACE};${SUBNET};${GATEWAY};${IP_RANGE};${HOST_INTERFACE};${MODE};${ALLOWED_NETWORKS_CSV}")
      echo ""
      continue
    fi

    # Build the docker network create command
    COMMAND="docker network create -d ${TYPE} "
    OPTIONS=""
    SKIP_NETWORK=0 # Flag to skip current network if validation fails

    case "$TYPE" in
      "bridge")
        if [ -n "$SUBNET" ]; then
          OPTIONS="${OPTIONS} --subnet=${SUBNET}"
        fi
        if [ -n "$GATEWAY" ]; then
          OPTIONS="${OPTIONS} --gateway=${GATEWAY}"
        fi
        if [ -n "$IP_RANGE" ]; then
          OPTIONS="${OPTIONS} --ip-range=${IP_RANGE}"
        fi
        if [ -n "$HOST_INTERFACE" ]; then
          OPTIONS="${OPTIONS} -o \"com.docker.network.bridge.name=${HOST_INTERFACE}\""
          if [ "$DEBUG_MODE" -eq 1 ]; then echo "  - DEBUG: Custom host bridge interface name requested: ${HOST_INTERFACE}"; fi
        fi
        ;;
      "macvlan"|"ipvlan")
        if [ -z "$PARENT_INTERFACE" ]; then
          echo "Error: ${TYPE} network '${NAME}' requires 'parent_interface' but none was found."
          echo "Skipping network creation for '${NAME}'."
          SKIP_NETWORK=1
        fi
        if [ -z "$SUBNET" ]; then
          echo "Error: ${TYPE} network '${NAME}' requires 'subnet' but none was found."
          echo "Skipping network creation for '${NAME}'."
          SKIP_NETWORK=1
        fi
        if [ -z "$GATEWAY" ]; then
          echo "Error: ${TYPE} network '${NAME}' requires 'gateway' but none was found."
          echo "Skipping network creation for '${NAME}'."
          SKIP_NETWORK=1
        fi

        if [ $SKIP_NETWORK -eq 0 ]; then
          OPTIONS="${OPTIONS} --subnet=${SUBNET} --gateway=${GATEWAY} -o parent=${PARENT_INTERFACE}"
        fi

        if [ -n "$IP_RANGE" ]; then
          OPTIONS="${OPTIONS} --ip-range=${IP_RANGE}"
        fi

        if [ "$TYPE" = "ipvlan" ] && [ -n "$MODE" ]; then
          OPTIONS="${OPTIONS} -o ipvlan_mode=${MODE}"
          if [ "$DEBUG_MODE" -eq 1 ]; then echo "  - DEBUG: IPvlan mode specified: ${MODE}"; fi
        fi

        if [ -n "$HOST_INTERFACE" ]; then
          if [ "$DEBUG_MODE" -eq 1 ]; then
            echo "  - DEBUG: Note: 'host_interface' parameter '${HOST_INTERFACE}' is ignored for ${TYPE} network '${NAME}'."
            echo "    The 'parent_interface' ('${PARENT_INTERFACE}') defines the host association."
          fi
        fi
        ;;
      *)
        echo "Warning: Unknown network type '${TYPE}' for network '${NAME}'. Please use 'bridge', 'macvlan', or 'ipvlan'. Skipping."
        SKIP_NETWORK=1
        ;;
    esac

    if [ $SKIP_NETWORK -eq 1 ]; then
      echo ""
      continue
    fi

    FULL_COMMAND="docker network create -d ${TYPE} ${OPTIONS} ${NAME}"
    if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Executing: ${FULL_COMMAND}"; fi
    eval "$FULL_COMMAND"

    if [ $? -eq 0 ]; then
      echo "Successfully created network: '${NAME}'."
      NETWORK_DEFINITIONS_FOR_IPTABLES+=("${NAME};${TYPE};${PARENT_INTERFACE};${SUBNET};${GATEWAY};${IP_RANGE};${HOST_INTERFACE};${MODE};${ALLOWED_NETWORKS_CSV}")
    else
      echo "Failed to create network: '${NAME}'. Check Docker output for details."
    fi
    echo ""

  done < <(yq -r '.networks[] | [(.name | @json), (.type | @json), (.parent_interface | @json), (.subnet | @json), (.gateway | @json), (.ip_range | @json), (.host_interface | @json), (.mode | @json), (.allowed_networks | join(",") | @json)] | join(";")' "$CONFIG_FILE")
else # In NETWORK_ONLY_MODE
  echo "--- Pass 1: Skipping Docker Network Creation (Network-Only Mode) ---"
  # In network-only mode, we still need to populate NETWORK_DEFINITIONS_FOR_IPTABLES
  # with networks defined in the YAML that *actually exist* on the system.
  echo "Collecting definitions for existing networks from YAML..."
  while IFS=';' read -r NAME_JSON TYPE_JSON PARENT_INTERFACE_JSON SUBNET_JSON GATEWAY_JSON IP_RANGE_JSON HOST_INTERFACE_JSON MODE_JSON ALLOWED_NETWORKS_JSON; do

    NAME=$(echo "$NAME_JSON" | sed 's/^"//;s/"$//;s/null//')
    TYPE=$(echo "$TYPE_JSON" | sed 's/^"//;s/"$//;s/null//')
    PARENT_INTERFACE=$(echo "$PARENT_INTERFACE_JSON" | sed 's/^"//;s/"$//;s/null//')
    SUBNET=$(echo "$SUBNET_JSON" | sed 's/^"//;s/"$//;s/null//')
    GATEWAY=$(echo "$GATEWAY_JSON" | sed 's/^"//;s/"$//;s/null//')
    IP_RANGE=$(echo "$IP_RANGE_JSON" | sed 's/^"//;s/"$//;s/null//')
    HOST_INTERFACE=$(echo "$HOST_INTERFACE_JSON" | sed 's/^"//;s/"$//;s/null//')
    MODE=$(echo "$MODE_JSON" | sed 's/^"//;s/"$//;s/null//')
    ALLOWED_NETWORKS_CSV=$(echo "$ALLOWED_NETWORKS_JSON" | sed 's/^"//;s/"$//;s/null//')

    NAME=$(echo "$NAME" | xargs)
    TYPE=$(echo "$TYPE" | xargs)
    PARENT_INTERFACE=$(echo "$PARENT_INTERFACE" | xargs)
    SUBNET=$(echo "$SUBNET" | xargs)
    GATEWAY=$(echo "$GATEWAY" | xargs)
    IP_RANGE=$(echo "$IP_RANGE" | xargs)
    HOST_INTERFACE=$(echo "$HOST_INTERFACE" | xargs)
    MODE=$(echo "$MODE" | xargs)
    ALLOWED_NETWORKS_CSV=$(echo "$ALLOWED_NETWORKS_CSV" | xargs)

    if [ -z "$NAME" ] || [ -z "$TYPE" ]; then
      if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Skipping incomplete YAML entry: Name or Type missing."; fi
      continue
    fi

    if docker network inspect "$NAME" >/dev/null 2>&1; then
      echo "  Network '${NAME}' exists. Adding to list for iptables processing."
      NETWORK_DEFINITIONS_FOR_IPTABLES+=("${NAME};${TYPE};${PARENT_INTERFACE};${SUBNET};${GATEWAY};${IP_RANGE};${HOST_INTERFACE};${MODE};${ALLOWED_NETWORKS_CSV}")
    else
      echo "  Network '${NAME}' does not exist. Skipping iptables for this network."
    fi
  done < <(yq -r '.networks[] | [(.name | @json), (.type | @json), (.parent_interface | @json), (.subnet | @json), (.gateway | @json), (.ip_range | @json), (.host_interface | @json), (.mode | @json), (.allowed_networks | join(",") | @json)] | join(";")' "$CONFIG_FILE")
fi # End of NETWORK_ONLY_MODE conditional

if [ "$DEBUG_MODE" -eq 1 ]; then
  echo "DEBUG: Contents of NETWORK_DEFINITIONS_FOR_IPTABLES array after Pass 1 (or Network-Only Mode processing):"
  printf '%s\n' "${NETWORK_DEFINITIONS_FOR_IPTABLES[@]}"
  echo ""
fi

# --- Pass 2: Apply iptables Rules for Inter-Network Communication ---
echo "--- Pass 2: Applying iptables Rules for Inter-Network Communication ---"

# First, collect all successfully created network names and their subnets
declare -A NETWORK_SUBNETS # Associative array to store name -> subnet mapping
echo "Collecting subnets of created networks..."
ALL_CREATED_NETWORKS=$(docker network ls --format "{{.Name}}")

for NET_NAME in $ALL_CREATED_NETWORKS; do
  if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Inspecting network '${NET_NAME}' for subnet..."; fi
  NET_SUBNET=$(docker network inspect "$NET_NAME" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null) # Suppress errors for non-existent IPAM configs
  if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Subnet for '${NET_NAME}': '${NET_SUBNET}'"; fi
  if [ -n "$NET_SUBNET" ]; then
    NETWORK_SUBNETS["$NET_NAME"]="$NET_SUBNET"
    echo "  Found subnet for '${NET_NAME}': ${NET_SUBNET}"
  else
    echo "  Warning: Could not determine subnet for '${NET_NAME}'. Skipping iptables for this network."
  fi
done
if [ "$DEBUG_MODE" -eq 1 ]; then
  echo "DEBUG: Contents of NETWORK_SUBNETS associative array:"
  for key in "${!NETWORK_SUBNETS[@]}"; do
    echo "  KEY: '$key', VALUE: '${NETWORK_SUBNETS[$key]}'"
  done
fi
echo ""

# Now, iterate through stored network definitions to apply rules
for NET_DEF in "${NETWORK_DEFINITIONS_FOR_IPTABLES[@]}"; do
  if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Processing network definition string for iptables: '${NET_DEF}'"; fi
  # Explicitly naming variables for clarity in debugging
  IFS=';' read -r SRC_NET_NAME SRC_TYPE SRC_PARENT_INTERFACE SRC_SUBNET_DEF SRC_GATEWAY_DEF SRC_IP_RANGE_DEF SRC_HOST_INTERFACE_DEF SRC_MODE_DEF ALLOWED_NETWORKS_CSV <<< "$NET_DEF"

  if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "DEBUG: Parsed SRC_NET_NAME for iptables: '${SRC_NET_NAME}'"
    echo "DEBUG: Parsed ALLOWED_NETWORKS_CSV for iptables: '${ALLOWED_NETWORKS_CSV}'"
  fi

  if [ -z "$ALLOWED_NETWORKS_CSV" ]; then
    if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: No allowed networks specified for '${SRC_NET_NAME}'. Skipping iptables for this network."; fi
    continue # No allowed networks specified for this source network
  fi

  SRC_SUBNET="${NETWORK_SUBNETS[$SRC_NET_NAME]}"
  if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Looked up source network subnet for iptables: '${SRC_NET_NAME}': '${SRC_SUBNET}'"; fi

  if [ -z "$SRC_SUBNET" ]; then
    echo "Skipping iptables for '${SRC_NET_NAME}': Source subnet not found in the collected network subnets map. This network might not have been created or is not inspectable."
    continue
  fi

  echo "Setting up communication rules for '${SRC_NET_NAME}' (Source Subnet: ${SRC_SUBNET}):"
  IFS=',' read -r -a TARGET_NETS <<< "$ALLOWED_NETWORKS_CSV" # Split CSV into array

  if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Target networks from CSV for iptables: '${TARGET_NETS[@]}'"; fi

  for TGT_NET_NAME in "${TARGET_NETS[@]}"; do
    TGT_NET_NAME=$(echo "$TGT_NET_NAME" | xargs) # Trim whitespace
    if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Current target network for iptables: '${TGT_NET_NAME}'"; fi

    if [ -z "$TGT_NET_NAME" ]; then
      if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Empty target network name found. Skipping."; fi
      continue # Skip empty target network names
    fi

    TGT_SUBNET="${NETWORK_SUBNETS[$TGT_NET_NAME]}"
    if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Looked up target network subnet for iptables: '${TGT_NET_NAME}': '${TGT_SUBNET}'"; fi

    if [ -z "$TGT_SUBNET" ]; then
      echo "  Warning: Target network '${TGT_NET_NAME}' not found or its subnet could not be determined. Skipping rule for this target."
      continue
    fi

    # Add bidirectional iptables rules using the DOCKER-USER chain
    if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Applying rule: Allow from '${SRC_NET_NAME}' (${SRC_SUBNET}) to '${TGT_NET_NAME}' (${TGT_SUBNET}) DOCKER-USER chain in FILTER table"; fi
    sudo iptables -I DOCKER-USER -s "$SRC_SUBNET" -d "$TGT_SUBNET" -j ACCEPT
    RULE_STATUS_1=$?

    if [ "$DEBUG_MODE" -eq 1 ]; then echo "DEBUG: Applying rule: Allow from '${SRC_NET_NAME}' (${SRC_SUBNET}) to '${TGT_NET_NAME}' (${TGT_SUBNET}) PREROUTING chain in RAW table"; fi
    sudo iptables -t raw -I PREROUTING -s "$SRC_SUBNET" -d "$TGT_SUBNET" -j ACCEPT
    RULE_STATUS_2=$?

    if [ $RULE_STATUS_1 -eq 0 ] && [ $RULE_STATUS_2 -eq 0 ]; then
      echo "  Rules applied successfully for ${SRC_NET_NAME} <-> ${TGT_NET_NAME}."
    else
      echo "  Error: Failed to apply one or both iptables rules for ${SRC_NET_NAME} <-> ${TGT_NET_NAME}. Check sudo permissions or iptables status."
    fi
  done
  echo ""
done

echo "--- Docker Network Setup Finished ---"
echo "You can verify created networks with 'docker network ls' and 'docker network inspect <network_name>'."
echo "To view iptables rules, use 'sudo iptables -L DOCKER-USER -n -v'."
echo ""
echo "Attempting to save iptables rules (requires 'netfilter-persistent' or similar)..."
if command -v netfilter-persistent >/dev/null 2>&1; then
  sudo netfilter-persistent save
  if [ $? -eq 0 ]; then
    echo "Iptables rules saved successfully."
  else
    echo "Warning: Failed to save iptables rules using 'netfilter-persistent'. Rules may not persist across reboots."
  fi
else
  echo "Warning: 'netfilter-persistent' command not found. Iptables rules will NOT persist across reboots."
  echo "Please install 'netfilter-persistent' (e.g., 'sudo apt install netfilter-persistent') or configure an alternative persistence method."
fi
