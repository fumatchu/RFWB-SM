#!/bin/bash

# dialog-based Wi-Fi Access Point Testing Script (RFWB-Setup)

# Determine if we're sourced or executed directly
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0

TEMP_INPUT=$(mktemp)
LOGDIR="/tmp/hostapd-test-logs"
mkdir -p "$LOGDIR"
HOSTAPD_CONF_DIR="/etc/hostapd"

# ========== Dialog Helpers ==========
msg_box()    { dialog --title "$1" --msgbox "$2" 10 60; }
yesno_box()  { dialog --title "$1" --yesno "$2" 10 60; }
info_box()   { dialog --infobox "$1" 5 60; sleep 2; }

# ========== Start Script ==========
dialog --title "Wi-Fi AP Test" --infobox "Initializing Wi-Fi Access Point Testing..." 5 50
sleep 1

REQUIRED_PKGS=("hostapd" "iw" "iproute" "bridge-utils" "lshw")
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
            [[ $SOURCED -eq 1 ]] && return || exit 1
        fi
    done
else
    info_box "All required packages are already installed."
fi

ALL_WLAN_IFACES=($(iw dev | awk '/Interface/ {print $2}'))

if [[ ${#ALL_WLAN_IFACES[@]} -eq 0 ]]; then
    msg_box "No Wireless Interface" "No wireless interface found. Please check your hardware."
    [[ $SOURCED -eq 1 ]] && return || exit 1
fi

# Build radiolist with chipset descriptions
RADIO_ITEMS=()
for IFACE in "${ALL_WLAN_IFACES[@]}"; do
    SYS_PATH="/sys/class/net/$IFACE/device"
    CHIP_DESC="Unknown chipset"

    if [[ -e "$SYS_PATH/modalias" ]]; then
        DRIVER_NAME=$(basename "$(readlink -f "$SYS_PATH/driver")" 2>/dev/null)
        CHIP_DESC=$(modinfo "$DRIVER_NAME" 2>/dev/null | awk -F: '/description:/ {print $2}' | xargs)
    fi

    if [[ "$CHIP_DESC" == "Unknown chipset" ]]; then
        CHIP_DESC=$(lshw -class network 2>/dev/null | awk -v iface="$IFACE" '
            $0 ~ "logical name: "iface {found=1}
            found && /product:/ {for (i=2;i<=NF;i++) printf "%s ", $i; print ""; exit}
        ')
        [[ -z "$CHIP_DESC" ]] && CHIP_DESC="Unknown chipset"
    fi

    RADIO_ITEMS+=("$IFACE" "$IFACE ($CHIP_DESC)" "off")
done

# ========== Prompt User ==========
while true; do
    dialog --title "Select Wireless Interface" \
      --radiolist "Choose ONE wireless interface to test:" \
      15 80 6 \
      "${RADIO_ITEMS[@]}" 2> "$TEMP_INPUT"

    DIALOG_EXIT=$?
    USER_IFACE=$(<"$TEMP_INPUT")
    rm -f "$TEMP_INPUT"

    if [[ $DIALOG_EXIT -ne 0 || -z "$USER_IFACE" ]]; then
        [[ $SOURCED -eq 1 ]] && return || exit 0
    fi

    SELECTED_IFACES=("$USER_IFACE")
    break
done

# ========== Begin Testing ==========
for WIFI_IFACE in "${SELECTED_IFACES[@]}"; do
    info_box "Preparing test for interface: $WIFI_IFACE"
    sleep 1

    systemctl stop hostapd wpa_supplicant &>/dev/null || :
    pkill -9 hostapd &>/dev/null || :
    pkill -9 wpa_supplicant &>/dev/null || :
    killall -q hostapd wpa_supplicant &>/dev/null || :
    sleep 1

    info_box "Resetting $WIFI_IFACE to managed mode..."
    ip link set "$WIFI_IFACE" down
    iw dev "$WIFI_IFACE" set type managed
    ip link set "$WIFI_IFACE" up
    sleep 1

    info_box "Switching $WIFI_IFACE to AP mode..."
    ip link set "$WIFI_IFACE" down
    iw dev "$WIFI_IFACE" set type __ap
    ip link set "$WIFI_IFACE" up
    sleep 1

    CONF_FILE="$HOSTAPD_CONF_DIR/hostapd-test-${WIFI_IFACE}.conf"
    LOG_FILE="$LOGDIR/hostapd-test-${WIFI_IFACE}.log"

    info_box "Creating hostapd config for $WIFI_IFACE..."
    cat <<EOF > "$CONF_FILE"
interface=$WIFI_IFACE
driver=nl80211
ssid=RFWB-Setup-${WIFI_IFACE}
hw_mode=g
channel=6
auth_algs=1
wpa=0
EOF

    info_box "Starting hostapd on $WIFI_IFACE..."
    hostapd -dd "$CONF_FILE" &> "$LOG_FILE" &
    HOSTAPD_PID=$!
    sleep 5

    if grep -q "WLAN_FC_STYPE_PROBE_REQ" "$LOG_FILE"; then
        PROBE_RESULT="success"
    else
        PROBE_RESULT="fail"
    fi

    dialog --title "SSID Detection ($WIFI_IFACE)" \
      --yesno "Please check your Wi-Fi from another device.\n\nYou should see an SSID named:\n  RFWB-Setup-${WIFI_IFACE}\n\nDo you see it?" 12 60

    USER_SEES_SSID=$?

    info_box "Stopping hostapd and cleaning up for $WIFI_IFACE..."
    pkill -9 hostapd &>/dev/null || :
    killall -q hostapd &>/dev/null || :
    rm -f "$CONF_FILE" "$LOG_FILE"
    sleep 1

    info_box "Restoring $WIFI_IFACE to managed mode..."
    ip link set "$WIFI_IFACE" down
    iw dev "$WIFI_IFACE" set type managed
    ip link set "$WIFI_IFACE" up
    sleep 1

    if [[ "$USER_SEES_SSID" -eq 0 ]]; then
        msg_box "Success ($WIFI_IFACE)" "Test SSID RFWB-Setup-${WIFI_IFACE} detected!\nInterface $WIFI_IFACE is working."
    else
        msg_box "Test Failed ($WIFI_IFACE)" "You reported that the SSID was not visible.\n\nManual configuration may be required."
    fi
done
