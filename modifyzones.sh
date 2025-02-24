#!/bin/bash

# Path to the named configuration file
NAMED_CONF="/etc/named.conf"

# Check if named.conf exists
if [[ ! -f $NAMED_CONF ]]; then
    echo "Error: $NAMED_CONF not found."
    exit 1
fi

# Extract zones and their corresponding database files
declare -A ZONES
forward_zones=() # List to store forward zones
current_zone=""
while IFS= read -r line; do
    if [[ $line =~ zone[[:space:]]+\"([^\"]+)\" ]]; then
        current_zone="${BASH_REMATCH[1]}"
    elif [[ -n $current_zone && $line =~ file[[:space:]]+\"([^\"]+)\" ]]; then
        # Exclude the root zone (.)
        if [[ $current_zone != "." ]]; then
            ZONES["$current_zone"]="${BASH_REMATCH[1]}"
            # Populate forward zones list
            if [[ $current_zone != *.in-addr.arpa ]]; then
                forward_zones+=("$current_zone")
            fi
        fi
        current_zone=""
    fi
done < "$NAMED_CONF"

if [[ ${#ZONES[@]} -eq 0 ]]; then
    echo "No zones found in $NAMED_CONF."
    exit 1
fi

# Freeze all zones
echo "Freezing all zones:"
for zone in "${!ZONES[@]}"; do
    echo "Freezing zone: $zone"
    rndc freeze "$zone"
done

# List available zones with an exit option
echo "Available zones (type 'Exit' to quit):"
select zone in "${!ZONES[@]}" "Exit"; do
    if [[ $zone == "Exit" ]]; then
        echo "Exiting script."
        # Thaw all zones before exiting
        echo "Thawing all zones:"
        for z in "${!ZONES[@]}"; do
            echo "Thawing zone: $z"
            rndc thaw "$z"
        done
        exit 0
    elif [[ -n $zone ]]; then
        echo "You selected zone: $zone"
        db_file="${ZONES[$zone]}"
        echo "Database file: $db_file"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Verify the db_file exists before proceeding
if [[ ! -f $db_file ]]; then
    echo "Error: Database file $db_file not found."
    exit 1
fi

# Create a temporary file for the zone file
tmp_file=$(mktemp)
cp "$db_file" "$tmp_file"

# Function to increment the serial number in a zone file
increment_serial() {
    local file="$1"
    awk '/[0-9]+[[:space:]]*;[[:space:]]*serial/ { sub(/[0-9]+/, $1+1, $0) } { print }' "$file" > "$file.tmp" && mv "$file.tmp" "$
file"
}

# Function to check and possibly create a forward zone entry
check_and_create_forward_entry() {
    local ip="$1"
    local hostname="$2"
    local forward_db_file="$3"

    # Check if the hostname exists in the forward zone file
    if ! grep -q "$hostname IN A" "$forward_db_file"; then
        echo "No A record found for $hostname. Do you want to create it? (yes/no)"
        read create_a
        if [[ $create_a == "yes" ]]; then
            echo "$hostname IN A $ip" >> "$forward_db_file"
            increment_serial "$forward_db_file"
            echo "A record added: $hostname IN A $ip"
        fi
    else
        echo "A record for $hostname already exists in the forward zone."
        echo "Do you want to update it with IP $ip? (yes/no)"
        read update_a
        if [[ $update_a == "yes" ]]; then
            sed -i "/$hostname IN A/c\\$hostname IN A $ip" "$forward_db_file"
            increment_serial "$forward_db_file"
            echo "A record updated: $hostname IN A $ip"
        fi
    fi
}

# Function to edit zone file
edit_zone_file() {
    local record_type="$1"

    # Display the current configuration before adding new records
    echo "Current configuration of the zone file:"
    cat "$tmp_file"
    echo "-----------------------------------"

    case $record_type in
        A)
            echo "Enter the name of the A record:"
            read name
            echo "Enter the IP address for the A record:"
            read ip
            echo "$name IN A $ip" >> "$tmp_file"
            increment_serial "$tmp_file"

            echo "Do you want to create a PTR record for $ip? (yes/no)"
            read create_ptr
            if [[ $create_ptr == "yes" ]]; then
                reverse_zone=$(determine_reverse_zone "$ip")
                if [[ -n $reverse_zone ]]; then
                    reverse_db_file="${ZONES[$reverse_zone]}"
                    if [[ -f $reverse_db_file ]]; then
                        reverse_tmp_file=$(mktemp)
                        cp "$reverse_db_file" "$reverse_tmp_file"
                        IFS='.' read -r -a ip_parts <<< "$ip"
                        octet="${ip_parts[3]}"
                        echo "$octet IN PTR $name.$zone." >> "$reverse_tmp_file"
                        increment_serial "$reverse_tmp_file"
                        echo "PTR record added to reverse zone $reverse_zone"
                    else
                        echo "Error: Reverse zone database file $reverse_db_file not found."
                    fi
                else
                    echo "Error: No suitable reverse zone found for IP $ip."
                fi
            fi
            ;;
        CNAME)
            echo "Enter the alias name for the CNAME record:"
            read cname
            echo "Enter the canonical name for the CNAME record:"
            read cname_target
            echo "$cname IN CNAME $cname_target" >> "$tmp_file"
            increment_serial "$tmp_file"
            ;;
        SRV)
            echo "Enter the service name for the SRV record:"
            read service
            echo "Enter the priority, weight, port, and target for the SRV record (space-separated):"
            read priority weight port target
            echo "$service IN SRV $priority $weight $port $target" >> "$tmp_file"
            increment_serial "$tmp_file"
            ;;
        PTR)
            echo "Enter the last octet of the IP address for the PTR record:"
            read octet
            echo "Enter the host name for the PTR record:"
            read hostname

            # List available forward zones for selection
            echo "Select the domain to complete the PTR record:"
            select domain in "${forward_zones[@]}"; do
                if [[ -n $domain ]]; then
                    # Append the selected domain to form the full canonical name
                    canonical_name="$hostname.$domain."
                    echo "$octet IN PTR $canonical_name" >> "$tmp_file"
                    increment_serial "$tmp_file"
                    echo "PTR record added: $octet IN PTR $canonical_name"

                    # Rebuild the full IP address from the reverse zone
                    IFS='.' read -r -a zone_parts <<< "${zone//.in-addr.arpa/}"
                    full_ip="${zone_parts[2]}.${zone_parts[1]}.${zone_parts[0]}.$octet"

                    # Check if the A record exists in the forward zone
                    forward_db_file="${ZONES[$domain]}"
                    if [[ -f $forward_db_file ]]; then
                        check_and_create_forward_entry "$full_ip" "$hostname" "$forward_db_file"
                    else
                        echo "Error: Forward zone database file $forward_db_file not found."
                    fi
                    break
                else
                    echo "Invalid selection. Please try again."
                fi
            done
            ;;
        *)
            echo "Unsupported record type."
            exit 1
            ;;
    esac
}

# Present options to create a new record based on the zone type
if [[ $zone == *.in-addr.arpa ]]; then
    # Options for reverse zones
    echo "Select the type of record to create (type 'Exit' to quit):"
    options=("PTR" "Exit")
else
    # Options for forward zones
    echo "Select the type of record to create (type 'Exit' to quit):"
    options=("A" "CNAME" "SRV" "Exit")
fi

select opt in "${options[@]}"; do
    if [[ $opt == "Exit" ]]; then
        echo "Exiting script."
        # Clean up temporary files and thaw all zones before exiting
        rm -f "$tmp_file"
        if [[ -n $reverse_tmp_file ]]; then
            rm -f "$reverse_tmp_file"
        fi
        echo "Thawing all zones:"
        for z in "${!ZONES[@]}"; do
            echo "Thawing zone: $z"
            rndc thaw "$z"
        done
        exit 0
    elif [[ -n $opt ]]; then
        echo "You selected: $opt"
        edit_zone_file "$opt"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Output the modified file and ask for confirmation
echo "Modified zone file:"
cat "$tmp_file"

echo "Do you accept these changes? (yes/no)"
read confirmation

if [[ $confirmation == "yes" ]]; then
    # Apply changes by moving the temporary file to the original file
    mv "$tmp_file" "$db_file"
    if [[ -n $reverse_tmp_file ]]; then
        mv "$reverse_tmp_file" "$reverse_db_file"
    fi
    echo "Zone $zone updated successfully."
else
    echo "Changes discarded."
    # Remove temporary files
    rm -f "$tmp_file"
    if [[ -n $reverse_tmp_file ]]; then
        rm -f "$reverse_tmp_file"
    fi
fi

# Thaw all zones
echo "Thawing all zones:"
for z in "${!ZONES[@]}"; do
    echo "Thawing zone: $z"
    rndc thaw "$z"
done
