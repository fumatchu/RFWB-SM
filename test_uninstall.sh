#!/bin/bash


TEMP_INPUT=$(mktemp)
LOG_FILE="/tmp/wifi_uninstall.log"
: > "$LOG_FILE"

msg_box() { dialog --title "$1" --msgbox "$2" 12 60; }
menu_box() { dialog --menu "$1" 15 60 5 "1" "Proceed with Uninstall" "2" "Cancel" 2>"$TEMP_INPUT"; }

# === Detect Wi-Fi Bridge ===
mapfile -t WIFI_BRIDGES < <(nmcli -t -f NAME,TYPE connection show --active | grep '^br-wifi[0-9]\+:bridge$' | cut -d: -f1)

if [[ ${#WIFI_BRIDGES[@]} -eq 0 ]]; then
  msg_box "Nothing Found" "No active Wi-Fi bridges detected."
  exit 0
fi

BRIDGE_NAME="${WIFI_BRIDGES[0]}"
VLAN_ID=$(echo "$BRIDGE_NAME" | sed -E 's/.*([0-9]+)$/\1/')
VLAN_DEV=$(nmcli -g GENERAL.DEVICES connection show "wifi-vlan${VLAN_ID}" 2>/dev/null | head -n1)
WIFI_IFACE=$(iw dev | awk '/Interface/ {print $2}' | head -n 1)
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
KEA_CONF="/etc/kea/kea-dhcp4.conf"
KEA_DDNS_CONF="/etc/kea/kea-dhcp-ddns.conf"
NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named"
FILTER_TABLE="inet filter"

# Extract CIDR from bridge
CIDR=$(nmcli -g IP4.ADDRESS device show "$BRIDGE_NAME" | grep '/' | head -n1 | cut -d' ' -f1)
BRIDGE_IP=$(echo "$CIDR" | cut -d/ -f1)
REV_ZONE=$(echo "$BRIDGE_IP" | awk -F. '{print $3"."$2"."$1}')
REV_FILE="db.${REV_ZONE}"
ZONE_NAME_BIND="${REV_ZONE}.in-addr.arpa"

SUMMARY="The following will be removed:\n\n"
SUMMARY+="- Bridge: $BRIDGE_NAME\n"
SUMMARY+="- VLAN: wifi-vlan${VLAN_ID} (${VLAN_DEV})\n"
SUMMARY+="- Bridge Slaves: wifi-vlan${VLAN_ID}-slave, wifi-phy-slave${VLAN_ID}\n"
SUMMARY+="- hostapd config ($HOSTAPD_CONF)\n"
SUMMARY+="- nftables rules for $BRIDGE_NAME\n"
SUMMARY+="- Kea subnet entry for $CIDR\n"
SUMMARY+="- Reverse zone: $ZONE_NAME_BIND\n"
SUMMARY+="- Zone file: $ZONE_DIR/$REV_FILE\n"

msg_box "Wi-Fi Uninstall Summary" "$SUMMARY"
menu_box "Confirm removal of Wi-Fi VLAN $VLAN_ID?"
choice=$(<"$TEMP_INPUT")
[[ "$choice" != "1" ]] && exit 0

# === Remove nmcli connections ===
nmcli connection delete "$BRIDGE_NAME" &>> "$LOG_FILE" || true
nmcli connection delete "wifi-vlan${VLAN_ID}" &>> "$LOG_FILE" || true
nmcli connection delete "wifi-vlan${VLAN_ID}-slave" &>> "$LOG_FILE" || true
nmcli connection delete "wifi-phy-slave${VLAN_ID}" &>> "$LOG_FILE" || true

# === Disable and remove hostapd config ===
systemctl disable --now hostapd &>> "$LOG_FILE" || true
rm -f "$HOSTAPD_CONF"

# === Remove nftables rules ===
DROP_HANDLE=$(nft --handle list chain $FILTER_TABLE input | grep -F 'log prefix "INPUT DROP: "' | awk '{for (i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}')
if [[ -n "$DROP_HANDLE" ]]; then
  nft delete rule $FILTER_TABLE input handle "$DROP_HANDLE" &>> "$LOG_FILE" || true
fi
nft flush chain $FILTER_TABLE forward &>> "$LOG_FILE" || true

# === Remove subnet from Kea config ===
tmp1=$(mktemp)
jq --arg cidr "$CIDR" 'del(.Dhcp4.subnet4[] | select(.subnet == $cidr))' "$KEA_CONF" > "$tmp1" && mv "$tmp1" "$KEA_CONF"

tmp2=$(mktemp)
jq --arg iface "$BRIDGE_NAME" 'if .Dhcp4."interfaces-config".interfaces | index($iface) then .Dhcp4."interfaces-config".interfaces -= [$iface] else . end' "$KEA_CONF" > "$tmp2" && mv "$tmp
2" "$KEA_CONF"

# === Purge old leases associated with the removed subnet ===
LEASE_FILE="/var/lib/kea/kea-leases4.csv"
tmp_leases=$(mktemp)
awk -F, -v net="${BRIDGE_IP%.*}." '$1 !~ "^"net { print }' "$LEASE_FILE" > "$tmp_leases" && mv "$tmp_leases" "$LEASE_FILE"
chown kea:kea "$LEASE_FILE"
chmod 640 "$LEASE_FILE"
restorecon "$LEASE_FILE"

chown kea:kea "$KEA_CONF"
chmod 640 "$KEA_CONF"
restorecon "$KEA_CONF"

# === Remove reverse zone from Kea DDNS ===
tmp3=$(mktemp)
jq --arg z "${ZONE_NAME_BIND}." 'del(.DhcpDdns["reverse-ddns"]."ddns-domains"[] | select(.name == $z))' "$KEA_DDNS_CONF" > "$tmp3" && mv "$tmp3" "$KEA_DDNS_CONF"
chown kea:kea "$KEA_DDNS_CONF"
chmod 640 "$KEA_DDNS_CONF"
restorecon "$KEA_DDNS_CONF"

# === Remove zone from named.conf ===
sed -i "/zone \"$ZONE_NAME_BIND\"/,/^};/d" "$NAMED_CONF"

# === Remove reverse zone file ===
rm -f "$ZONE_DIR/$REV_FILE"
chown named:named "$ZONE_DIR" || true
restorecon -R "$ZONE_DIR"

# === Reload services ===
systemctl restart kea-dhcp4 kea-dhcp-ddns named &>> "$LOG_FILE" || true

msg_box "Uninstall Complete" "Wi-Fi VLAN $VLAN_ID and all associated configs were removed."
exit 0
