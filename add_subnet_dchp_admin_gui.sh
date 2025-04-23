#Latest Version in DiALOG. NEED TO TEST ALL FUNCTIONS FOr FLOW.. ADJUST MSG BOXES, ETC
#####
#####
#####
#####
#####
#!/usr/bin/env bash
set -euo pipefail

INPUT_CONFIG="/etc/kea/kea-dhcp4.conf"
TMP_CONFIG="/tmp/kea-dhcp4.conf.tmp"
NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named/"

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
TEXTRESET="\e[0m"

# Validate CIDR
validate_cidr() {
    local cidr=${1-}  # Use default value to prevent unbound variable error
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    local n="(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
    [[ $ip =~ ^$n(\.$n){3}$ ]] && [[ $prefix -ge 0 && $prefix -le 32 ]]
}

# Validate IP
validate_ip() {
    local ip=${1-}  # Use default value to prevent unbound variable error
    local n="(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
    [[ $ip =~ ^$n(\.$n){3}$ ]]
}

# Extract domain name
get_domain() {
    hostnamectl | awk -F. '/Static hostname/ {print $2"."$3}'
}

# Reverse IP for zone
reverse_ip() {
    local ip="$1"
    echo "$ip" | awk -F '.' '{print $3"."$2"."$1}'
}

# Function to display a dialog menu
select_interface() {
    local interfaces=("$@")
    local options=()
    for i in "${!interfaces[@]}"; do
        options+=("$i" "${interfaces[$i]}")
    done
    local choice
    choice=$(dialog --clear --backtitle "Interface Selection" --title "Available Interfaces" \
        --menu "Select an interface:" 15 40 4 "${options[@]}" 3>&1 1>&2 2>&3)
    echo "${interfaces[$choice]}"
}

# Function to display a dialog input box with default value handling
input_box() {
    local backtitle="${1-}"
    local title="${2-}"
    local message="${3-}"
    local default_value="${4-}"

    local result
    result=$(dialog --clear --backtitle "$backtitle" --title "$title" --inputbox "$message" 8 40 "$default_value" 3>&1 1>&2 2>&3)
    echo "$result"
}

# Function to display a dialog yes/no box
yesno_box() {
    local backtitle="${1-}"
    local title="${2-}"
    local message="${3-}"

    dialog --clear --backtitle "$backtitle" --title "$title" --yesno "$message" 8 40
    return $?
}

# Function to display a dialog message box
msg_box() {
    local backtitle="${1-}"
    local title="${2-}"
    local message="${3-}"

    dialog --clear --backtitle "$backtitle" --title "$title" --msgbox "$message" 10 50
}

# Function to display examples in a message box
show_examples() {
    local examples="Standard: tftp-server-name = 192.168.50.10\n\
Advanced: code=150 name=tftp-server-name space=dhcp4 data=192.168.50.10\n\
More examples: bootfile-name, time-servers, log-servers, domain-name"

    msg_box "Examples" "DHCP Option Examples" "$examples"
}

while true; do
  USED_INTERFACES=$(jq -r '.Dhcp4.subnet4[].interface' "$INPUT_CONFIG")
  BASE_IFACE=$(nmcli -t -f DEVICE,CONNECTION device status | awk -F: '$2 ~ /-inside$/ {print $1}')
  ALL_IFACES=$(nmcli -t -f DEVICE,CONNECTION device status | awk -F: -v base="$BASE_IFACE" '$1 == base || $1 ~ base"\\.[0-9]+" {print $1}')

  AVAILABLE_INTERFACES=()
  for iface in $ALL_IFACES; do
    if ! grep -q "\"$iface\"" <<< "$USED_INTERFACES"; then
      AVAILABLE_INTERFACES+=("$iface")
    fi
  done

  if [[ ${#AVAILABLE_INTERFACES[@]} -eq 0 ]]; then
    msg_box "Error" "No available interfaces found for assignment." "No available interfaces found for assignment."
    exit 1
  fi

  SELECTED_IFACE=$(select_interface "${AVAILABLE_INTERFACES[@]}")
  dns_server_ip=$(nmcli -g IP4.ADDRESS device show "$SELECTED_IFACE" | awk -F/ '{print $1}')
  if [ -z "$dns_server_ip" ]; then
    msg_box "Error" "No IP found for interface $SELECTED_IFACE" "No IP found for interface $SELECTED_IFACE"
    exit 1
  fi

  domain=$(get_domain)
  MAX_ID=$(jq '.Dhcp4.subnet4[].id' "$INPUT_CONFIG" | sort -n | tail -n1)
  NEW_ID=$((MAX_ID + 1))

  description=$(input_box "Subnet Configuration" "Description" "Enter a friendly description for this subnet:")

  while true; do
      CIDR=$(input_box "Subnet Configuration" "CIDR" "Enter subnet in CIDR format (e.g., 192.168.50.0/24):")
      if validate_cidr "$CIDR"; then break; else msg_box "Error" "Invalid CIDR. Try again." "Invalid CIDR. Try again."; fi
  done

  DEFAULT_START="$(echo "$CIDR" | awk -F. '{print $1"."$2"."$3".10"}')"
  DEFAULT_END="$(echo "$CIDR" | awk -F. '{print $1"."$2"."$3".100"}')"

  while true; do
      pool_start=$(input_box "Subnet Configuration" "Start IP" "Enter start IP for pool [$DEFAULT_START]:" "$DEFAULT_START")
      if validate_ip "$pool_start"; then break; else msg_box "Error" "Invalid IP. Try again." "Invalid IP. Try again."; fi
  done

  while true; do
      pool_end=$(input_box "Subnet Configuration" "End IP" "Enter end IP for pool [$DEFAULT_END]:" "$DEFAULT_END")
      if validate_ip "$pool_end"; then break; else msg_box "Error" "Invalid IP. Try again." "Invalid IP. Try again."; fi
  done

  while true; do
      router_address=$(input_box "Subnet Configuration" "Router IP" "Enter router address [default: $dns_server_ip]:" "$dns_server_ip")
      if validate_ip "$router_address"; then break; else msg_box "Error" "Invalid IP. Try again." "Invalid IP. Try again."; fi
  done

  EXTRA_OPTIONS=()
  if yesno_box "DHCP Options" "Custom Options" "Would you like to add custom DHCP options?"; then
    while true; do
      opt_type=$(dialog --clear --backtitle "DHCP Options" --title "Option Type" --menu "Choose option type:" 10 40 3 \
        1 "Standard option (name + value)" \
        2 "Advanced option (code + name + value)" \
        3 "Show examples" 3>&1 1>&2 2>&3)

      case "$opt_type" in
        1)
          opt_name=$(input_box "DHCP Options" "Option Name" "Enter option name:")
          opt_value=$(input_box "DHCP Options" "Option Value" "Enter value for $opt_name:")
          EXTRA_OPTIONS+=("{\"name\": \"$opt_name\", \"data\": \"$opt_value\"}")
          ;;
        2)
          opt_code=$(input_box "DHCP Options" "Option Code" "Enter option code (e.g. 150):")
          opt_name=$(input_box "DHCP Options" "Option Name" "Enter option name (e.g. tftp-server-name):")
          opt_value=$(input_box "DHCP Options" "Option Value" "Enter value for $opt_name:")
          opt_space=$(input_box "DHCP Options" "Option Space" "Enter space (default: dhcp4):" "dhcp4")
          EXTRA_OPTIONS+=("{\"code\": $opt_code, \"name\": \"$opt_name\", \"space\": \"$opt_space\", \"data\": \"$opt_value\"}")
          ;;
        3)
          show_examples
          ;;
        *)
          msg_box "Error" "Invalid choice. Try again." "Please enter a valid option from the menu."
          continue
          ;;
      esac

      if ! yesno_box "DHCP Options" "Add Another" "Add another option?"; then
        break
      fi
    done
  fi

  EXTRA_JSON=$(IFS=,; echo "${EXTRA_OPTIONS[*]}")

  dialog --clear --backtitle "Review Settings" --title "Configuration Review" --msgbox \
    "Friendly Name: $description\nNetwork Scheme: $CIDR\nInterface: $SELECTED_IFACE\nIP Pool Range: $pool_start - $pool_end\nRouter Address: $router_address\
nNTP Server: $dns_server_ip\nDNS Server: $dns_server_ip\nClient suffix: $domain\nClient Search Domain: $domain\n\nCustom DHCP Options:\n$(IFS=$'\n'; echo "${
EXTRA_OPTIONS[*]}" | jq -r '. | "- " + (if .code then "[code=" + (.code|tostring) + "] " else "" end) + .name + " = " + .data')" 15 40

  if yesno_box "Confirmation" "Review" "Is this configuration correct?"; then
      pool_range="$pool_start - $pool_end"
      NEW_SUBNET=$(jq -n \
        --arg cidr "$CIDR" \
        --arg iface "$SELECTED_IFACE" \
        --arg pool_range "$pool_range" \
        --arg desc "$description" \
        --arg router "$router_address" \
        --arg dns "$dns_server_ip" \
        --arg dom "$domain" \
        --argjson id "$NEW_ID" \
        --argjson extras "[${EXTRA_JSON:-}]" '
{
  comment: $desc,
  id: $id,
  subnet: $cidr,
  interface: $iface,
  pools: [ { pool: $pool_range } ],
  "option-data": (
    [
      { name: "routers", data: $router },
      { name: "domain-name-servers", data: $dns },
      { name: "ntp-servers", data: $dns },
      { name: "domain-search", data: $dom },
      { name: "domain-name", data: $dom }
    ] + $extras
  )}')

      jq --argjson new_subnet "$NEW_SUBNET" '.Dhcp4.subnet4 += [$new_subnet]' "$INPUT_CONFIG" > "$TMP_CONFIG"

      if jq . "$TMP_CONFIG" > "$INPUT_CONFIG"; then
          msg_box "Success" "Subnet added successfully." "Subnet added successfully.\nRestarting KEA DHCP service..."
          if systemctl restart kea-dhcp4; then
              msg_box "Success" "KEA DHCP restarted." "KEA DHCP restarted."
          else
              msg_box "Error" "Failed to restart KEA DHCP." "Failed to restart KEA DHCP."
          fi
      else
          msg_box "Failure" "Failed to validate updated config." "Failed to validate updated config. Reverting."
          exit 1
      fi

      ip_portion="$(echo "$CIDR" | cut -d'/' -f1)"
      reversed_ip="$(reverse_ip "$ip_portion")"
      reverse_zone="${reversed_ip}.in-addr.arpa"
      reverse_zone_file="${ZONE_DIR}db.${reversed_ip}"
      full_hostname=$(hostnamectl status | awk '/Static hostname:/ {print $3}')
      hostname="${full_hostname%%.*}"
      domain="${full_hostname#*.}"

      msg_box "Info" "Checking for reverse zone: ${reverse_zone}" "Checking for reverse zone: ${reverse_zone}"

      if ! grep -q "zone \"$reverse_zone\"" "$NAMED_CONF"; then
          msg_box "Info" "Reverse zone not found. Creating..." "Reverse zone not found. Creating..."

          cat >> "$NAMED_CONF" <<EOF

zone "$reverse_zone" {
    type master;
    file "$reverse_zone_file";
    allow-update { key "Kea-DDNS"; };
};
EOF

          cat > "$reverse_zone_file" <<EOF
\$TTL 86400
@   IN  SOA   $full_hostname. admin.$domain. (
    2023100501 ; serial
    3600       ; refresh
    1800       ; retry
    604800     ; expire
    86400      ; minimum
)
@   IN  NS    $full_hostname.
${dns_server_ip##*.}  IN  PTR   $full_hostname.
EOF

          chmod 640 "$reverse_zone_file"
          chown named:named "$reverse_zone_file"
      else
          msg_box "Success" "Reverse zone already exists." "Reverse zone already exists."
      fi

      if systemctl restart named; then
          msg_box "Success" "Named restarted." "Named restarted."
      else
          msg_box "Error" "Failed to restart named." "Failed to restart named."
      fi

      break
  else
      msg_box "Info" "Let's try that again..." "Let's try that again..."
  fi

done
