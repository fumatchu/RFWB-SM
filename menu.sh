#!/bin/bash

source /root/.rfwb-admin/lib.sh

#========[ CONFIGURATION ]========#
declare -A MODULE_PATHS=(
  [QOS]="/etc/rfwb-qos.conf"
  [DHCP]="/etc/kea/kea-dhcp4.conf"
  [DNS]="/etc/named.conf"
  [Suricata]="/etc/suricata/suricata.yaml"
  [RFWB-PORTSCAN]="/etc/rfwb/portscan.conf"
  [NFT-Threatlist]="/usr/local/bin/update_nft_threatlist.sh"
)

declare -A MODULE_SCRIPTS=(
  [INTERFACES]="/root/.rfwb-admin/interface-management.sh"
  [QOS]="/root/.rfwb-admin/qos-admin.sh"
  [DHCP]="/root/.rfwb-admin/dhcp-admin.sh"
  [DNS]="/root/.rfwb-admin/dns-admin.sh"
  [Suricata]="/root/.rfwb-admin/suricata-admin.sh"
  [RFWB-PORTSCAN]="/root/.rfwb-admin/rfwb-portscan-admin.sh"
  [NFT-Threatlist]="/root/.rfwb-admin/nft-threat-admin.sh"
  [SERVICES]="/root/.rfwb-admin/service-admin.sh"
)

declare -A MODULE_DESCRIPTIONS=(
  [INTERFACES]="Configure Ethernet/Wireless and guest networks"
  [QOS]="Manage QoS traffic shaping"
  [DHCP]="Configure Kea DHCP server"
  [DNS]="Manage BIND DNS zones"
  [Suricata]="Inspect Suricata IDS config"
  [RFWB-PORTSCAN]="Portscan detection for nftables"
  [NFT-Threatlist]="Threatlist updates for nftables"
  [SERVICES]="Check system service statuses"
)

#========[ MODULE HANDLER ]========#
manage_module() {
  local module="$1"
  local script="${MODULE_SCRIPTS[$module]}"

  if [[ -x "$script" ]]; then
    "$script"
  elif [[ -f "$script" ]]; then
    source "$script"
    if declare -f "${module,,}_admin_menu" &>/dev/null; then
      "${module,,}_admin_menu"
    else
      dialog --msgbox "$module module loaded, but no menu function found." 6 50
    fi
  else
    dialog --msgbox "$module admin script not found or not executable." 6 50
  fi
}

#========[ MAIN MENU BUILDER ]========#
build_main_menu() {
  reset_backtitle
  add_to_backtitle "Main Menu"

  local menu=()

  menu=( "INTERFACES" "${MODULE_DESCRIPTIONS[INTERFACES]}" )

  for module in "${!MODULE_PATHS[@]}"; do
    if [[ -e "${MODULE_PATHS[$module]}" && -f "${MODULE_SCRIPTS[$module]}" ]]; then
      menu+=( "$module" "${MODULE_DESCRIPTIONS[$module]}" )
    fi
  done

  if [[ -f "${MODULE_SCRIPTS[SERVICES]}" ]]; then
    menu+=( "SERVICES" "${MODULE_DESCRIPTIONS[SERVICES]}" )
  fi

  menu+=(
    "UPDATES" "Check for Updates"
    "REBOOT" "Reboot Firewall"
    "EXIT" "Exit Admin Menu"
  )

  exec 3>&1
  selection=$(dialog --clear --title "Modular Admin Menu" \
    --backtitle "$BACKTITLE" \
    --menu "Select a module to manage:" 24 80 15 \
    "${menu[@]}" 2>&1 1>&3)
  exec 3>&-

  [[ $? -ne 0 ]] && return

  case "$selection" in
    EXIT) clear; exit 0 ;;
    UPDATES) check_for_updates ;;
    REBOOT) reboot_system ;;
    *) manage_module "$selection" ;;
  esac
}

#========[ PLACEHOLDER ACTIONS ]========#
check_for_updates() {
  dialog --title "Check for Updates" --backtitle "$BACKTITLE" --msgbox "Update checking not yet implemented." 6 50
}

reboot_system() {
  dialog --yesno "Are you sure you want to reboot the firewall?" 7 50
  if [[ $? -eq 0 ]]; then
    dialog --infobox "Rebooting system..." 5 40
    sleep 2
    reboot
  fi
}

#========[ START LOOP ]========#
while true; do
  build_main_menu
done
