
#!/bin/bash

# Define color codes for pretty output
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
TEXTRESET="\033[0m"

# Function to locate the server's private IP address using nmcli
find_private_ip() {
    # Find the interface ending with -inside
    interface=$(nmcli device status | awk '/-inside/ {print $1}')

    if [ -z "$interface" ]; then
        echo -e "${RED}Error: No interface ending with '-inside' found.${TEXTRESET}"
        exit 1
    fi

    echo -e "${GREEN}Inside interface found: $interface${TEXTRESET}"
}

# Function to set up nftables rule for SSH on the inside interface
setup_nftables() {
    # Ensure the nftables service is enabled and started
    sudo systemctl enable nftables
    sudo systemctl start nftables

    # Create a filter table if it doesn't exist
    if ! sudo nft list tables | grep -q 'inet filter'; then
        sudo nft add table inet filter
    fi

    # Create an input chain if it doesn't exist
    if ! sudo nft list chain inet filter input &>/dev/null; then
        sudo nft add chain inet filter input { type filter hook input priority 0 \; }
    fi

    # Add a rule to allow SSH on the inside interface, if not already present
    if ! sudo nft list chain inet filter input | grep -q "iifname \"$interface\" tcp dport 22 accept"; then
        sudo nft add rule inet filter input iifname "$interface" tcp dport 22 accept
        echo -e "${GREEN}Rule added: Allow SSH on interface $interface${TEXTRESET}"
        save_nftables_config
    else
        echo -e "${YELLOW}Rule already exists: Allow SSH on interface $interface${TEXTRESET}"
    fi

    # Show the added rule in the input chain
    echo -e "${YELLOW}Current rules in the input chain:${TEXTRESET}"
    sudo nft list chain inet filter input
}

# Function to save the current nftables configuration
save_nftables_config() {
    sudo nft list ruleset > /etc/nftables.conf
    echo -e "${GREEN}Configuration saved to /etc/nftables.conf${TEXTRESET}"
}

# Function to prompt for additional ports
add_additional_ports() {
    while true; do
        read -p "Do you want to open additional ports? (yes/no): " answer
        if [[ "$answer" != "yes" ]]; then
            break
        fi

        read -p "Enter the port numbers (e.g., 80,82 or 80-89): " port_input
        read -p "Will all ports use the same protocol? (yes/no): " same_protocol

        if [[ "$same_protocol" == "yes" ]]; then
            protocol=""
            while [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; do
                read -p "Enter the protocol (tcp/udp): " protocol
                if [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; then
                    echo -e "${RED}Invalid protocol. Please enter 'tcp' or 'udp'.${TEXTRESET}"
                fi
            done
        fi

        # Process each port or range of ports
        IFS=',' read -ra PORTS <<< "$port_input"
        for port in "${PORTS[@]}"; do
            if [[ $port == *"-"* ]]; then
                # Handle range of ports
                IFS='-' read start_port end_port <<< "$port"
                for (( p=start_port; p<=end_port; p++ )); do
                    if [[ $p -ge 0 && $p -le 65535 ]]; then
                        if [[ "$same_protocol" == "no" ]]; then
                            protocol=""
                            while [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; do
                                read -p "Enter the protocol for port $p (tcp/udp): " protocol
                                if [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; then
                                    echo -e "${RED}Invalid protocol. Please enter 'tcp' or 'udp'.${TEXTRESET}"
                                fi
                            done
                        fi
                        add_nft_rule "$protocol" "$p"
                    else
                        echo -e "${RED}Invalid port number $p. Please enter a port between 0 and 65535.${TEXTRESET}"
                    fi
                done
            else
                # Handle single port
                if [[ $port -ge 0 && $port -le 65535 ]]; then
                    if [[ "$same_protocol" == "no" ]]; then
                        protocol=""
                        while [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; do
                            read -p "Enter the protocol for port $port (tcp/udp): " protocol
                            if [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; then
                                echo -e "${RED}Invalid protocol. Please enter 'tcp' or 'udp'.${TEXTRESET}"
                            fi
                        done
                    fi
                    add_nft_rule "$protocol" "$port"
                else
                    echo -e "${RED}Invalid port number $port. Please enter a port between 0 and 65535.${TEXTRESET}"
                fi
            fi
        done

        echo -e "${YELLOW}Updated rules in the input chain:${TEXTRESET}"
        sudo nft list chain inet filter input
    done
}

# Function to add a rule to nftables
add_nft_rule() {
    local protocol=$1
    local port=$2

    if ! sudo nft list chain inet filter input | grep -q "iifname \"$interface\" $protocol dport $port accept"; then
        sudo nft add rule inet filter input iifname "$interface" $protocol dport $port accept
        echo -e "${GREEN}Rule added: Allow $protocol on port $port for interface $interface${TEXTRESET}"
        save_nftables_config
    else
        echo -e "${YELLOW}Rule already exists: Allow $protocol on port $port for interface $interface${TEXTRESET}"
    fi
}

# Main script execution
find_private_ip
setup_nftables
add_additional_ports
