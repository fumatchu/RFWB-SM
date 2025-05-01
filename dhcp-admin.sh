#!/bin/bash
# Dialog helpers
input_box() {
    local backtitle="$1" title="$2" message="$3" default_value="$4"
    exec 3>&1
    result=$(dialog --clear --backtitle "$backtitle" --title "$title" \
                   --inputbox "$message" 8 40 "$default_value" 2>&1 1>&3)
    rc=$?;
    exec 3>&-
    [[ $rc -ne 0 ]] && return 1
    echo "$result"
}

msg_box() {
    dialog --clear --backtitle "$1" --title "$2" --msgbox "$3" 10 50
}

yesno_box() {
    dialog --clear --backtitle "$1" --title "$2" --yesno "$3" 8 40
    return $?
}
#================== CONFIG ==================#
CONFIG_FILE="/etc/kea/kea-dhcp4.conf"
LEASES_FILE="/var/lib/kea/kea-leases4.csv"
RESERVATIONS_FILE="/etc/kea/reservations.json"
LOG_FILE="/var/log/kea-admin.log"
SERVICE_NAME="kea-dhcp4"

#================= SETUP ====================#
touch "$LOG_FILE"

#================= FUNCTIONS =================#

log_action() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Validate MAC address format
validate_mac() {
  [[ "$1" =~ ^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$ ]]
}

# Validate IPv4 address format
validate_ip() {
  local ip=$1
  local stat=1
  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    OIFS=$IFS; IFS='.'; ip=($ip); IFS=$OIFS
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    stat=$?
  fi
  return $stat
}

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

# List active leases with optional search
list_active_leases() {
  if [[ ! -f "$LEASES_FILE" ]]; then
    dialog --msgbox "Lease file not found: $LEASES_FILE" 6 50
    return
  fi

  exec 3>&1
  search_term=$(dialog --inputbox "Enter MAC, IP, or hostname to filter (blank = all):" 8 60 "" 2>&1 1>&3)
  exec 3>&-

  tmp_output=$(mktemp)
  {
    printf "%-20s %-17s %-15s %-10s\n" "Lease Time" "MAC Address" "IP Address" "Hostname"
    printf -- "%.0s-" {1..80}; echo
    awk -F, -v search="$search_term" 'BEGIN {IGNORECASE=1}
      NR > 1 && (search == "" || $1 ~ search || $2 ~ search || $9 ~ search) {
        printf "%-20s %-17s %-15s %-10s\n", $5, $2, $1, $9
      }
    ' "$LEASES_FILE" | sort
  } > "$tmp_output"

  dialog --title "Active DHCP Leases" --textbox "$tmp_output" 35 110
  rm -f "$tmp_output"
}

add_mac_reservation() {
  log_action "[DEBUG] Starting MAC reservation function"

  exec 3>&1
  mac=$(dialog --inputbox "Enter MAC address (e.g., 00:11:22:33:44:55):" 8 50 2>&1 1>&3)
  [[ -z "$mac" ]] && log_action "[DEBUG] MAC entry cancelled or failed" && return
  if ! validate_mac "$mac"; then
    dialog --msgbox "Invalid MAC address format." 6 50
    return
  fi

  ip=$(dialog --inputbox "Enter IP address to reserve for this MAC:" 8 50 2>&1 1>&3)
  [[ -z "$ip" ]] && log_action "[DEBUG] IP entry cancelled or failed" && return
  if ! validate_ip "$ip"; then
    dialog --msgbox "Invalid IP address format." 6 50
    return
  fi

  hostname=$(dialog --inputbox "Enter hostname (optional):" 8 50 2>&1 1>&3)
  exec 3>&-
  log_action "[DEBUG] Collected MAC: $mac, IP: $ip, Hostname: $hostname"

  # Check for duplicate MAC or IP
  if jq -e --arg mac "$mac" '.Dhcp4.subnet4[].reservations[]? | select(."hw-address" == $mac)' "$CONFIG_FILE" >/dev/null; then
    dialog --msgbox "[ERROR] MAC address $mac is already reserved." 6 60
    log_action "[ERROR] Duplicate MAC: $mac"
    return
  fi

  if jq -e --arg ip "$ip" '.Dhcp4.subnet4[].reservations[]? | select(."ip-address" == $ip)' "$CONFIG_FILE" >/dev/null; then
    dialog --msgbox "[ERROR] IP address $ip is already reserved." 6 60
    log_action "[ERROR] Duplicate IP: $ip"
    return
  fi

  ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
  }

  ip_int=$(ip_to_int "$ip")
  subnet_index=""

  mapfile -t entries < <(jq -c '.Dhcp4.subnet4[]' "$CONFIG_FILE")
  for i in "${!entries[@]}"; do
    cidr=$(jq -r '.subnet' <<< "${entries[$i]}")
    [[ "$cidr" == "null" ]] && continue

    subnet_ip="${cidr%/*}"
    prefix="${cidr#*/}"
    mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))

    subnet_int=$(ip_to_int "$subnet_ip")
    if (( (ip_int & mask) == (subnet_int & mask) )); then
      subnet_index="$i"
      break
    fi
  done

  if [[ -z "$subnet_index" ]]; then
    dialog --msgbox "[ERROR] Could not find matching subnet for IP $ip" 6 60
    log_action "[ERROR] No matching subnet for $ip"
    return
  fi

  log_action "[DEBUG] Subnet index matched: $subnet_index"

  tmpfile=$(mktemp)
  jq --arg mac "$mac" \
     --arg ip "$ip" \
     --arg hostname "$hostname" \
     --argjson idx "$subnet_index" \
     'if (.Dhcp4.subnet4[$idx].reservations) then
        (.Dhcp4.subnet4[$idx].reservations) += [{"hw-address": $mac, "ip-address": $ip, "hostname": $hostname}]
      else
        .Dhcp4.subnet4[$idx].reservations = [{"hw-address": $mac, "ip-address": $ip, "hostname": $hostname}]
      end' \
     "$CONFIG_FILE" > "$tmpfile" 2>>"$LOG_FILE"

  if [[ $? -ne 0 ]]; then
    dialog --msgbox "[ERROR] Failed to update configuration." 6 60
    log_action "[ERROR] jq failed to insert reservation"
    rm -f "$tmpfile"
    return
  fi

  mv "$tmpfile" "$CONFIG_FILE"
  chown kea:kea "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"
  restorecon "$CONFIG_FILE"

  log_action "[DEBUG] Reservation added to subnet $subnet_index"
  systemctl restart kea-dhcp4
  log_action "[INFO] Reservation for $mac -> $ip added and service restarted"
  dialog --msgbox "Reservation added and KEA restarted." 6 60
}
# Delete static MAC reservation
delete_mac_reservation() {
  CONFIG_FILE="/etc/kea/kea-dhcp4.conf"
  TMP_FILE="/tmp/kea-dhcp4.reservations.json"

  mapfile -t RES_LIST < <(
    jq -r '
      .Dhcp4.subnet4[] |
      select(.reservations != null and (.reservations | length > 0)) |
      .id as $sid | .comment as $desc |
      .reservations[] |
      "\($sid)|\($desc)|\(."hw-address")|\(."ip-address")|\(.hostname // "")"
    ' "$CONFIG_FILE"
  )

  if [[ ${#RES_LIST[@]} -eq 0 ]]; then
    dialog --msgbox "No static reservations found." 6 50
    return
  fi

  MENU=()
  for entry in "${RES_LIST[@]}"; do
    IFS="|" read -r sid desc mac ip host <<< "$entry"
    label="$mac → $ip"
    [[ -n "$host" ]] && label+=" ($host)"
    [[ -n "$desc" ]] && label+=" - $desc"
    MENU+=("${mac}|${sid}" "$label")
  done

  exec 3>&1
  sel=$(dialog --clear --title "Delete MAC Reservation" \
               --menu "Select a reservation to delete:" 20 80 12 \
               "${MENU[@]}" 2>&1 1>&3)
  exec 3>&-
  [[ -z "$sel" ]] && return

  mac="${sel%%|*}"
  sid="${sel##*|}"

  dialog --yesno "Are you sure you want to delete the reservation for $mac from subnet ID $sid?" 7 60 || return

  jq --arg mac "$mac" --arg sid "$sid" '
    .Dhcp4.subnet4 |= map(
      if (.id == ($sid | tonumber)) then
        .reservations |= map(select(."hw-address" != $mac))
      else . end
    )' "$CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_FILE"

  chown kea:kea "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"
  restorecon "$CONFIG_FILE"

  systemctl restart kea-dhcp4
  dialog --msgbox "Reservation for $mac deleted from subnet ID $sid." 6 60
}



# ─── Structured Record Manager ───────────────────────────────────────────────
  add_subnet () {
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
    cp "$CONFIG_FILE" /tmp/debug-kea-dhcp4.conf
    dialog --msgbox "Validation failed. Configuration saved to /tmp/debug-kea-dhcp4.conf for troubleshooting.
Returning to main menu." 8 60
    return
  fi
}


#!/usr/bin/env bash

# Full subnet deletion wizard for Kea DHCP and BIND DNS reverse zones

delete_subnet() {
  CONFIG="/etc/kea/kea-dhcp4.conf"
  DDNS_FILE="/etc/kea/kea-dhcp-ddns.conf"
  NAMED_CONF="/etc/named.conf"
  ZONE_DIR="/var/named"
  BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  TMP="/tmp/kea-dhcp4.modified.json"
  TMP_DDNS="/tmp/kea-dhcp-ddns.modified.json"
  DIFF="/tmp/kea-dhcp4.diff.$(date +%s)"

  [[ ! -f "$CONFIG" ]] && { dialog --msgbox "KEA config not found: $CONFIG" 6 50; return; }

  mapfile -t COMMENTS < <(jq -r '.Dhcp4.subnet4[] | select(.comment != null) | .comment' "$CONFIG")

  if [[ ${#COMMENTS[@]} -eq 0 ]]; then
    dialog --msgbox "No subnets found!" 6 50
    return
  fi

  MENU_ITEMS=()
  for comment in "${COMMENTS[@]}"; do
    subnet=$(jq -r --arg c "$comment" '.Dhcp4.subnet4[] | select(.comment == $c) | .subnet' "$CONFIG")
    MENU_ITEMS+=("$comment" "$subnet")
  done

  exec 3>&1
  CHOICE=$(dialog --clear --title "Delete Subnet" \
    --menu "Choose subnet to delete:" 20 60 ${#MENU_ITEMS[@]} \
    "${MENU_ITEMS[@]}" 2>&1 1>&3)
  rc=$?
  exec 3>&-
  [[ $rc -ne 0 ]] && return
  [[ -z "$CHOICE" ]] && return

  dialog --yesno "Really delete subnet: $CHOICE?" 7 50
  [[ $? -ne 0 ]] && return

  # Backup before deleting
  cp "$CONFIG" "$BACKUP"
  dialog --msgbox "Backup saved to:\n$BACKUP" 7 60

  # Find subnet CIDR
  CIDR=$(jq -r --arg c "$CHOICE" '.Dhcp4.subnet4[] | select(.comment == $c) | .subnet' "$CONFIG")

  # Create reverse zone name
  rev_zone=$(echo "${CIDR%/*}" | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
  rev_file="$ZONE_DIR/db.$(echo "${CIDR%/*}" | awk -F. '{print $3"."$2"."$1}')"

  # Remove from kea-dhcp4.conf
  jq --arg c "$CHOICE" 'del(.Dhcp4.subnet4[] | select(.comment == $c))' "$CONFIG" > "$TMP"

  # Validate new DHCP config
  if ! kea-dhcp4 -t "$TMP" 2> /tmp/kea_tmp_invalid.log; then
    dialog --title "Validation Failed" --textbox /tmp/kea_tmp_invalid.log 20 70
    dialog --msgbox "Config test failed. Backup was not replaced." 6 60
    return
  fi

  # Remove reverse zone from kea-dhcp-ddns.conf
  if [[ -f "$DDNS_FILE" ]]; then
    jq 'del(.DhcpDdns["reverse-ddns"]["ddns-domains"][] | select(.name == "'$rev_zone'"))' "$DDNS_FILE" > "$TMP_DDNS"
    mv "$TMP_DDNS" "$DDNS_FILE"
    chown kea:kea "$DDNS_FILE"
    chmod 640 "$DDNS_FILE"
    restorecon "$DDNS_FILE"
  fi

 # Remove reverse zone from named.conf
if grep -q "zone \"$rev_zone\"" "$NAMED_CONF"; then
  named_backup="${NAMED_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$NAMED_CONF" "$named_backup"
  sed -i "/zone \"$rev_zone\"/,/};/d" "$NAMED_CONF"
  # Clean up any stray closing braces left at the top level
  sed -i '/^};$/d' "$NAMED_CONF"
  chown root:named "$NAMED_CONF"
  chmod 640 "$NAMED_CONF"
  restorecon "$NAMED_CONF"
fi


  # Remove reverse zone db file
  if [[ -f "$rev_file" ]]; then
    rm -f "$rev_file"
  fi

  # Apply new DHCP config
  cp "$TMP" "$CONFIG"
  chown kea:kea "$CONFIG"
  chmod 640 "$CONFIG"
  restorecon "$CONFIG"

  chown kea:kea "$DDNS_FILE"
  chmod 640 "$DDNS_FILE"
  restorecon "$DDNS_FILE"

  chown root:named "$NAMED_CONF"
  chmod 640 "$NAMED_CONF"
  restorecon "$NAMED_CONF"

  diff -u "$BACKUP" "$CONFIG" > "$DIFF" || true
  dialog --yesno "Subnet removed successfully.\n\nDiff saved to:\n$DIFF\n\nApply changes and restart services?" 10 60
  [[ $? -ne 0 ]] && return

  systemctl restart kea-dhcp4
  systemctl reload kea-dhcp-ddns || systemctl restart kea-dhcp-ddns
  systemctl reload named || systemctl restart named

  dhcp_status=$(systemctl is-active kea-dhcp4)
  ddns_status=$(systemctl is-active kea-dhcp-ddns)
  named_status=$(systemctl is-active named)

  if [[ "$dhcp_status" == "active" && "$ddns_status" == "active" && "$named_status" == "active" ]]; then
    dialog --msgbox "Subnet deleted and all services restarted successfully." 7 60
  else
    dialog --msgbox "[WARNING] One or more services failed to restart. Please check systemctl status." 7 60
  fi
}



edit_config() {
  [ -f "$CONFIG_FILE" ] || {
    dialog --msgbox "KEA config not found at $CONFIG_FILE" 6 60
    return
  }

  tmp=$(mktemp)
  out=$(mktemp)
  cp "$CONFIG_FILE" "$tmp"

  exec 3>&1
  dialog --clear --title "Manual Edit: kea-dhcp4.conf" \
    --editbox "$tmp" 25 80 2>"$out" 1>&3
  erc=$?
  exec 3>&-
  rm -f "$tmp"

  [ $erc -ne 0 ] && { rm -f "$out"; return; }

  # Validate JSON
  if ! jq . "$out" >/dev/null 2>&1; then
    dialog --msgbox "Invalid JSON syntax. Changes discarded." 7 60
    rm -f "$out"
    log_action "Invalid JSON edit attempted. Discarded changes."
    return
  fi

  exec 3>&1
  dialog --clear --title "Apply Changes?" \
    --yesno "Save changes to $CONFIG_FILE?" 7 60
  arc=$?
  exec 3>&-

  if [ $arc -eq 0 ]; then
    backup="$CONFIG_FILE.bak.$(date '+%Y%m%d%H%M%S')"
    cp "$CONFIG_FILE" "$backup"
    mv "$out" "$CONFIG_FILE"
    dialog --msgbox "Changes saved. Backup created at: $backup" 6 60
    log_action "Manual edit applied to $CONFIG_FILE"
  else
    rm -f "$out"
    dialog --msgbox "Changes discarded." 6 40
  fi
}

restart_service() {
  systemctl restart "$SERVICE_NAME"
  dialog --msgbox "Service $SERVICE_NAME restarted." 6 40
  log_action "Service $SERVICE_NAME restarted"
}

show_status() {
  tmpfile=$(mktemp)
  systemctl status "$SERVICE_NAME" --no-pager | fold -s -w 110 > "$tmpfile"
  dialog --title "$SERVICE_NAME Service Status" --textbox "$tmpfile" 30 120
  rm -f "$tmpfile"
  log_action "Viewed service status for $SERVICE_NAME"
}

view_logs() {
  tail -n 50 "$LOG_FILE" > /tmp/kea-admin-log.txt
  dialog --title "KEA Admin Logs (Last 50 lines)" --textbox /tmp/kea-admin-log.txt 25 80
  rm -f /tmp/kea-admin-log.txt
}

kea_service_menu() {
  while true; do
    exec 3>&1
    choice=$(
      dialog --clear \
             --title "KEA Service Control" \
             --menu "Choose an action (Cancel→main menu):" \
             25 70 10 \
             1 "Show kea-dhcp4 status" \
             2 "View kea-dhcp4 logs" \
             3 "Restart kea-dhcp4" \
             4 "Show kea-dhcp-ddns status" \
             5 "View kea-dhcp-ddns logs" \
             6 "Restart kea-dhcp-ddns" \
             7 "Back to Main Menu" \
        2>&1 1>&3
    )
    rc=$?
    exec 3>&-

    [ $rc -ne 0 ] && break

    case "$choice" in
      1)
        tmpfile=$(mktemp)
        systemctl status kea-dhcp4 --no-pager | fold -s -w 110 > "$tmpfile"
        dialog --title "kea-dhcp4 Service Status" --textbox "$tmpfile" 30 120
        rm -f "$tmpfile"
        log_action "Viewed service status for kea-dhcp4"
        ;;
      2)
        journalctl -u kea-dhcp4 -n 200 --no-pager > /tmp/kea4-journal.log
        dialog --title "kea-dhcp4 Logs (last 200 lines)" \
               --tailbox /tmp/kea4-journal.log 30 120
        rm -f /tmp/kea4-journal.log
        log_action "Viewed logs for kea-dhcp4"
        ;;
      3)
        systemctl restart kea-dhcp4
        dialog --msgbox "kea-dhcp4 restarted successfully." 6 50
        log_action "Service kea-dhcp4 restarted"
        ;;
      4)
        tmpfile=$(mktemp)
        systemctl status kea-dhcp-ddns --no-pager | fold -s -w 110 > "$tmpfile"
        dialog --title "kea-dhcp-ddns Service Status" --textbox "$tmpfile" 30 120
        rm -f "$tmpfile"
        log_action "Viewed service status for kea-dhcp-ddns"
        ;;
      5)
        journalctl -u kea-dhcp-ddns -n 200 --no-pager > /tmp/keaddns-journal.log
        dialog --title "kea-dhcp-ddns Logs (last 200 lines)" \
               --tailbox /tmp/keaddns-journal.log 30 120
        rm -f /tmp/keaddns-journal.log
        log_action "Viewed logs for kea-dhcp-ddns"
        ;;
      6)
        systemctl restart kea-dhcp-ddns
        dialog --msgbox "kea-dhcp-ddns restarted successfully." 6 50
        log_action "Service kea-dhcp-ddns restarted"
        ;;
      7)
        break
        ;;
    esac
  done
}


#================== MAIN MENU ==================#
main_menu() {
  while true; do
    exec 3>&1
    CHOICE=$(dialog --clear --backtitle "KEA DHCP Admin Tool" \
      --title "Main Menu" \
      --menu "Choose an option:" 18 60 9 \
      1 "Add Subnet" \
      2 "Delete Subnet" \
      3 "Edit kea-dhcp4.conf manually" \
      4 "List Active Leases" \
      5 "Add MAC Reservation" \
      6 "Delete MAC Reservation" \
      7 "KEA Service Control" \
      8 "Exit" \
      2>&1 1>&3)
    menu_exit=$?
    exec 3>&-

    if [ $menu_exit -ne 0 ]; then
      break
    fi

    case "$CHOICE" in
      1) add_subnet ;;
      2) delete_subnet ;;
      3) edit_config ;;
      4) list_active_leases ;;
      5) add_mac_reservation ;;
      6) delete_mac_reservation ;;
      7) kea_service_menu ;;
      8) break ;;
    esac
  done
}

main_menu
clear
