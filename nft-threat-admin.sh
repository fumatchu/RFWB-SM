#!/bin/bash

THREAT_SCRIPT="/usr/local/bin/update_nft_threatlist.sh"
BLOCK_SET_NAME="threatlist"
NFTABLES_TABLE="inet"
NFTABLES_CHAIN="input"
THREAT_FEEDS_FILE="/etc/nft-threatlist-feeds.txt"
LOGFILE="/var/log/nft-threatlist.log"

EDITOR="${EDITOR:-vi}"

# ===== Dialog Helpers =====
msg_box() { dialog --title "$1" --msgbox "$2" 8 60; }
input_box() {
  dialog --inputbox "$2" 10 60 "$3" 2>"$TEMP_INPUT"
  result=$?
  [[ $result -ne 0 ]] && return 1
  INPUT=$(<"$TEMP_INPUT")
  return 0
}

# ===== View Current IPs =====
view_threatlist() {
  tmp=$(mktemp)
  nft list set $NFTABLES_TABLE $BLOCK_SET_NAME > "$tmp" 2>/dev/null || echo "Set not found." > "$tmp"
  dialog --title "Current Blocked IPs" --textbox "$tmp" 25 80
  rm -f "$tmp"
}

# ===== Manually Add IP =====
add_ip() {
  TEMP_INPUT=$(mktemp)
  input_box "Add IP" "Enter IP to block:" "" || return
  ip="$INPUT"
  if [[ -n "$ip" ]]; then
    nft add element $NFTABLES_TABLE $BLOCK_SET_NAME { $ip } 2>/dev/null && \
      echo "[$(date)] Added $ip manually" >> "$LOGFILE" && \
      msg_box "Success" "$ip added to blocklist."
  fi
  rm -f "$TEMP_INPUT"
}

# ===== Manually Remove IP =====
remove_ip() {
  TEMP_INPUT=$(mktemp)
  input_box "Remove IP" "Enter IP to remove from blocklist:" "" || return
  ip="$INPUT"
  if [[ -n "$ip" ]]; then
    nft delete element $NFTABLES_TABLE $BLOCK_SET_NAME { $ip } 2>/dev/null && \
      echo "[$(date)] Removed $ip manually" >> "$LOGFILE" && \
      msg_box "Success" "$ip removed from blocklist."
  fi
  rm -f "$TEMP_INPUT"
}

# ===== Edit Feed URLs =====
edit_feeds() {
  tmp=$(mktemp)
  cp "$THREAT_FEEDS_FILE" "$tmp"
  dialog --editbox "$tmp" 20 70 2>"$THREAT_FEEDS_FILE"
  rm -f "$tmp"
  msg_box "Updated" "Feed list saved to $THREAT_FEEDS_FILE"
}

# ===== Run Update Script =====
run_update() {
  bash "$THREAT_SCRIPT" > /tmp/threatlist-update.log 2>&1
  dialog --textbox /tmp/threatlist-update.log 25 80
  rm -f /tmp/threatlist-update.log
}

# ===== Cron Toggle =====
toggle_cron() {
  cron_file="/etc/cron.d/nft-threatlist"
  if [[ -f "$cron_file" ]]; then
    rm -f "$cron_file"
    msg_box "Cron Disabled" "Auto-update cron job disabled."
  else
    echo "@daily root $THREAT_SCRIPT" > "$cron_file"
    chmod 644 "$cron_file"
    msg_box "Cron Enabled" "Auto-update cron job enabled."
  fi
}

# ===== View Logs =====
view_logs() {
  if [[ -f "$LOGFILE" ]]; then
    dialog --title "Threat List Logs" --textbox "$LOGFILE" 25 100
  else
    msg_box "No Logs" "Log file not found: $LOGFILE"
  fi
}

# ===== Show Last Run =====
show_last_run() {
  if [[ -f "$LOGFILE" ]]; then
    last_run=$(grep 'Completed update' "$LOGFILE" | tail -n 1)
    [[ -z "$last_run" ]] && last_run="No successful update found."
  else
    last_run="Log file not found."
  fi
  msg_box "Last Update Status" "$last_run"
}

# ===== Service Control =====
service_control() {
  while true; do
    choice=$(dialog --clear --title "nft-threatlist Service Control" --menu "Choose an action (Cancel→main menu):" 15 60 6 \
      1 "Show service status" \
      2 "View recent logs" \
      3 "Restart update script" \
      4 "Show last successful update" \
      5 "Back to Main Menu" \
      3>&1 1>&2 2>&3)

    case "$choice" in
      1)
        systemctl status nft-threatlist.service | tee /tmp/nft_status
        dialog --textbox /tmp/nft_status 20 80
        ;;
      2)
        view_logs
        ;;
      3)
        systemctl restart nft-threatlist.service
        msg_box "Service Restarted" "nft-threatlist service restarted."
        ;;
      6|*) break ;;
      4) show_last_run ;;
    esac
  done
}

# ===== Main Menu =====
main_menu() {
  # Show last run timestamp and total IPs
  LAST_RUN="Not found"
  BLOCKED_IPS="0"
  if [[ -f "$LOGFILE" ]]; then
      if [[ -f "$LOGFILE" ]]; then
    LAST_RUN=$(grep 'Completed update' "$LOGFILE" | tail -n 1 | cut -d']' -f1 | tr -d '[')
    [[ -z "$LAST_RUN" ]] && LAST_RUN="Not found"
  fi
    [[ -z "$LAST_RUN" ]] && LAST_RUN="Not found"
  fi
    if nft list set $NFTABLES_TABLE $BLOCK_SET_NAME &>/dev/null; then
    BLOCKED_IPS=$(nft list set $NFTABLES_TABLE $BLOCK_SET_NAME | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | wc -l)
  fi
  while true; do
    choice=$(dialog --clear --title "NFT Threat List Admin [Last run: $LAST_RUN | IPs: $BLOCKED_IPS]" --menu "Select an option:" 20 60 10 \
      1 "View Current Blocked IPs" \
      2 "Manually Add IP to Blocklist" \
      3 "Manually Remove IP" \
      4 "Edit Feed URLs" \
      5 "Run Threatlist Update Now" \
      6 "Enable/Disable Daily Auto-Update" \
      7 "Service Control" \
      8 "Exit" \
      3>&1 1>&2 2>&3)

    case "$choice" in
      1) view_threatlist ;;
      2) add_ip ;;
      3) remove_ip ;;
      4) edit_feeds ;;
      5) run_update ;;
      6) toggle_cron ;;
      9|*) clear; exit 0 ;;
      7) service_control ;;
      8) clear; exit 0 ;;
    esac
  done
}

main_menu
