WE NEED TO UPDATE THIS FOR MULTIPLE INSTANCES OF OPENVPN SERVICE
###############################################################
###############################################################
#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
CANDIDATE_UNITS=(
  chronyd.service
  evebox-agent.service
  evebox.service
  fail2ban.service
  kea-dhcp-ddns.service
  kea-dhcp4.service
  named.service
  openvpn-server@server.service
  rfwb-portscan.service
  rfwb-ps-mon.service
  snmpd.service
  sshd.service
  suricata.service
  cockpit.service
  netdata.service
  ntopng.service
)

# ─── Helpers ─────────────────────────────────────────────────────────────────
if ! command -v dialog &>/dev/null; then
  echo "Error: dialog is required. Install it and retry." >&2
  exit 1
fi

service_state() {
  systemctl is-active "$1" 2>/dev/null || echo "unknown"
}

get_installed_units() {
  local unit installed=()
  mapfile -t all_units < <( systemctl list-unit-files --no-legend --no-pager | awk '{print $1}' )
  for unit in "${CANDIDATE_UNITS[@]}"; do
    if printf '%s\n' "${all_units[@]}" | grep -qx "$unit"; then
      installed+=( "$unit" )
    fi
  done
  printf '%s\n' "${installed[@]}"
}

# ─── Unit Control Submenu ─────────────────────────────────────────────────────
control_unit_menu() {
  local unit="$1"
  while true; do
    exec 3>&1; set +e
    choice=$(
      dialog --clear \
             --title "Manage Unit: $unit" \
             --menu "Status: $(service_state "$unit")    Action:" \
             15 70 5 \
               1 "Start" \
               2 "Stop" \
               3 "Restart" \
               4 "View Logs" \
               5 "Back" \
        2>&1 1>&3
    )
    rc=$?; set -e; exec 3>&-
    [ $rc -ne 0 ] && break

    case $choice in
      1) systemctl start   "$unit" && dialog --msgbox "$unit started."   6 50 ;;
      2) systemctl stop    "$unit" && dialog --msgbox "$unit stopped."   6 50 ;;
      3) systemctl restart "$unit" && dialog --msgbox "$unit restarted." 6 50 ;;
      4)
        journalctl -u "$unit" -n 200 --no-pager > "/tmp/${unit//\//_}_logs.txt"
        dialog --title "$unit Logs (arrows/PageUp/PageDown)" \
               --tailbox "/tmp/${unit//\//_}_logs.txt" 30 120
        ;;
      5) break ;;
    esac
  done
}

# ─── Manage Installed Units ────────────────────────────────────────────────────
manage_units_menu() {
  while true; do
    mapfile -t UNITS < <( get_installed_units )
    [ ${#UNITS[@]} -gt 0 ] || { dialog --msgbox "No candidate units present." 6 60; break; }

    menu_args=()
    for u in "${UNITS[@]}"; do
      menu_args+=( "$u" "$(service_state "$u")" )
    done

    exec 3>&1; set +e
    selected=$(
      dialog --clear \
             --title "Systemd Unit Manager" \
             --menu "Select a unit to manage (Cancel→back):" \
             20 80 "${#UNITS[@]}" \
             "${menu_args[@]}" \
        2>&1 1>&3
    )
    rc=$?; set -e; exec 3>&-
    [ $rc -ne 0 ] && break

    control_unit_menu "$selected"
  done
}

# ─── Enable/Disable Services Submenu ──────────────────────────────────────────
enable_disable_menu() {
  # Temporarily disable errexit so cancelling ntsysv won't kill the script
  set +e
  dialog --clear \
         --title "Enable/Disable Services" \
         --msgbox "Launching ntsysv...\n\nUse space to toggle services, then OK to apply." \
         8 60
  ntsysv
  # Re-enable errexit
  set -e
}

# ─── Top‑Level Main Menu ──────────────────────────────────────────────────────
main_menu() {
  while true; do
    exec 3>&1; set +e
    choice=$(
      dialog --clear --title "Service Manager" \
             --menu "Choose an option (Cancel→exit):" \
             15 60 3 \
               1 "View/Manage Services" \
               2 "Enable/Disable Services (ntsysv)" \
               3 "Exit" \
        2>&1 1>&3
    )
    rc=$?; set -e; exec 3>&-
    [ $rc -ne 0 ] && break

    case $choice in
      1) manage_units_menu   ;;
      2) enable_disable_menu ;;
      3) clear; exit 0       ;;
    esac
  done
  clear
}

# ─── Startup ─────────────────────────────────────────────────────────────────
main_menu
