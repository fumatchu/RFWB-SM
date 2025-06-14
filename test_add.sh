#!/bin/bash

TEMP_INPUT=$(mktemp)
COMMON_PASSWORDS=("password" "12345678" "qwertyui" "letmein123" "admin123")
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
FILTER_TABLE="inet filter"

msg_box() { dialog --title "$1" --msgbox "$2" 10 60; }
input_box() { dialog --inputbox "$1" 8 60 "$2" 2>"$TEMP_INPUT"; }
menu_box() { dialog --menu "$1" 15 60 5 "${@:2}" 2>"$TEMP_INPUT"; }
checklist_box() { dialog --checklist "$1" 20 70 10 "${@:2}" 2>"$TEMP_INPUT"; }

validate_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

is_host_ip() {
  ipcalc -c "$1" >/dev/null 2>&1
}

get_supported_bands() {
  mapfile -t SUPPORTED_FREQS < <(iw list | awk '/^\s+\* [0-9]+/ {print $2}')
  SUPPORTED_BANDS=()
  for freq in "${SUPPORTED_FREQS[@]}"; do
    freq_int=${freq%%.*}
    (( freq_int >= 2400 && freq_int <= 2500 )) && SUPPORTED_BANDS+=("2.4")
    (( freq_int >= 5000 && freq_int <= 6000 )) && SUPPORTED_BANDS+=("5")
    (( freq_int >= 5925 )) && SUPPORTED_BANDS+=("6")
  done
  SUPPORTED_BANDS=($(printf "%s\n" "${SUPPORTED_BANDS[@]}" | sort -u))
}

get_supported_channel_widths() {
  mapfile -t CAPABILITIES < <(iw list | awk '/Capabilities:/,/^$/')
  SUPPORTED_WIDTHS=()
  for cap in "${CAPABILITIES[@]}"; do
    [[ "$cap" =~ HT20 ]] && SUPPORTED_WIDTHS+=("20")
    [[ "$cap" =~ HT40 ]] && SUPPORTED_WIDTHS+=("40")
    [[ "$cap" =~ VHT80 ]] && SUPPORTED_WIDTHS+=("80")
    [[ "$cap" =~ VHT160|HE160 ]] && SUPPORTED_WIDTHS+=("160")
    [[ "$cap" =~ HE80 ]] && SUPPORTED_WIDTHS+=("80")
  done
  SUPPORTED_WIDTHS=($(printf "%s\n" "${SUPPORTED_WIDTHS[@]}" | sort -u))
}

detect_band_congestion() {
  mapfile -t SCAN_FREQS < <(iw dev "$WIFI_IFACE" scan 2>/dev/null | awk '/freq:/ {print $2}')
  NUM_24=0; NUM_5=0; NUM_6=0
  for f in "${SCAN_FREQS[@]}"; do
    f_int=${f%%.*}
    (( f_int >= 2400 && f_int <= 2500 )) && ((NUM_24++))
    (( f_int >= 5000 && f_int <= 6000 )) && ((NUM_5++))
    (( f_int >= 5925 )) && ((NUM_6++))
  done
  CONGESTION_MSG="Visible APs:\n- 2.4 GHz: $NUM_24\n- 5 GHz: $NUM_5\n- 6 GHz: $NUM_6"
}

WIFI_IFACE=$(iw dev | awk '/Interface/ {print $2}' | head -n 1)
[[ -z "$WIFI_IFACE" ]] && msg_box "No Wi-Fi Interface" "No wireless interface found." && exit 1

WIFI_CHIPSET=$(lspci -nnk | grep -A2 Network | grep -i atheros)
IS_AR93XX=0
if [[ "$WIFI_CHIPSET" =~ AR93 ]]; then
  IS_AR93XX=1
  msg_box "Detected Chipset" "Atheros AR93xx detected — applying optimized config."
fi


INSIDE_IFACE=$(nmcli -t -f DEVICE,NAME connection show --active | awk -F: '$2 ~ /-inside$/ {print $1}' | head -n 1)
OUTSIDE_IFACE=$(nmcli -t -f DEVICE,NAME connection show --active | awk -F: '$2 ~ /-outside$/ {print $1}' | head -n 1)

get_supported_bands
get_supported_channel_widths
detect_band_congestion
msg_box "Band Congestion Info" "$CONGESTION_MSG"

chipset_info=$(lshw -class network 2>/dev/null | awk '/Wireless interface/,/^$/')
band_list=$(IFS=','; echo "${SUPPORTED_BANDS[*]}")
width_list=$(IFS=','; echo "${SUPPORTED_WIDTHS[*]}")
msg_box "Wi-Fi Chipset Info" "Detected chipset:\n\n$chipset_info\nSupported Bands: $band_list GHz\nChannel Widths: $width_list MHz"

if [[ "$IS_AR93XX" -eq 1 ]]; then
  CHANNEL=6
  HOSTAPD_HW_MODE="g"
else
  get_supported_bands
  get_supported_channel_widths
  detect_band_congestion
  msg_box "Band Congestion Info" "$CONGESTION_MSG"

  band_list=$(IFS=','; echo "${SUPPORTED_BANDS[*]}")
  width_list=$(IFS=','; echo "${SUPPORTED_WIDTHS[*]}")
  msg_box "Wi-Fi Chipset Info" "Detected chipset:\n\n$chipset_info\nSupported Bands: $band_list GHz\nChannel Widths: $width_list MHz"

  width_options=()
  [[ " ${SUPPORTED_WIDTHS[*]} " =~ " 20 " ]] && width_options+=("1" "20 MHz")
  [[ " ${SUPPORTED_WIDTHS[*]} " =~ " 40 " ]] && width_options+=("2" "40 MHz")
  [[ " ${SUPPORTED_WIDTHS[*]} " =~ " 80 " ]] && width_options+=("3" "80 MHz")
  [[ " ${SUPPORTED_WIDTHS[*]} " =~ " 160 " ]] && width_options+=("4" "160 MHz")
  [[ ${#width_options[@]} -eq 0 ]] && msg_box "Error" "No supported channel widths detected!" && exit 1

  menu_box "Select Channel Width:" "${width_options[@]}"
  WIDTH_CHOICE=$(<"$TEMP_INPUT")
  case "$WIDTH_CHOICE" in
    1) CHANNEL_WIDTH="20" ;;
    2) CHANNEL_WIDTH="40" ;;
    3) CHANNEL_WIDTH="80" ;;
    4) CHANNEL_WIDTH="160" ;;
    *) msg_box "Invalid Selection" "Defaulting to 20 MHz."; CHANNEL_WIDTH="20" ;;
  esac

  CHANNEL=36
  HOSTAPD_HW_MODE="a"
fi


: > "$HOSTAPD_CONF"  # Clear hostapd.conf before writing

echo "channel=$CHANNEL" >> "$HOSTAPD_CONF"

case "$CHANNEL_WIDTH" in
  20)
    echo "ht_capab=[HT20]" >> "$HOSTAPD_CONF"
    ;;
  40)
    echo "ht_capab=[HT40+]" >> "$HOSTAPD_CONF"
    echo "vht_oper_chwidth=0" >> "$HOSTAPD_CONF"
    echo "vht_oper_centr_freq_seg0_idx=$((CHANNEL + 2))" >> "$HOSTAPD_CONF"
    ;;
  80)
    echo "ht_capab=[HT40+]" >> "$HOSTAPD_CONF"
    echo "vht_oper_chwidth=1" >> "$HOSTAPD_CONF"
    echo "vht_oper_centr_freq_seg0_idx=$((CHANNEL + 6))" >> "$HOSTAPD_CONF"
    ;;
  160)
    echo "ht_capab=[HT40+]" >> "$HOSTAPD_CONF"
    echo "vht_oper_chwidth=2" >> "$HOSTAPD_CONF"
    echo "vht_oper_centr_freq_seg0_idx=$((CHANNEL + 14))" >> "$HOSTAPD_CONF"
    ;;
esac

# VLAN and bridge creation, SSID, PSK, nftables configuration continue below...

# (You can now append VLAN + bridge creation, nmcli setup, hostapd config, nft INPUT and FORWARD rules, etc. as discussed.)

while true; do
  input_box "Enter VLAN ID for Wi-Fi (e.g., 70):" "70"
  VLAN_ID=$(<"$TEMP_INPUT")
  VLAN_DEV="${INSIDE_IFACE}.${VLAN_ID}"
  BRIDGE_NAME="br-wifi${VLAN_ID}"
  nmcli device status | grep -q "$VLAN_DEV" && \
    msg_box "VLAN Exists" "VLAN $VLAN_ID already exists on $INSIDE_IFACE." && continue
  break
done

input_box "Enter SSID:" "RFWB-WIFI"
SSID=$(<"$TEMP_INPUT")

menu_box "Select WPA Mode:" 2 "WPA2" 3 "WPA3"
WPA_MODE=$(<"$TEMP_INPUT")

while true; do
  input_box "Enter Wi-Fi password (min 8 chars):" ""
  PSK=$(<"$TEMP_INPUT")
  [[ ${#PSK} -lt 8 ]] && msg_box "Invalid" "Password too short." && continue
  for p in "${COMMON_PASSWORDS[@]}"; do [[ "$PSK" == "$p" ]] && msg_box "Weak Password" "Choose a stronger password." && continue 2; done
  break
done

while true; do
  input_box "Enter static IP in CIDR (e.g. 192.168.${VLAN_ID}.1/24):" "192.168.${VLAN_ID}.1/24"
  CIDR=$(<"$TEMP_INPUT")
  validate_cidr "$CIDR" || { msg_box "Invalid" "CIDR format invalid."; continue; }
  is_host_ip "$CIDR" || { msg_box "Invalid" "Not a valid host IP."; continue; }
  SUBNET=$(ipcalc -n "$CIDR" | awk -F= '/NETWORK/ {print $2}')
  ip -4 addr | grep -q "$SUBNET" && msg_box "Conflict" "That subnet overlaps." && continue
  break
done

declare -A iface_cidrs iface_names
mapfile -t ALL_INTERFACES < <(nmcli -t -f DEVICE,CONNECTION device status | awk -F: '!/lo/ && NF==2 {print $1}')

for iface in "${ALL_INTERFACES[@]}"; do
  cidr=$(nmcli -g IP4.ADDRESS device show "$iface" | grep '/' | cut -d' ' -f1 || true)
  [[ -n "$cidr" ]] && {
    iface_names["$iface"]="$iface ($cidr)"
    iface_cidrs["$iface"]="$cidr"
  }
done

menu_items=( "None" "Skip Internet & internal access" off )
for i in "${!iface_cidrs[@]}"; do
  [[ "$i" != "$BRIDGE_NAME" ]] && menu_items+=("$i" "${iface_names[$i]}" off)
done

exec 3>&1
selected=$(dialog --checklist "Allow Wi-Fi ($CIDR) to access:" 20 70 10 "${menu_items[@]}" 2>&1 1>&3)
exec 3>&-
IFS=' ' read -r -a mappings <<< "$selected"

# Delete any existing connections to avoid conflicts
nmcli connection delete "$BRIDGE_NAME" &>/dev/null || true
nmcli connection delete "wifi-vlan${VLAN_ID}" &>/dev/null || true
nmcli connection delete "wifi-vlan${VLAN_ID}-slave" &>/dev/null || true
nmcli connection delete "wifi-phy-slave${VLAN_ID}" &>/dev/null || true

# Create the bridge with static IP
nmcli connection add type bridge con-name "$BRIDGE_NAME" ifname "$BRIDGE_NAME" \
  ipv4.method manual ipv4.addresses "$CIDR" ipv4.never-default yes autoconnect yes

# Create the VLAN on the internal interface
nmcli connection add type vlan con-name "wifi-vlan${VLAN_ID}" dev "$INSIDE_IFACE" id "$VLAN_ID" \
  ipv4.method disabled ipv6.method ignore autoconnect yes

# Add the VLAN interface as a bridge slave
nmcli connection add type bridge-slave con-name "wifi-vlan${VLAN_ID}-slave" \
  ifname "$VLAN_DEV" connection.interface-name "$VLAN_DEV" master "$BRIDGE_NAME"

# Add the Wi-Fi interface as a bridge slave
nmcli connection add type bridge-slave con-name "wifi-phy-slave${VLAN_ID}" \
  ifname "$WIFI_IFACE" connection.interface-name "$WIFI_IFACE" master "$BRIDGE_NAME"

# Bring up each component explicitly
nmcli connection up "wifi-vlan${VLAN_ID}" || true
nmcli connection up "wifi-vlan${VLAN_ID}-slave" || true
nmcli connection up "wifi-phy-slave${VLAN_ID}" || true
nmcli connection up "$BRIDGE_NAME" || true


mkdir -p /etc/hostapd
cat <<EOF > "$HOSTAPD_CONF"
interface=$WIFI_IFACE
bridge=$BRIDGE_NAME
driver=nl80211
ssid=$SSID
hw_mode=$HOSTAPD_HW_MODE
channel=$CHANNEL
auth_algs=1
wpa=$WPA_MODE
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$PSK
country_code=US
EOF

if [[ "$IS_AR93XX" -eq 1 ]]; then
  # Special hostapd settings for Atheros AR93xx
  cat <<EOF >> "$HOSTAPD_CONF"
ieee80211n=1
ht_capab=[HT40+][SHORT-GI-40][SHORT-GI-20][RX-STBC1][TX-STBC]
require_ht=1 # Require 802.11n clients only; disables legacy b/g
EOF
else
  case "$CHANNEL_WIDTH" in
    20)
      echo "ht_capab=[HT20]" >> "$HOSTAPD_CONF"
      ;;
    40)
      echo "ht_capab=[HT40+]" >> "$HOSTAPD_CONF"
      echo "vht_oper_chwidth=0" >> "$HOSTAPD_CONF"
      echo "vht_oper_centr_freq_seg0_idx=$((CHANNEL + 2))" >> "$HOSTAPD_CONF"
      ;;
    80)
      echo "ht_capab=[HT40+]" >> "$HOSTAPD_CONF"
      echo "vht_oper_chwidth=1" >> "$HOSTAPD_CONF"
      echo "vht_oper_centr_freq_seg0_idx=$((CHANNEL + 6))" >> "$HOSTAPD_CONF"
      ;;
    160)
      echo "ht_capab=[HT40+]" >> "$HOSTAPD_CONF"
      echo "vht_oper_chwidth=2" >> "$HOSTAPD_CONF"
      echo "vht_oper_centr_freq_seg0_idx=$((CHANNEL + 14))" >> "$HOSTAPD_CONF"
      ;;
  esac
fi


systemctl enable hostapd
systemctl daemon-reexec
systemctl restart hostapd

# Get the handle for the final drop rule in input chain
# INPUT chain: allow DNS, DHCP, NTP on BRIDGE
drop_handle=$(nft --handle list chain $FILTER_TABLE input | grep -F 'log prefix "INPUT DROP: "' | awk '{for (i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}')

if [[ -n "$drop_handle" ]]; then
  nft insert rule $FILTER_TABLE input handle "$drop_handle" iifname "$BRIDGE_NAME" udp dport 67 accept comment '"Wi-Fi DHCPv4"'
  nft insert rule $FILTER_TABLE input handle "$drop_handle" iifname "$BRIDGE_NAME" udp dport 53 accept comment '"Wi-Fi DNSv4 UDP"'
  nft insert rule $FILTER_TABLE input handle "$drop_handle" iifname "$BRIDGE_NAME" tcp dport 53 accept comment '"Wi-Fi DNSv4 TCP"'
  nft insert rule $FILTER_TABLE input handle "$drop_handle" iifname "$BRIDGE_NAME" udp dport 123 accept comment '"Wi-Fi NTP"'
else
  msg_box "Warning" "Could not insert before DROP rule. Manual nftables fix needed."
fi

# === Debug output to verify mappings and CIDRs ===
debug_msg=""
debug_msg+="Selected mappings:\n"
for tgt in "${mappings[@]}"; do
  debug_msg+="$tgt --> ${iface_cidrs[$tgt]}\n"
done
msg_box "Debug: Wi-Fi Mapping" "$debug_msg"

LOG_FILE="/tmp/wifi_nft_debug.log"
: > "$LOG_FILE"  # Clear old log

for tgt in "${mappings[@]}"; do
  tgt_cidr="${iface_cidrs[$tgt]}"
  [[ -z "$tgt_cidr" ]] && {
    echo "[ERROR] Missing CIDR for $tgt" >> "$LOG_FILE"
    msg_box "Error" "Missing CIDR for target interface $tgt."
    continue
  }

if [[ "$tgt" == "$OUTSIDE_IFACE" ]]; then
  if ! nft add rule $FILTER_TABLE forward_internet ip saddr "$CIDR" iifname "$BRIDGE_NAME" oifname "$OUTSIDE_IFACE" accept comment "\"Wi-Fi Auto Rule\"" 2>>"$LOG_FILE"; then
    msg_box "Error" "Failed to add forward_internet rule (see $LOG_FILE)"
  fi
else
  jump_line=$(nft --handle list chain $FILTER_TABLE forward | grep 'jump forward_internet' | tail -n1)
  jump_handle=$(awk '{for (i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}' <<< "$jump_line")

  echo "[DEBUG] forward_internet jump line: $jump_line" >> "$LOG_FILE"
  echo "[DEBUG] forward_internet jump handle: $jump_handle" >> "$LOG_FILE"

  if [[ -n "$jump_handle" ]]; then
    if ! nft insert rule $FILTER_TABLE forward handle "$jump_handle" \
      ip saddr "$CIDR" ip daddr "$tgt_cidr" \
      iifname "$BRIDGE_NAME" oifname "$tgt" accept comment "\"Wi-Fi Auto Rule\"" 2>>"$LOG_FILE"; then
      msg_box "Error" "Failed to insert rule before jump (see $LOG_FILE)"
    fi
  else
    if ! nft add rule $FILTER_TABLE forward \
      ip saddr "$CIDR" ip daddr "$tgt_cidr" \
      iifname "$BRIDGE_NAME" oifname "$tgt" accept comment "\"Wi-Fi Auto Rule\"" 2>>"$LOG_FILE"; then
      msg_box "Error" "Failed to add forward rule without jump (see $LOG_FILE)"
    fi
  fi
fi

done

add_wifi_subnet_to_kea() {
  local cidr="$1" iface="$2" domain="$3"
  local kea_config="/etc/kea/kea-dhcp4.conf"

  local iface_ip pool_start pool_end base_net id desc fqdn
  iface_ip=$(nmcli -g IP4.ADDRESS device show "$iface" | awk -F/ '{print $1}')
  base_net=$(echo "$cidr" | cut -d/ -f1 | awk -F. '{printf "%s.%s.%s", $1, $2, $3}')
  pool_start="${base_net}.10"
  pool_end="${base_net}.200"
  desc="Wi-Fi Subnet ($cidr)"

  id=$(jq '[.Dhcp4.subnet4[].id] | max + 1' "$kea_config" 2>/dev/null || echo 1)
  [[ -z "$id" || "$id" == "null" ]] && id=1
  fqdn=$(hostnamectl status | awk '/Static hostname:/ {print $3}')

  local options subnet tmp1 tmp2
  options=$(jq -n --arg r "$iface_ip" --arg d "$iface_ip" --arg dom "$domain" '[
    { "name": "routers", "data": $r },
    { "name": "domain-name-servers", "data": $d },
    { "name": "ntp-servers", "data": $d },
    { "name": "domain-search", "data": $dom },
    { "name": "domain-name", "data": $dom }
  ]')

  subnet=$(jq -n --argjson id "$id" --arg cidr "$cidr" --arg desc "$desc" \
                  --arg pool_start "$pool_start" --arg pool_end "$pool_end" \
                  --arg iface "$iface" --argjson opts "$options" '{
    id: $id,
    subnet: $cidr,
    comment: $desc,
    interface: $iface,
    pools: [ { pool: ($pool_start + " - " + $pool_end) } ],
    "option-data": $opts
  }')

  # First: add interface if missing
  tmp1=$(mktemp)
  jq --arg iface "$iface" '
    if .Dhcp4."interfaces-config".interfaces | index($iface) then
      .
    else
      .Dhcp4."interfaces-config".interfaces += [$iface]
    end
  ' "$kea_config" > "$tmp1"

  # Second: add new subnet to modified file
  tmp2=$(mktemp)
  jq --argjson sn "$subnet" '.Dhcp4.subnet4 += [$sn]' "$tmp1" > "$tmp2" && mv "$tmp2" "$kea_config"
  rm -f "$tmp1"

  chown kea:kea "$kea_config"
  chmod 640 "$kea_config"
  restorecon "$kea_config"

  kea-dhcp4 -t "$kea_config" || {
    msg_box "Error" "KEA config test failed."
    return 1
  }
}

add_reverse_zone_for_wifi() {
  local cidr="$1" iface_ip="$2" domain="$3"
  local kea_ddns="/etc/kea/kea-dhcp-ddns.conf"
  local named_conf="/etc/named.conf"
  local zone_dir="/var/named"

  local rev_zone zone_name_ddns zone_name_bind zone_file fqdn last_octet
  rev_zone=$(echo "${cidr%.*}" | awk -F. '{print $3"."$2"."$1}')
  zone_name_ddns="${rev_zone}.in-addr.arpa."
  zone_name_bind="${rev_zone}.in-addr.arpa"
  zone_file="$zone_dir/db.${rev_zone}"
  fqdn=$(hostnamectl status | awk '/Static hostname:/ {print $3}')
  last_octet=$(echo "$iface_ip" | awk -F. '{print $4}')

  if ! jq -e --arg z "$zone_name_ddns" '.DhcpDdns["reverse-ddns"]["ddns-domains"][]? | select(.name == $z)' "$kea_ddns" >/dev/null; then
    tmpddns=$(mktemp)
    jq --arg z "$zone_name_ddns" '.DhcpDdns["reverse-ddns"]["ddns-domains"] += [{
      "name": $z,
      "key-name": "Kea-DDNS",
      "dns-servers": [ { "ip-address": "127.0.0.1", "port": 53 } ]
    }]' "$kea_ddns" > "$tmpddns"
    mv "$tmpddns" "$kea_ddns"
    chown kea:kea "$kea_ddns"
    chmod 640 "$kea_ddns"
    restorecon "$kea_ddns"
  fi

  if ! grep -q "zone \"$zone_name_bind\"" "$named_conf"; then
    cat >> "$named_conf" <<EOF

zone "$zone_name_bind" {
  type master;
  file "$zone_file";
  allow-update { key "Kea-DDNS"; };
};
EOF
  fi

  if [[ ! -f "$zone_file" ]]; then
    cat > "$zone_file" <<EOF
\$TTL 86400
@   IN  SOA   ${fqdn}. admin.${domain}. (
    $(date +%Y%m%d01) ; serial
    3600       ; refresh
    1800       ; retry
    604800     ; expire
    86400 )    ; minimum
@   IN  NS    ${fqdn}.
$last_octet  IN PTR ${fqdn}.
EOF
    chown named:named "$zone_file"
    chmod 640 "$zone_file"
    restorecon "$zone_file"
  fi

  systemctl restart kea-dhcp-ddns kea-dhcp4 named
}

iface_ip=$(nmcli -g IP4.ADDRESS device show "$BRIDGE_NAME" | awk -F/ '{print $1}')
fqdn=$(hostnamectl status | awk '/Static hostname:/ {print $3}')
domain="${fqdn#*.}"

add_wifi_subnet_to_kea "$CIDR" "$BRIDGE_NAME" "$domain"
add_reverse_zone_for_wifi "$CIDR" "$iface_ip" "$domain"


msg_box "Wi-Fi Ready" "Access point and VLAN bridge configured successfully."
