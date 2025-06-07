# Docker Network Setup Utility

A comprehensive bash script for creating and managing Docker networks with automated iptables rules for inter-network communication.

## Features

- Create multiple Docker networks from a single YAML configuration
- Support for bridge, macvlan, and ipvlan network types
- Automated iptables rules for inter-network communication
- Debug mode for troubleshooting
- Network-only mode for applying iptables rules to existing networks
- Persistent iptables rules (with netfilter-persistent)

## Requirements

- Docker installed and running
- Root/sudo privileges
- yq (YAML processor) installed
- netfilter-persistent (optional, for persistent iptables rules)

## Installation

```bash
git clone [your-repo-url]
cd docker-network-setup
chmod +x net-setup.sh
```

## Configuration

Create a YAML configuration file (e.g., `conf.yaml`) with your network definitions:

```yaml
networks:
  - name: web_app_net           # Network name
    type: bridge                # Network type (bridge/macvlan/ipvlan)
    host_interface: "web_br0"   # Custom bridge interface name (bridge only)
    allowed_networks:           # Networks that can communicate with this one
      - database_backend_net    

  - name: prod_macvlan_net
    type: macvlan
    parent_interface: "eth0"    # Required for macvlan/ipvlan
    subnet: "192.168.1.0/24"    # Required for macvlan/ipvlan
    gateway: "192.168.1.1"      # Required for macvlan/ipvlan
    ip_range: "192.168.1.128/25" # Optional IP range
```

### Configuration Options

- `name`: Network name (required)
- `type`: Network type - bridge, macvlan, or ipvlan (required)
- `subnet`: Network subnet CIDR
- `gateway`: Gateway IP address
- `ip_range`: Range for container IP allocation
- `parent_interface`: Physical interface for macvlan/ipvlan
- `host_interface`: Custom bridge interface name (bridge only)
- `mode`: Mode for ipvlan (l2/l3)
- `allowed_networks`: List of networks allowed to communicate

## Usage

### Basic Usage
```bash
sudo ./net-setup.sh conf.yaml
```

### Available Options
```bash
./net-setup.sh [--help] [--debug] [--network] <path_to_yaml_config_file>

Options:
  --help          Display help message
  --debug         Enable debug output
  --network       Only apply iptables rules (skip network creation)
```

### Examples

1. Create networks and apply iptables rules:
```bash
sudo ./net-setup.sh conf.yaml
```

2. Debug mode:
```bash
sudo ./net-setup.sh --debug conf.yaml
```

3. Only apply iptables rules:
```bash
sudo ./net-setup.sh --network conf.yaml
```

## Network Types

### Bridge Network
- Default Docker network type
- Suitable for single-host deployments
- Supports custom interface naming

### Macvlan Network
- Direct access to physical network
- Better performance than bridge
- Requires promiscuous mode
- Parent interface required

### IPvlan Network
- Similar to macvlan but shares MAC address
- Supports L2 and L3 modes
- Parent interface required
- Good for environments where MAC address changes are restricted

## Troubleshooting

1. Check Docker daemon status:
```bash
systemctl status docker
```

2. Verify iptables rules:
```bash
sudo iptables -L DOCKER-USER -n -v
```

3. Check network creation:
```bash
docker network ls
docker network inspect <network_name>
```

4. Enable debug mode for detailed logs:
```bash
sudo ./net-setup.sh --debug conf.yaml
```

## Contributing

Feel free to submit issues, fork the repository, and create pull requests for any improvements.

## License