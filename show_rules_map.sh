#!/bin/bash

# Check if nftables is installed
if ! command -v nft &> /dev/null; then
    echo "nftables is not installed. Please install it and try again."
    exit 1
fi

# Fetch nftables configuration
nft_config=$(nft list ruleset 2>/dev/null)

# Check if configuration was fetched successfully
if [ -z "$nft_config" ]; then
    echo "Failed to retrieve nftables configuration or no ruleset is present."
    exit 1
fi

# Function to format the nftables configuration into a detailed ASCII map
format_nftables() {
    local config="$1"
    local output=""
    local current_table=""
    local current_chain=""

    while read -r line; do
        # Detect table
        if [[ $line =~ ^table ]]; then
            current_table=$(echo "$line" | awk '{print $3}')
            output+="\n+------------------------------+\n"
            output+="| Table: $current_table |\n"
            output+="+------------------------------+\n"
        fi

        # Detect chain
        if [[ $line =~ ^\s*chain ]]; then
            current_chain=$(echo "$line" | awk '{print $2}')
            output+="\n  +-------> Chain: $current_chain\n"
            output+="  |---------------------------+\n"
        fi

        # Detect rules with interfaces, ports, and connection state
        if [[ $line =~ iifname || $line =~ oifname || $line =~ dport || $line =~ sport || $line =~ ct ]]; then
            interface_in=$(echo "$line" | grep -oP 'iifname\s+\K\S+')
            interface_out=$(echo "$line" | grep -oP 'oifname\s+\K\S+')
            dport=$(echo "$line" | grep -oP 'dport\s+\K\S+')
            sport=$(echo "$line" | grep -oP 'sport\s+\K\S+')
            conn_state=$(echo "$line" | grep -oP 'ct state\s+\K\S+')
            rule_details="In: ${interface_in:-any}, Out: ${interface_out:-any}, DPort: ${dport:-any}, SPort: ${sport:-any}, State: ${conn_state:-none}"
            output+="  | Rule: $rule_details\n"
        fi
    done <<< "$config"

    echo -e "$output"
}

# Generate the ASCII map
ascii_map=$(format_nftables "$nft_config")

# Display the ASCII map
echo -e "nftables Configuration Map:\n"
echo -e "$ascii_map"
