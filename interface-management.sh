#!/bin/bash

source /root/.rfwb-admin/lib.sh
source /root/.rfwb-admin/vlan-admin.sh  # Add this line to include your VLAN logic

reset_backtitle
add_to_backtitle "Interfaces"

interfaces_admin_menu() {
  while true; do
    CHOICE=$(dialog --clear \
      --title "Interface Management" \
      --backtitle "$BACKTITLE" \
      --menu "Select an option:" 15 60 6 \
      1 "Launch nmtui (then restart rfwb-portscan)" \
      2 "Guest Network Setup" \
      3 "VLAN Management" \
      4 "Back to Main Menu" \
      3>&1 1>&2 2>&3)

    case "$CHOICE" in
      1)
        clear
        nmtui
        systemctl restart rfwb-portscan
        dialog --backtitle "$BACKTITLE" --msgbox "rfwb-portscan restarted." 6 50
        ;;
      2)
        guest_network_menu
        ;;
      3)
        vlan_main
        ;;
      4|"")
        break
        ;;
    esac
  done
}

guest_network_menu() {
  add_to_backtitle "Guest Network"

  while true; do
    CHOICE=$(dialog --clear \
      --title "Guest Network Setup" \
      --backtitle "$BACKTITLE" \
      --menu "Manage guest network:" 15 60 6 \
      1 "Add Guest Network" \
      2 "Remove Guest Network" \
      3 "Back" \
      3>&1 1>&2 2>&3)

    case "$CHOICE" in
      1)
        /root/.rfwb-admin/add_guest_network.sh
        ;;
      2)
        /root/.rfwb-admin/remove_guest_network.sh
        ;;
      3|"")
        break
        ;;
    esac
  done
}

interfaces_admin_menu
