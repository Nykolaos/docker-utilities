Docker Network Setup Script
This script automates the creation of various Docker network types (bridge, macvlan, ipvlan) and manages inter-network communication rules using iptables based on a YAML configuration file. It's designed for convenience in setting up complex Docker networking environments.

Table of Contents
Features

Prerequisites

Installation

Usage

Script Options

Examples

Configuration File (networks.yaml)

Network Object Properties

Important Notes for Configuration

Contributing

License

Features
Multi-Network Creation: Define and create multiple Docker networks (bridge, macvlan, ipvlan) from a single YAML file.

Flexible Configuration: All network parameters (subnet, gateway, IP range, host interface name, IPvlan mode) are optional except for the network's name and type.

Dynamic Type Inference: The script infers the network type (macvlan/ipvlan vs. bridge) based on the presence of the parent_interface in the configuration.

Inter-Network Communication: Automatically sets up bidirectional iptables rules to allow communication between specified Docker networks.

Conditional Debugging: Run the script with --debug to see detailed execution logs.

Network-Only Mode: Use the --network option to skip network creation and only apply iptables rules for pre-existing Docker networks defined in your configuration.

Help Option: Comprehensive usage instructions available via --help.

Prerequisites
Before running this script, ensure you have the following installed and configured on your Linux system:

Docker: The Docker daemon must be installed and running.

Install Docker Engine

yq (YAML Processor): This command-line tool is required to parse the YAML configuration file.

Installation (Recommended):

# Using snap (Ubuntu/Debian)
sudo snap install yq

# Using Homebrew (macOS/Linux)
brew install yq

# Manual download (Linux)
# Check for the latest version at https://github.com/mikefarah/yq/releases
YQ_VERSION="v4.44.2" # Replace with latest if needed
YQ_BINARY="yq_linux_amd64" # Adjust for your architecture if needed
sudo wget https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY} -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

sudo Privileges: The script executes Docker and iptables commands which require root privileges. You will need to run the script using sudo.

netfilter-persistent (Optional but Recommended for persistence): iptables rules are not persistent across reboots by default. To save and restore your rules after a system reboot, it's highly recommended to install netfilter-persistent (or an equivalent persistence mechanism for your distribution, e.g., firewalld on CentOS/RHEL).

Installation (Debian/Ubuntu):

sudo apt update
sudo apt install netfilter-persistent

Installation
Save the script content (provided in the code block below) as create_docker_networks.sh.

Make the script executable:

chmod +x create_docker_networks.sh

Create your network configuration file (e.g., networks.yaml) following the structure described in the Configuration File section.

Usage
Run the script from your terminal. Always ensure you are in the directory where create_docker_networks.sh is located, or provide the full path to it.

sudo ./create_docker_networks.sh [--help] [--debug] [--network] <path_to_yaml_config_file>

Script Options

--help: Display a comprehensive usage message (this help text) and then exit.

--debug: Enable verbose debug output. This will print detailed steps and variable values during execution, useful for troubleshooting.

--network: Activates "network-only" mode. In this mode, the script skips the creation of Docker networks. It will only process networks defined in your YAML that already exist on your Docker host and apply (or re-apply) the specified iptables communication rules for them.

Examples

Create networks and apply iptables rules (normal operation):

sudo ./create_docker_networks.sh networks.yaml

Same as above, but with debug output:

sudo ./create_docker_networks.sh --debug networks.yaml

Only apply iptables rules for existing networks (e.g., after a reboot):

sudo ./create_docker_networks.sh --network networks.yaml

Same as above, but with debug output:

sudo ./create_docker_networks.sh --debug --network networks.yaml

Display usage instructions:

./create_docker_networks.sh --help

Configuration File (networks.yaml)
The script reads its network definitions from a YAML file. The file should contain a top-level key networks which holds a list of network objects.

Network Object Properties

Each network object in the networks list can have the following properties:

name: (string, required)

A unique name for your Docker network.

type: (string, required)

The Docker network driver type. Must be one of: bridge, macvlan, or ipvlan.

parent_interface: (string, optional)

Required for macvlan and ipvlan types.

This is the name of your host's physical network interface (e.g., eth0, enp0s3, wlan0).

Leave empty or omit for bridge networks.

subnet: (string, optional)

The CIDR notation for the network subnet (e.g., "192.168.1.0/24").

Required for macvlan and ipvlan networks.

Optional for bridge networks (Docker assigns a default if not provided).

gateway: (string, optional)

The gateway IP address for the network (e.g., "192.168.1.1").

Required for macvlan and ipvlan networks.

Optional for bridge networks.

ip_range: (string, optional)

An optional IP range within the specified subnet for container IPs (e.g., "192.168.1.200/29"). If omitted, containers will get IPs from the full subnet range.

host_interface: (string, optional)

For bridge networks only.

This specifies the exact name of the bridge interface that Docker will create on the host (e.g., "docker0", "my_custom_br").

If omitted, Docker uses a default name like br-xxxxxxxxxxxx.

This parameter is ignored for macvlan and ipvlan networks.

mode: (string, optional)

For ipvlan networks only.

Specifies the IPvlan mode. Can be "l2", "l3", or "l3s".

Defaults to "l2" if omitted for ipvlan. Ignored for other network types.

allowed_networks: (list of strings, optional)

A list of names of other Docker networks that this network should be allowed to communicate with.

The script will set up bidirectional iptables rules. You do not need to explicitly list network_A in network_B's allowed_networks if network_B is already listed in network_A's.

Ensure the networks listed here are also defined in the same YAML file.

Example networks.yaml

# Docker Network Configuration File

networks:
  - name: web_app_net
    type: bridge
    host_interface: "web_br0" # Custom name for the host bridge interface
    allowed_networks:
      - database_backend_net

  - name: database_backend_net
    type: bridge
    subnet: "172.25.0.0/24"
    gateway: "172.25.0.1"
    host_interface: "db_br0"
    allowed_networks:
      - web_app_net
      - monitoring_net

  - name: monitoring_net
    type: bridge
    subnet: "172.26.0.0/24"
    gateway: "172.26.0.1"
    # ip_range, host_interface are omitted (optional)
    allowed_networks: [] # No specific outbound communication defined

  # IMPORTANT: Replace 'eth0' below with YOUR HOST'S ACTUAL NETWORK INTERFACE.
  #            You can find interface names using 'ip a' or 'ifconfig'.
  #            Adjust subnet/gateway to match your physical network configuration.

  - name: prod_macvlan_net
    type: macvlan
    parent_interface: "eth0" # Required for macvlan/ipvlan
    subnet: "192.168.1.0/24" # Required for macvlan/ipvlan
    gateway: "192.168.1.1" # Required for macvlan/ipvlan
    # ip_range is omitted
    # host_interface is ignored for macvlan
    allowed_networks:
      - dev_macvlan_net

  - name: dev_macvlan_net
    type: macvlan
    parent_interface: "eth0"
    subnet: "192.168.2.0/24"
    gateway: "192.168.2.1"
    ip_range: "192.168.2.200/29" # Specific IP range
    # host_interface is ignored for macvlan
    allowed_networks:
      - prod_macvlan_net

  # Example IPvlan Networks
  - name: app_ipvlan_l2_net
    type: ipvlan
    parent_interface: "eth0"
    subnet: "192.168.3.0/24"
    gateway: "192.168.3.1"
    mode: "l2" # Optional, defaults to l2
    allowed_networks: []

  - name: dmz_ipvlan_l3_net
    type: ipvlan
    parent_interface: "eth0"
    subnet: "10.0.0.0/24"
    gateway: "10.0.0.1"
    mode: "l3" # IPvlan L3 mode
    allowed_networks: []

Contributing
Feel free to open issues or submit pull requests to improve this script.

License
This project is open-source and available under the MIT License.

