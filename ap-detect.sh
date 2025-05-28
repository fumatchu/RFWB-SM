#!/bin/bash

# dialog-based Wi-Fi Access Point Testing Script (RFWB-Setup)

#set -euo pipefail

TEMP_INPUT=$(mktemp)
LOGFILE="/tmp/hostapd-test.log"
HOSTAPD_CONF="/etc/hostapd/hostapd-test.conf"

# ========== Dialog Helpers ==========
msg_box() { dialog --title "$1" --msgbox "$2" 10 60; }
yesno_box() { dialog --title "$1" --yesno "$2" 10 60; }
info_box() { dialog --infobox "$1" 5 60; sleep 2; }

# ========== Start Script ==========
dialog --title "Wi-Fi AP Test" --infobox "Initializing Wi-Fi Access Point Testing..." 5 50
sleep 1

# Step 1: Ensure required packages are installed
REQUIRED_PKGS=("hostapd" "iw" "iproute" "bridge-utils")
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! rpm -q "$pkg" &>/dev/null; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    for pkg in "${MISSING_PKGS[@]}"; do
        info_box "Installing missing package: $pkg"
        if ! dnf install -y "$pkg" &>/dev/null; then
            msg_box "Error" "Failed to install $pkg. Exiting."
            exit 1
        fi
    done
else
    info_box "All required packages are already installed."
fi

# Step 2: Find a wireless interface
WIFI_IFACE=$(iw dev | awk '/Interface/ {print $2}' | head -n 1)
if [[ -z "$WIFI_IFACE" ]]; then
    msg_box "No Wireless Interface" "No wireless interface found. Please check your hardware."
    exit 1
fi

info_box "Wireless interface found: $WIFI_IFACE"

# Step 3: Stop any running hostapd/wpa_supplicant
info_box "Stopping hostapd and wpa_supplicant..."
systemctl stop hostapd wpa_supplicant &>/dev/null || :
pkill -9 hostapd &>/dev/null || :
pkill -9 wpa_supplicant &>/dev/null || :
killall -q hostapd wpa_supplicant &>/dev/null || :
sleep 2

# Step 4: Reset Wi-Fi interface to managed
info_box "Resetting interface $WIFI_IFACE to managed mode..."
ip link set "$WIFI_IFACE" down
iw dev "$WIFI_IFACE" set type managed
ip link set "$WIFI_IFACE" up
sleep 1

# Step 5: Set to AP mode
info_box "Switching $WIFI_IFACE to Access Point mode..."
ip link set "$WIFI_IFACE" down
iw dev "$WIFI_IFACE" set type __ap
ip link set "$WIFI_IFACE" up
sleep 1

# Step 6: Create hostapd config
info_box "Creating test hostapd config..."
cat <<EOF > "$HOSTAPD_CONF"
interface=$WIFI_IFACE
driver=nl80211
ssid=RFWB-Setup
hw_mode=g
channel=6
auth_algs=1
wpa=0
EOF

# Step 7: Start hostapd
info_box "Starting hostapd..."
hostapd -dd "$HOSTAPD_CONF" &> "$LOGFILE" &
HOSTAPD_PID=$!
sleep 5

# Step 8: Check for probe requests
if grep -q "WLAN_FC_STYPE_PROBE_REQ" "$LOGFILE"; then
    PROBE_RESULT="success"
else
    PROBE_RESULT="fail"
fi

# Step 9: Ask user if they see the SSID
# Step 9: Ask user if they see the SSID
dialog --title "SSID Detection" \
  --yesno "Please check your Wi-Fi from another device.\n\nYou should see an SSID named: RFWB-Setup\n\nDo you see it?" 12 60

USER_SEES_SSID=$?  # 0 = Yes, 1 = No

# Step 10: Cleanup
info_box "Stopping hostapd and cleaning up..."
pkill -9 hostapd &>/dev/null || :
killall -q hostapd &>/dev/null || :
rm -f "$HOSTAPD_CONF" "$LOGFILE"

# Reset Wi-Fi interface
info_box "Resetting interface $WIFI_IFACE to managed..."
ip link set "$WIFI_IFACE" down
iw dev "$WIFI_IFACE" set type managed
ip link set "$WIFI_IFACE" up

# Final status
# Final status
if [[ "$USER_SEES_SSID" -eq 0 ]]; then
  msg_box "Success" "Test SSID RFWB-Setup detected!\n\nSystem is ready for full AP setup."
else
  msg_box "Test Failed" "You reported that the SSID was not visible.\n\nWi-Fi setup was unsuccessful."

  msg_box "Manual Setup Required" \
  "Unfortunately, we were not able to configure your radio hardware for Wi-Fi.\n\nIf you would still like to use Wi-Fi, you must set it up manually using NetworkManager or nmtui."
fi
