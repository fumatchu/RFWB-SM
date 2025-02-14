#!/bin/bash

# Define color codes for output
RESET="\033[0m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"

# Function to find the network interface based on connection name ending
find_interface() {
    local suffix="$1"
    nmcli -t -f DEVICE,CONNECTION device status | awk -F: -v suffix="$suffix" '$2 ~ suffix {print $1}'
}

# Setup the FW: Determine inside and outside interfaces
echo -e "${YELLOW}Determining network interfaces...${RESET}"
INSIDE_INTERFACE=$(find_interface "-inside")
OUTSIDE_INTERFACE=$(find_interface "-outside")

echo -e "${GREEN}Inside interface: $INSIDE_INTERFACE${RESET}"
echo -e "${GREEN}Outside interface: $OUTSIDE_INTERFACE${RESET}"

if [[ -z "$INSIDE_INTERFACE" || -z "$OUTSIDE_INTERFACE" ]]; then
    echo -e "${RED}Error: Could not determine one or both interfaces. Please check your connection names.${RESET}"
    exit 1
fi

# Ensure nftables tables and chains exist
sudo nft add table ip nat
sudo nft add chain ip nat prerouting { type nat hook prerouting priority 0\; }
sudo nft add chain ip nat postrouting { type nat hook postrouting priority 100\; }
sudo nft add table ip filter
sudo nft add chain ip filter input { type filter hook input priority 0\; }

# Get the IP address for the inside interface
INSIDE_IP=$(nmcli -g IP4.ADDRESS device show "$INSIDE_INTERFACE" | head -n1 | cut -d'/' -f1)

# Ask the user if they want to scan an internal device for open ports
read -p "Do you want to scan an internal device for open ports? (yes/no): " scan_choice

if [[ "$scan_choice" == "yes" ]]; then
    read -p "Enter the IP address of the internal device: " device_ip
    echo -e "${YELLOW}Scanning $device_ip for open ports... Please wait.${RESET}"

    # Run nmap in verbose mode and display output while capturing open ports
    nmap_output=$(mktemp)
    nmap -sS -sU -p- --min-rate=1000 -T4 -v $device_ip | tee $nmap_output

    # Extract open ports from the nmap output
    open_ports=$(awk '/^[0-9]+\/(tcp|udp)/ && /open/ {print $1 "/" $2}' $nmap_output)

    rm $nmap_output

    if [ -z "$open_ports" ]; then
        echo -e "${RED}No open ports found on $device_ip.${RESET}"
        exit 1
    fi

    echo -e "${GREEN}Open ports found:${RESET}"
    echo "$open_ports" | nl

    # Ask the user if they want to forward all ports or select specific ones
    read -p "Do you want to port forward all open ports or select specific ones? (all/select): " forward_choice

    if [[ "$forward_choice" == "all" ]]; then
        echo -e "${YELLOW}Applying port forwarding rules for all open ports...${RESET}"
        for port in $open_ports; do
            port_number=$(echo "$port" | cut -d'/' -f1)
            protocol=$(echo "$port" | cut -d'/' -f2)
            echo "Applying rule for port $port_number/$protocol"
            sudo nft add rule ip nat prerouting iif $OUTSIDE_INTERFACE $protocol dport $port_number counter dnat to $device_ip:$port_number
            sudo nft add rule ip filter input iif $OUTSIDE_INTERFACE $protocol dport $port_number accept
        done
    elif [[ "$forward_choice" == "select" ]]; then
        selected_ports=()
        echo "Enter the number of the port you want to forward (e.g., 1,2,3), separated by spaces:"
        read -a port_numbers
        echo -e "${YELLOW}Applying port forwarding rules for selected ports...${RESET}"
        for number in "${port_numbers[@]}"; do
            port=$(echo "$open_ports" | sed -n "${number}p")
            selected_ports+=("$port")
        done

        for port in "${selected_ports[@]}"; do
            port_number=$(echo "$port" | cut -d'/' -f1)
            protocol=$(echo "$port" | cut -d'/' -f2)
            echo "Applying rule for port $port_number/$protocol"
            sudo nft add rule ip nat prerouting iif $OUTSIDE_INTERFACE $protocol dport $port_number counter dnat to $device_ip:$port_number
            sudo nft add rule ip filter input iif $OUTSIDE_INTERFACE $protocol dport $port_number accept
        done
    fi

else
    # If user selects no to scanning, ask for manual input
    read -p "Enter the IP address for port forwarding: " manual_ip
    read -p "Enter the port number to forward: " manual_port
    read -p "Enter the protocol (tcp/udp): " manual_protocol

    echo -e "${YELLOW}Applying manual port forwarding rule...${RESET}"
    sudo nft add rule ip nat prerouting iif $OUTSIDE_INTERFACE $manual_protocol dport $manual_port counter dnat to $manual_ip:$manual_port
    sudo nft add rule ip filter input iif $OUTSIDE_INTERFACE $manual_protocol dport $manual_port accept
fi

# Save the nftables configuration
echo -e "${YELLOW}Saving nftables configuration...${RESET}"
sudo nft list ruleset > /etc/sysconfig/nftables.conf
echo -e "${GREEN}Configuration saved successfully to /etc/sysconfig/nftables.conf!${RESET}"
