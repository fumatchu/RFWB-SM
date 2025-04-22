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
    local cidr=$1
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    local n="(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
    [[ $ip =~ ^$n(\.$n){3}$ ]] && [[ $prefix -ge 0 && $prefix -le 32 ]]
}

# Validate IP
validate_ip() {
    local ip=$1
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
    echo -e "[${RED}ERROR${TEXTRESET}] No available interfaces found for assignment."
    exit 1
  fi

  echo -e "Available interfaces:"
  select SELECTED_IFACE in "${AVAILABLE_INTERFACES[@]}"; do
    [[ -n "$SELECTED_IFACE" ]] && break
    echo "Invalid choice. Try again."
  done

  dns_server_ip=$(nmcli -g IP4.ADDRESS device show "$SELECTED_IFACE" | awk -F/ '{print $1}')
  if [ -z "$dns_server_ip" ]; then
      echo -e "[${RED}ERROR${TEXTRESET}] No IP found for interface ${GREEN}$SELECTED_IFACE${TEXTRESET}"
      exit 1
  fi

  domain=$(get_domain)
  MAX_ID=$(jq '.Dhcp4.subnet4[].id' "$INPUT_CONFIG" | sort -n | tail -n1)
  NEW_ID=$((MAX_ID + 1))

  echo -n "Enter a friendly description for this subnet: "
  read description

  while true; do
      echo -n "Enter subnet in CIDR format (e.g., 192.168.50.0/24): "
      read CIDR
      if validate_cidr "$CIDR"; then break; else echo -e "[${RED}ERROR${TEXTRESET}] Invalid CIDR. Try again."; fi
  done

  DEFAULT_START="$(echo "$CIDR" | awk -F. '{print $1"."$2"."$3".10"}')"
  DEFAULT_END="$(echo "$CIDR" | awk -F. '{print $1"."$2"."$3".100"}')"

  while true; do
      echo -n "Enter start IP for pool [$DEFAULT_START]: "
      read pool_start
      pool_start=${pool_start:-$DEFAULT_START}
      if validate_ip "$pool_start"; then break; else echo -e "[${RED}ERROR${TEXTRESET}] Invalid IP. Try again."; fi
  done

  while true; do
      echo -n "Enter end IP for pool [$DEFAULT_END]: "
      read pool_end
      pool_end=${pool_end:-$DEFAULT_END}
      if validate_ip "$pool_end"; then break; else echo -e "[${RED}ERROR${TEXTRESET}] Invalid IP. Try again."; fi
  done

  while true; do
      echo -n "Enter router address [default: $dns_server_ip]: "
      read router_address
      router_address=${router_address:-$dns_server_ip}
      if validate_ip "$router_address"; then break; else echo -e "[${RED}ERROR${TEXTRESET}] Invalid IP. Try again."; fi
  done

  EXTRA_OPTIONS=()
  echo -e "\nWould you like to add custom DHCP options?"
  echo -e "For example:\n  tftp-server-name = 150\nOther examples: bootfile-name, domain-name, time-servers, etc."
  read -p "Add custom DHCP options now? [y/N]: " add_opts

  if [[ "$add_opts" =~ ^[Yy]$ ]]; then
    while true; do
      echo -e "\nChoose option type:"
      echo "1) Standard option (name + value)"
      echo "2) Advanced option (code + name + value)"
      echo "(?) Show examples"
      read -p "#? " opt_type

      if [[ "$opt_type" == "?" ]]; then
        echo -e "\nExamples:\n  Standard: tftp-server-name = 192.168.50.10"
        echo "  Advanced: code=150 name=tftp-server-name space=dhcp4 data=192.168.50.10"
        echo "  More examples: bootfile-name, time-servers, log-servers, domain-name"
        continue
      fi

      case "$opt_type" in
        1)
          read -p "Enter option name: " opt_name
          read -p "Enter value for $opt_name: " opt_value
          EXTRA_OPTIONS+=("{\"name\": \"$opt_name\", \"data\": \"$opt_value\"}")
          ;;
        2)
          read -p "Enter option code (e.g. 150): " opt_code
          read -p "Enter option name (e.g. tftp-server-name): " opt_name
          read -p "Enter value for $opt_name: " opt_value
          read -p "Enter space (default: dhcp4): " opt_space
          opt_space=${opt_space:-dhcp4}
          EXTRA_OPTIONS+=("{\"code\": $opt_code, \"name\": \"$opt_name\", \"space\": \"$opt_space\", \"data\": \"$opt_value\"}")
          ;;
        *)
          echo "Invalid choice. Try again."
          continue
          ;;
      esac

      read -p "Add another option? [y/N]: " again
      [[ ! "$again" =~ ^[Yy]$ ]] && break
    done
  fi

  EXTRA_JSON=$(IFS=,; echo "${EXTRA_OPTIONS[*]}")

  echo -e "\nReview settings:"
  echo -e "Friendly Name: ${GREEN}$description${TEXTRESET}"
  echo -e "Network Scheme: ${GREEN}$CIDR${TEXTRESET}"
  echo -e "Interface: ${GREEN}$SELECTED_IFACE${TEXTRESET}"
  echo -e "IP Pool Range: ${GREEN}$pool_start - $pool_end${TEXTRESET}"
  echo -e "Router Address: ${GREEN}$router_address${TEXTRESET}"
  echo -e "NTP Server: ${GREEN}$dns_server_ip${TEXTRESET}"
  echo -e "DNS Server: ${GREEN}$dns_server_ip${TEXTRESET}"
  echo -e "Client suffix: ${GREEN}$domain${TEXTRESET}"
  echo -e "Client Search Domain: ${GREEN}$domain${TEXTRESET}"

  if [[ ${#EXTRA_OPTIONS[@]} -gt 0 ]]; then
    echo -e "Custom DHCP Options:"
    for opt in "${EXTRA_OPTIONS[@]}"; do
      echo "$opt" | jq -r '. | "- " + (if .code then "[code=" + (.code|tostring) + "] " else "" end) + .name + " = " + .data'
    done
  fi

  read -p "Is this configuration correct? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
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
          echo -e "[${GREEN}SUCCESS${TEXTRESET}] Subnet added successfully."
          echo -e "[INFO] Restarting KEA DHCP service..."
          if systemctl restart kea-dhcp4; then
              echo -e "[${GREEN}SUCCESS${TEXTRESET}] KEA DHCP restarted."
          else
              echo -e "[${RED}ERROR${TEXTRESET}] Failed to restart KEA DHCP."
          fi
      else
          echo -e "[${RED}FAIL${TEXTRESET}] Failed to validate updated config. Reverting."
          exit 1
      fi

      ip_portion="$(echo "$CIDR" | cut -d'/' -f1)"
      reversed_ip="$(reverse_ip "$ip_portion")"
      reverse_zone="${reversed_ip}.in-addr.arpa"
      reverse_zone_file="${ZONE_DIR}db.${reversed_ip}"
      full_hostname=$(hostnamectl status | awk '/Static hostname:/ {print $3}')
      hostname="${full_hostname%%.*}"
      domain="${full_hostname#*.}"

      echo -e "[${YELLOW}INFO${TEXTRESET}] Checking for reverse zone: ${reverse_zone}"

      if ! grep -q "zone \"$reverse_zone\"" "$NAMED_CONF"; then
          echo -e "[${YELLOW}INFO${TEXTRESET}] Reverse zone not found. Creating..."

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
          echo -e "[${GREEN}SUCCESS${TEXTRESET}] Reverse zone already exists."
      fi

      systemctl restart named && echo -e "[${GREEN}SUCCESS${TEXTRESET}] named restarted." || echo -e "[${RED}ERROR${TEXTRESET}] Failed to restart named."

      break
  else
      echo -e "\nLet's try that again..."
  fi

done
