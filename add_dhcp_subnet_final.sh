#!/usr/bin/env bash
exec 2> >(grep -v 'escape sequence `\.' >&2)

# ─── Configuration ───────────────────────────────────────────────────────────
NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named"
STAGING_DIR="/tmp/dns-admin-staging"
mkdir -p "$STAGING_DIR"

# ─── Utility Functions ────────────────────────────────────────────────────────
list_zones() {
  grep 'zone[[:space:]]\+"' "$NAMED_CONF" | cut -d'"' -f2
}

validate_zone_name() { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]; }

show_zones() {
  mapfile -t zones < <(list_zones)
  if [ ${#zones[@]} -eq 0 ]; then
    dialog --msgbox "No zones defined." 6 40
  else
    msg=$(printf "• %s\n" "${zones[@]}")
    dialog --title "All Defined Zones" --msgbox "$msg" 20 60
  fi
}

finalize_file() {
  local file="$1"
  chown named:named "$file"
  chmod 640 "$file"
  restorecon "$file"
}

increment_soa_serial() {
  local file="$1"
  awk '
    BEGIN { in_soa=0; updated=0 }
    /SOA/ { in_soa=1 }
    in_soa && /[0-9]+[ \t]*;[ \t]*serial/ && !updated {
      sub(/[0-9]+/, $1+1)
      updated=1
    }
    /)/ && in_soa { in_soa=0 }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

ip_to_hex() {
  IFS=. read -r a b c d <<< "$1"
  printf '%02x%02x%02x%02x' "$a" "$b" "$c" "$d"
}


# ─── Structured Record Manager ───────────────────────────────────────────────

add_subnet_dialog() {
  CONFIG_FILE="/etc/kea/kea-dhcp4.conf"
  DDNS_FILE="/etc/kea/kea-dhcp-ddns.conf"
  USED_INTERFACES=$(jq -r '.Dhcp4.subnet4[].interface' "$CONFIG_FILE")
  BASE_IFACE=$(nmcli -t -f DEVICE,CONNECTION device status | awk -F: '$2 ~ /-inside$/ {print $1}')
  ALL_IFACES=$(nmcli -t -f DEVICE,CONNECTION device status | awk -F: -v base="$BASE_IFACE" '$1 == base || $1 ~ base"\.[0-9]+" {print $1}')

  AVAILABLE_INTERFACES=()
  for iface in $ALL_IFACES; do
    if ! grep -q "\"$iface\"" <<< "$USED_INTERFACES"; then
      AVAILABLE_INTERFACES+=("$iface")
    fi
  done

  if [[ ${#AVAILABLE_INTERFACES[@]} -eq 0 ]]; then
    dialog --msgbox "No available interfaces found for assignment." 6 50
    return
  fi

  iface_menu=()
  for i in "${!AVAILABLE_INTERFACES[@]}"; do
    ip=$(nmcli -g IP4.ADDRESS device show "${AVAILABLE_INTERFACES[$i]}" | awk -F/ '{print $1}')
    iface_menu+=("$i" "${AVAILABLE_INTERFACES[$i]} ($ip)")
  done

  exec 3>&1
  selected_index=$(dialog --menu "Select interface to assign to this subnet:" 20 60 10 "${iface_menu[@]}" 2>&1 1>&3)
  exec 3>&-
  SELECTED_IFACE="${AVAILABLE_INTERFACES[$selected_index]}"

  dns_server_ip=$(nmcli -g IP4.ADDRESS device show "$SELECTED_IFACE" | awk -F/ '{print $1}')
  if [ -z "$dns_server_ip" ]; then
    dialog --msgbox "No IP found for interface $SELECTED_IFACE." 6 50
    return
  fi

  full_hostname=$(hostnamectl status | awk '/Static hostname:/ {print $3}')
  hostname="${full_hostname%%.*}"
  domain="${full_hostname#*.}"

  existing_ids=($(jq '.Dhcp4.subnet4[].id' "$CONFIG_FILE" | sort -n))
id=1
for existing_id in "${existing_ids[@]}"; do
  if [[ "$id" -lt "$existing_id" ]]; then
    break
  fi
  ((id++))
done


  exec 3>&1
  iface_info=$(nmcli -g IP4.ADDRESS device show "$SELECTED_IFACE" | grep '/' | head -n1)
  base_ip=$(echo "$iface_info" | cut -d'/' -f1)
  prefix_len=$(echo "$iface_info" | cut -d'/' -f2)
  IFS=. read -r a b c d <<< "$base_ip"
  CIDR_SUGGEST="${a}.${b}.${c}.0/${prefix_len:-24}"
  [[ -z "$CIDR_SUGGEST" || "$CIDR_SUGGEST" == "..0/"* ]] && CIDR_SUGGEST="192.168.50.0/24"

  CIDR=$(dialog --inputbox "Enter subnet in CIDR notation (e.g. 192.168.50.0/24):" 8 50 "$CIDR_SUGGEST" 2>&1 1>&3)
  [[ -z "$CIDR" ]] && return

  ROUTER_DEFAULT="$dns_server_ip"
  ROUTER=$(dialog --inputbox "Enter default gateway IP (usually interface IP):" 8 50 "$ROUTER_DEFAULT" 2>&1 1>&3)
  DNS=$(dialog --inputbox "Enter DNS server IP (comma-separated if multiple):" 8 50 "$dns_server_ip" 2>&1 1>&3)

  DOMAIN_DEFAULT="$domain"
  domain=$(dialog --inputbox "Enter domain name (e.g., example.com):" 8 50 "$DOMAIN_DEFAULT" 2>&1 1>&3)
  [[ -z "$domain" ]] && domain="$DOMAIN_DEFAULT"

  IFS=. read -r a b c d <<< "$dns_server_ip"
  POOL_START_DEFAULT="${a}.${b}.${c}.10"
  POOL_START=$(dialog --inputbox "Enter start of DHCP pool (full IP):" 8 60 "$POOL_START_DEFAULT" 2>&1 1>&3)
  POOL_END_DEFAULT="${a}.${b}.${c}.100"
  POOL_END=$(dialog --inputbox "Enter end of DHCP pool (full IP):" 8 60 "$POOL_END_DEFAULT" 2>&1 1>&3)
  DESC=$(dialog --inputbox "Enter a friendly description for this subnet:" 8 50 2>&1 1>&3)
  [[ -z "$DESC" ]] && DESC="No description provided"

  EXTRA_OPTIONS=()
  dialog --yesno "Add custom DHCP options?" 7 50
  if [[ $? -eq 0 ]]; then
    while true; do
      exec 3>&1
      opt_type=$(dialog --menu "Select option type:" 15 50 4 1 "Standard Option" 2 "Advanced Option" 3 "Help" 2>&1 1>&3)
      exec 3>&-
      case "$opt_type" in
        1)
          exec 3>&1
n=$(dialog --inputbox "Option name (e.g. tftp-server-name):" 8 50 2>&1 1>&3)
v=$(dialog --inputbox "Option value (e.g. 192.168.50.10):" 8 50 2>&1 1>&3)
exec 3>&-
if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  v=$(ip_to_hex "$v")
fi
EXTRA_OPTIONS+=("{\"name\": \"$n\", \"data\": \"$v\"}")

          ;;
        2)
          exec 3>&1
c=$(dialog --inputbox "Option code (e.g. 150):" 8 50 2>&1 1>&3)
n=$(dialog --inputbox "Option name (e.g. TFTP-Server-Address):" 8 50 2>&1 1>&3)
v=$(dialog --inputbox "Option value (e.g. 192.168.50.10):" 8 50 2>&1 1>&3)
s=$(dialog --inputbox "Space (default: dhcp4):" 8 50 "dhcp4" 2>&1 1>&3)
exec 3>&-
if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  v=$(ip_to_hex "$v")
fi
EXTRA_OPTIONS+=("{\"code\": $c, \"name\": \"$n\", \"space\": \"$s\", \"data\": \"$v\"}")

          ;;
        3)
          dialog --msgbox "Example: Standard — name=tftp-server-name value=192.168.50.10
Advanced — code=150, space=dhcp4, name=tftp-server-address, value=192.168.50.10" 10 60
          continue
          ;;
        *)
          break
          ;;
      esac
      dialog --yesno "Add another DHCP option?" 7 50 || break
    done
  fi

  # Build standard DHCP options
  STANDARD_OPTIONS=$(jq -n --arg router "$ROUTER" --arg dns "$DNS" --arg domain "$domain" '
  [
    { "name": "routers", "data": $router },
    { "name": "domain-name-servers", "data": $dns },
    { "name": "ntp-servers", "data": $dns },
    { "name": "domain-search", "data": $domain },
    { "name": "domain-name", "data": $domain }
  ]')

  # Merge standard + custom DHCP options
  if [[ ${#EXTRA_OPTIONS[@]} -gt 0 ]]; then
    ALL_OPTIONS=$(jq -s '.[0] + .[1]' <(echo "$STANDARD_OPTIONS") <(printf '%s
' "${EXTRA_OPTIONS[@]}" | jq -s '.'))
  else
    ALL_OPTIONS="$STANDARD_OPTIONS"
  fi

  # Review summary
  SUMMARY="Subnet ID: $id
CIDR: $CIDR
Router: $ROUTER
DNS: $DNS
Domain: $domain
Pool: $POOL_START - $POOL_END
Interface: $SELECTED_IFACE"

  if [[ ${#EXTRA_OPTIONS[@]} -gt 0 ]]; then
    SUMMARY+="

Custom DHCP Options:
"
    for opt in "${EXTRA_OPTIONS[@]}"; do
      clean=$(echo "$opt" | jq -c .)
      SUMMARY+="  • $clean
"
    done
  fi

  dialog --yesno "$SUMMARY

Apply this configuration?" 20 70
  [[ $? -ne 0 ]] && { dialog --msgbox "Subnet creation cancelled." 6 40; return; }

  SUBNET_JSON=$(jq -n \
    --arg id "$id" \
    --arg cidr "$CIDR" \
    --arg desc "$DESC" \
    --arg pool_start "$POOL_START" \
    --arg pool_end "$POOL_END" \
    --argjson options "$ALL_OPTIONS" \
    '{
      id: ($id|tonumber),
      subnet: $cidr,
      comment: $desc,
      pools: [ { pool: ($pool_start + " - " + $pool_end) } ],
      "option-data": $options
    }')

  dialog --infobox "Saving new subnet..." 5 40
  sleep 1
  tmp_conf=$(mktemp)
  jq --argjson newsubnet "$SUBNET_JSON" '.Dhcp4.subnet4 += [$newsubnet]' "$CONFIG_FILE" > "$tmp_conf" && mv "$tmp_conf" "$CONFIG_FILE"
  chown kea:kea "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"
  restorecon "$CONFIG_FILE"
  chown kea:kea "$DDNS_FILE"
  chmod 640 "$DDNS_FILE"
  restorecon "$DDNS_FILE"


  dialog --infobox "Validating configuration..." 5 40
  sleep 1

  if kea-dhcp4 -t "$CONFIG_FILE"; then
    dialog --msgbox "Subnet added successfully and configuration validated!" 6 50
    # Update kea-dhcp-ddns.conf with reverse zone if missing
    rev_zone=$(echo "${CIDR%/*}" | awk -F. '{print $3"."$2"."$1}')
    existing_rev=$(jq --arg zone "$rev_zone.in-addr.arpa." '.DhcpDdns["reverse-ddns"]["ddns-domains"][]? | select(.name == $zone)' "$DDNS_FILE")
    if [[ -z "$existing_rev" ]]; then
    tmp_ddns=$(mktemp)
    jq --arg zone "$rev_zone.in-addr.arpa." '.DhcpDdns["reverse-ddns"]["ddns-domains"] += [{ "name": $zone, "key-name": "Kea-DDNS", "dns-servers": [ { "ip-address": "127.0.0.1", "port": 53 } ] }]' "$DDNS_FILE" > "$tmp_ddns" && mv "$tmp_ddns" "$DDNS_FILE"
    dialog --msgbox "Reverse zone $rev_zone.in-addr.arpa. added to kea-dhcp-ddns.conf." 7 60
    systemctl reload kea-dhcp-ddns
    systemctl restart kea-dhcp4
   dhcp_status=$(systemctl show -p ActiveState,ExecMainStatus kea-dhcp4)
ddns_status=$(systemctl show -p ActiveState,ExecMainStatus kea-dhcp-ddns)

if grep -q 'ActiveState=active' <<< "$dhcp_status" && \
   grep -q 'ExecMainStatus=0' <<< "$dhcp_status" && \
   grep -q 'ActiveState=active' <<< "$ddns_status" && \
   grep -q 'ExecMainStatus=0' <<< "$ddns_status"; then
  dialog --msgbox "KEA DHCPv4 restarted and KEA DDNS reloaded successfully." 7 60

    # Add reverse zone to named if missing
    ZONE_FILE="$ZONE_DIR/db.${rev_zone}"
    if ! grep -q "zone \"$rev_zone.in-addr.arpa\"" "$NAMED_CONF"; then
      cat >> "$NAMED_CONF" <<EOF

zone "$rev_zone.in-addr.arpa" {
    type master;
    file "$ZONE_FILE";
    allow-update { key "Kea-DDNS"; };
};
EOF

      last_octet=$(echo "$dns_server_ip" | awk -F. '{print $4}')
cat > "$ZONE_FILE" <<EOF
\$TTL 86400
@   IN  SOA   $full_hostname. admin.$domain. (
    2023100501 ; serial
    3600       ; refresh
    1800       ; retry
    604800     ; expire
    86400      ; minimum
)
@   IN  NS    $full_hostname.
$last_octet  IN PTR $full_hostname.
EOF

      finalize_file "$ZONE_FILE"
      systemctl restart named
      if systemctl is-active --quiet named; then
        dialog --msgbox "Reverse zone $rev_zone.in-addr.arpa. created and named restarted successfully." 7 60
      else
        dialog --msgbox "[ERROR] named failed to start after adding reverse zone." 7 60
      fi
    fi
else
  dialog --msgbox "[ERROR] One or more KEA services failed to start properly. Check systemctl status." 7 60
fi


  else
      dialog --msgbox "Reverse zone $rev_zone.in-addr.arpa. already exists in kea-dhcp-ddns.conf." 7 60
    fi

  else
    dialog --msgbox "Validation failed. Check /tmp/debug-kea-dhcp4.conf." 6 50
    cp "$CONFIG_FILE" /tmp/debug-kea-dhcp4.conf
    exit 1
  fi
  }
  add_subnet_dialog
