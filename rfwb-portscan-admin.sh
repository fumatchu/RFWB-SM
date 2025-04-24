#!/bin/bash

CONF_FILE="/etc/rfwb-portscan.conf"
IGNORE_NETWORKS_FILE="/etc/nftables/ignore_networks.conf"
IGNORE_PORTS_FILE="/etc/nftables/ignore_ports.conf"
LOG_FILE="/var/log/rfwb-portscan.log"

EDITOR="${EDITOR:-vi}"

# ===== Dialog Helpers =====
msg_box() { dialog --title "$1" --msgbox "$2" 8 60; }

edit_file() {
  tmp=$(mktemp)
  cp "$1" "$tmp"
  out=$(mktemp)

  dialog --title "Editing $(basename "$1")" --editbox "$tmp" 25 80 2>"$out"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    if ! cmp -s "$tmp" "$out"; then
      cp "$out" "$1"
      msg_box "Updated" "Saved changes to $(basename "$1")"
    else
      msg_box "No Changes" "No changes were made to $(basename "$1")"
    fi
  else
    msg_box "Cancelled" "Edit cancelled. No changes were made."
  fi

  rm -f "$tmp" "$out"
}

# ===== View Blocked IPs =====
view_blocked_ips() {
  tmp=$(mktemp)
  nft list set inet scanblock threatlist > "$tmp" 2>/dev/null || echo "Set not found." > "$tmp"
  dialog --title "Blocked IPs" --textbox "$tmp" 25 80
  rm -f "$tmp"
}

# ===== Manual IP Management =====
manual_add_ip() {
  ip=$(dialog --inputbox "Enter IP to block manually:" 8 50 2>&1 >/dev/tty)
  [[ -z "$ip" ]] && return
  nft add element inet scanblock threatlist { $ip } && \
  msg_box "Success" "$ip added to blocklist."
}

manual_remove_ip() {
  ip=$(dialog --inputbox "Enter IP to remove from blocklist:" 8 50 2>&1 >/dev/tty)
  [[ -z "$ip" ]] && return
  nft delete element inet scanblock threatlist { $ip } && \
  msg_box "Success" "$ip removed from blocklist."
}

# ===== View Logs =====
view_logs() {
  if [[ -f "$LOG_FILE" ]]; then
    dialog --title "rfwb-portscan Logs" --textbox "$LOG_FILE" 25 100
  else
    msg_box "Logs Missing" "$LOG_FILE not found."
  fi
}

# ===== Service Control =====
service_control() {
  while true; do
    choice=$(dialog --title "Service Control" --menu "Choose action:" 15 60 6 \
      1 "Start rfwb-portscan" \
      2 "Stop rfwb-portscan" \
      3 "Restart rfwb-portscan" \
      4 "Status rfwb-portscan" \
      5 "Start rfwb-ps-mon" \
      6 "Stop rfwb-ps-mon" \
      7 "Restart rfwb-ps-mon" \
      8 "Status rfwb-ps-mon" \
      9 "Back" \
      3>&1 1>&2 2>&3)

    case $choice in
      1) systemctl start rfwb-portscan && msg_box "Started" "rfwb-portscan started." ;;
      2) systemctl stop rfwb-portscan && msg_box "Stopped" "rfwb-portscan stopped." ;;
      3) systemctl restart rfwb-portscan && msg_box "Restarted" "rfwb-portscan restarted." ;;
      4) systemctl status rfwb-portscan | tee /tmp/status && dialog --textbox /tmp/status 20 70 ;;
      5) systemctl start rfwb-ps-mon && msg_box "Started" "rfwb-ps-mon started." ;;
      6) systemctl stop rfwb-ps-mon && msg_box "Stopped" "rfwb-ps-mon stopped." ;;
      7) systemctl restart rfwb-ps-mon && msg_box "Restarted" "rfwb-ps-mon restarted." ;;
      8) systemctl status rfwb-ps-mon | tee /tmp/status && dialog --textbox /tmp/status 20 70 ;;
      9|*) break ;;
    esac
  done
}


# ===== Main Menu =====
main_menu() {
  while true; do
    choice=$(dialog --clear --title "rfwb-portscan Admin" --menu "Choose an option:" 20 60 10 \
      1 "View Blocked IPs" \
      2 "Manually Add IP" \
      3 "Manually Remove IP" \
      4 "Edit Detection Settings" \
      5 "Edit Ignore Networks" \
      6 "Edit Ignore Ports" \
      7 "View Logs" \
      8 "Service Control" \
      9 "Exit" \
      3>&1 1>&2 2>&3)

    case $choice in
      1) view_blocked_ips ;;
      2) manual_add_ip ;;
      3) manual_remove_ip ;;
      4) edit_file "$CONF_FILE" ;;
      5) edit_file "$IGNORE_NETWORKS_FILE" ;;
      6) edit_file "$IGNORE_PORTS_FILE" ;;
      7) view_logs ;;
      8) service_control ;;
      9 |*) clear; exit 0 ;;
    esac
  done
}

main_menu
