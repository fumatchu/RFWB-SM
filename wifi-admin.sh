#!/bin/bash

# Wi-Fi Administration Menu (RFWB)

# Determine if we're sourced or executed directly
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0

TEMP_INPUT=$(mktemp)

# ========== Dialog Helpers ==========
msg_box()    { dialog --title "$1" --msgbox "$2" 10 60; }
yesno_box()  { dialog --title "$1" --yesno "$2" 10 60; }
info_box()   { dialog --infobox "$1" 5 60; sleep 2; }

# ========== Function: Show Wi-Fi Hardware Capabilities ==========
show_wifi_hardware_info() {
    > "$TEMP_INPUT"
    REG_DOMAIN=$(iw reg get 2>/dev/null | awk '/country/ {print $2}' | head -n1)

    while IFS= read -r IFACE; do
        SYS_PATH="/sys/class/net/$IFACE/device"
        DRIVER="$(basename $(readlink -f "$SYS_PATH/driver" 2>/dev/null))"
        DESC="$(modinfo "$DRIVER" 2>/dev/null | awk -F: '/description:/ {print $2}' | xargs)"
        MAC_ADDR=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
        IFACE_STATE=$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null)

        CONNECTION_TYPE="Unknown"
        if [[ -L "$SYS_PATH/../usb"* ]]; then
            CONNECTION_TYPE="USB"
        elif [[ -L "$SYS_PATH/../pci"* ]]; then
            CONNECTION_TYPE="PCI"
        fi

        echo -e "Interface: $IFACE" >> "$TEMP_INPUT"
        echo -e "Driver: $DRIVER" >> "$TEMP_INPUT"
        echo -e "Description: $DESC" >> "$TEMP_INPUT"
        echo -e "Connection: $CONNECTION_TYPE" >> "$TEMP_INPUT"
        echo -e "MAC Address: $MAC_ADDR" >> "$TEMP_INPUT"
        echo -e "State: $IFACE_STATE" >> "$TEMP_INPUT"
        echo -e "Regulatory Domain: ${REG_DOMAIN:-Unknown}" >> "$TEMP_INPUT"

        PHY=$(iw dev $IFACE info | awk '/wiphy/ {print "phy" $2}')
        if [[ -n "$PHY" ]]; then
            iw phy "$PHY" info 2>/dev/null | \
            awk '/Band [0-9]+:/ {band=$0} /Frequencies:/ {getline; while ($0 ~ /^\s*\*/) {gsub(/^\s*\*/, ""); print "  " band " - " $0; getline}}' >> "$TEMP_INPUT"
        fi

        echo "" >> "$TEMP_INPUT"
    done < <(iw dev | awk '/Interface/ {print $2}')

    if [[ ! -s "$TEMP_INPUT" ]]; then
        echo "No wireless hardware detected." > "$TEMP_INPUT"
    fi

    dialog --title "Wi-Fi Hardware Info" --textbox "$TEMP_INPUT" 30 90
    rm -f "$TEMP_INPUT"
}

# ========== Function: Test Wi-Fi Hardware ==========
test_wifi_hardware() {
    /root/.rfwb-admin/ap-detect.sh
}

# ========== Wi-Fi Admin Menu ==========
wifi_admin_menu() {
    while true; do
        CHOICE=$(dialog --clear \
            --title "Wi-Fi Administration" \
            --menu "Choose an option:" 15 60 6 \
            1 "Test Wireless Hardware" \
            2 "Show Wireless Hardware Info" \
            3 "Back" \
            3>&1 1>&2 2>&3)

        case "$CHOICE" in
            1)
                test_wifi_hardware
                ;;
            2)
                show_wifi_hardware_info
                ;;
            3|"")
                break
                ;;
        esac
    done
}

# Run the menu if script is executed directly
if [[ $SOURCED -eq 0 ]]; then
    wifi_admin_menu
fi
