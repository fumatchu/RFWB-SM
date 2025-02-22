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
current_zone=""
while IFS= read -r line; do
    if [[ $line =~ zone[[:space:]]+\"([^\"]+)\" ]]; then
        current_zone="${BASH_REMATCH[1]}"
    elif [[ -n $current_zone && $line =~ file[[:space:]]+\"([^\"]+)\" ]]; then
        ZONES["$current_zone"]="${BASH_REMATCH[1]}"
        current_zone=""
    fi
done < "$NAMED_CONF"

if [[ ${#ZONES[@]} -eq 0 ]]; then
    echo "No zones found in $NAMED_CONF."
    exit 1
fi

# List available zones
echo "Available zones:"
select zone in "${!ZONES[@]}"; do
    if [[ -n $zone ]]; then
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

# Function to increment the serial number in a zone file
increment_serial() {
    local file="$1"
    awk '/[0-9]+[[:space:]]*;[[:space:]]*serial/ { sub(/[0-9]+/, $1+1, $0) } { print }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Function to determine the reverse zone for an IP address
determine_reverse_zone() {
    local ip="$1"
    IFS='.' read -r -a ip_parts <<< "$ip"

    for reverse_zone in "${!ZONES[@]}"; do
        # Reverse the IP address to match the in-addr.arpa structure
        reverse_prefix="${ip_parts[2]}.${ip_parts[1]}.${ip_parts[0]}"
        # Check if the reverse zone matches
        if [[ $reverse_zone == *"${reverse_prefix}.in-addr.arpa" ]]; then
            echo "$reverse_zone"
            return
        fi
    done

    echo ""
}

# Function to edit zone file
edit_zone_file() {
    local record_type="$1"
    case $record_type in
        A)
            echo "Enter the name of the A record:"
            read name
            echo "Enter the IP address for the A record:"
            read ip
            echo "$name IN A $ip" >> "$db_file"

            # Increment the serial number of the forward zone
            increment_serial "$db_file"

            # Ask if user wants to create a PTR record
            echo "Do you want to create a PTR record for $ip? (yes/no)"
            read create_ptr
            if [[ $create_ptr == "yes" ]]; then
                # Determine the reverse zone
                reverse_zone=$(determine_reverse_zone "$ip")
                if [[ -n $reverse_zone ]]; then
                    reverse_db_file="${ZONES[$reverse_zone]}"
                    if [[ -f $reverse_db_file ]]; then
                        IFS='.' read -r -a ip_parts <<< "$ip"
                        octet="${ip_parts[3]}"
                        echo "$octet IN PTR $name.$zone." >> "$reverse_db_file"
                        increment_serial "$reverse_db_file"
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
            echo "$cname IN CNAME $cname_target" >> "$db_file"
            increment_serial "$db_file"
            ;;
        SRV)
            echo "Enter the service name for the SRV record:"
            read service
            echo "Enter the priority, weight, port, and target for the SRV record (space-separated):"
            read priority weight port target
            echo "$service IN SRV $priority $weight $port $target" >> "$db_file"
            increment_serial "$db_file"
            ;;
        PTR)
            echo "Enter the last octet of the IP address for the PTR record:"
            read octet
            echo "Enter the canonical name for the PTR record:"
            read ptr_target
            echo "$octet IN PTR $ptr_target" >> "$db_file"
            increment_serial "$db_file"
            ;;
        *)
            echo "Unsupported record type."
            exit 1
            ;;
    esac
}

# Freeze the zone before making changes
echo "Freezing zone $zone..."
rndc freeze "$zone"

# Present options to create a new record
echo "Select the type of record to create:"
options=("A" "CNAME" "SRV" "PTR")
select opt in "${options[@]}"; do
    if [[ -n $opt ]]; then
        echo "You selected: $opt"
        edit_zone_file "$opt"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Output the modified file and ask for confirmation
echo "Modified zone file:"
cat "$db_file"

echo "Do you accept these changes? (yes/no)"
read confirmation

if [[ $confirmation == "yes" ]]; then
    # Thaw the zone after changes
    echo "Thawing zone $zone..."
    rndc thaw "$zone"

    echo "Zone $zone updated successfully."
else
    echo "Changes discarded."
    # Thaw the zone if no changes are made
    rndc thaw "$zone"
fi
