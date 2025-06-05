#!/bin/bash

# Wi-Fi Administration Menu (wifi-admin.sh)

source /root/.rfwb-admin/lib.sh

# Determine if sourced or run directly
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0

reset_backtitle
add_to_backtitle "Wi-Fi Management"

# ===== Helper Functions =====
msg_box()    { dialog --title "$1" --msgbox "$2" 10 60; }
yesno_box()  { dialog --title "$1" --yesno "$2" 10 60; }
info_box()   { dialog --infobox "$1" 5 60; sleep 2; }

# ===== Hardware Test Function =====
run_wifi_hardware_test() {
  /root/.rfwb-admin/ap-detect.sh
}

# ===== Wi-Fi Admin Menu =====
wifi_admin_menu() {
  while true; do
    CHOICE=$(dialog --clear \
      --title "Wi-Fi Administration" \
      --backtitle "$BACKTITLE" \
      --menu "Choose an option:" 15 60 6 \
      1 "Test Wi-Fi Hardware (AP Mode)" \
      2 "Back to Interfaces Menu" \
      3>&1 1>&2 2>&3)

    case "$CHOICE" in
      1)
        run_wifi_hardware_test
        ;;
      2|"")
        break
        ;;
    esac
  done
}

# If run directly, launch the menu
if [[ $SOURCED -eq 0 ]]; then
  wifi_admin_menu
fi
