#!/bin/bash

THREAT_SCRIPT="/usr/local/bin/update_nft_threatlist.sh"
BLOCK_SET_NAME="threat_block"
NFTABLES_TABLE="inet filter"
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
  nft list set inet filter $BLOCK_SET_NAME 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
    sort -u > "$tmp"
  dialog --title "Current Blocked IPs" --textbox "$tmp" 25 80
  rm -f "$tmp"
}

# ===== Manually Add IP =====
add_ip() {
  TEMP_INPUT=$(mktemp)
  input_box "Add IP" "Enter IP to block:" "" || return
  ip="$INPUT"
  if [[ -n "$ip" ]]; then
    if grep -q "^$ip$" /etc/nft-threat-list/manual_block_list.txt; then
      msg_box "Already Exists" "$ip is already in the manual block list."
    else
      echo "$ip" >> /etc/nft-threat-list/manual_block_list.txt
      echo "[$(date)] Queued $ip for manual block" >> "$LOGFILE"
      msg_box "Success" "$ip added to manual block list."
    fi
  fi
  rm -f "$TEMP_INPUT"
}

# ===== Manually Remove IP =====
remove_ip() {
  TEMP_INPUT=$(mktemp)
  input_box "Remove IP" "Enter IP to remove from blocklist:" "" || return
  ip="$INPUT"
  if [[ -n "$ip" ]]; then
    if grep -q "^$ip$" /etc/nft-threat-list/manual_block_list.txt; then
      grep -v "^$ip$" /etc/nft-threat-list/manual_block_list.txt > /tmp/filtered_blocklist && \
      mv /tmp/filtered_blocklist /etc/nft-threat-list/manual_block_list.txt
      echo "[$(date)] Removed $ip from manual block list" >> "$LOGFILE"
      msg_box "Removed" "$ip removed from manual block list."
    else
      msg_box "Not Found" "$ip was not found in the manual block list."
    fi
  fi
  rm -f "$TEMP_INPUT"
}

# ===== Edit Feed URLs =====
edit_feeds() {
  tmp=$(mktemp)
  cp "$THREAT_FEEDS_FILE" "$tmp"
  out=$(mktemp)

  dialog --editbox "$tmp" 20 70 2>"$out"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    cp "$out" "$THREAT_FEEDS_FILE"
    msg_box "Updated" "Feed list saved to $THREAT_FEEDS_FILE"
  else
    msg_box "Cancelled" "Feed edit cancelled. No changes made."
  fi

  rm -f "$tmp" "$out"
}

# ===== Run Update Script =====
run_update() {
  bash "$THREAT_SCRIPT" > /tmp/threatlist-update.log 2>&1
  dialog --textbox /tmp/threatlist-update.log 25 80
  rm -f /tmp/threatlist-update.log
}

# ===== Show Pending Manual IPs =====
show_pending_manual() {
  TMP_FILE=$(mktemp)
  awk '/#########/{found=1; next} found && /^[0-9]+\./' /etc/nft-threat-list/manual_block_list.txt | sort -u > "$TMP_FILE"
  # Remove IPs already present in nftables
  nft list set inet filter $BLOCK_SET_NAME 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u > /tmp/current_nft_ips
  grep -vxFf /tmp/current_nft_ips "$TMP_FILE" > /tmp/pending_cleaned && mv /tmp/pending_cleaned "$TMP_FILE"
  if [[ -s "$TMP_FILE" ]]; then
    dialog --title "Pending Manual IPs" --textbox "$TMP_FILE" 25 80
  else
    msg_box "No Pending IPs" "No manually queued IPs remaining (all are applied)."
  fi
  rm -f "$TMP_FILE" /tmp/current_nft_ips
}

# ===== Apply Local Changes Only =====
apply_manual_blocklist() {
  dialog --title "Applying Manual Blocklist" --infobox "Applying updates to nftables..." 5 50
  sleep 1
  THREAT_LIST_FILE="/etc/nft-threat-list/threat_list.txt"
  MANUAL_BLOCK_LIST="/etc/nft-threat-list/manual_block_list.txt"
  COMBINED_BLOCK_LIST="/etc/nft-threat-list/combined_block_list.txt"
  TMP_FILE="/etc/nft-threat-list/threat_list.tmp"

  # Combine both static feed list and manual list
  awk '/#########/{found=1; next} found && /^[0-9]+\./' "$MANUAL_BLOCK_LIST" > "$TMP_FILE"
  cat "$THREAT_LIST_FILE" "$TMP_FILE" | sort -u > "$COMBINED_BLOCK_LIST"

  # Ensure the nftables set exists
  if ! nft list set inet filter threat_block &>/dev/null; then
    nft add table inet filter 2>/dev/null
    nft add set inet filter threat_block { type ipv4_addr\; flags timeout\; }
  else
    nft flush set inet filter threat_block
  fi

  # Add all IPs from the combined list to nftables
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && nft add element inet filter threat_block { $ip }
  done < "$COMBINED_BLOCK_LIST"

  IP_COUNT=$(wc -l < "$COMBINED_BLOCK_LIST")
  echo "[$(date)] Manual update applied with $IP_COUNT IPs from combined list." >> "$LOGFILE"
  clear
  msg_box "Manual Update Complete" "$IP_COUNT IPs applied from local combined list."
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
    BLOCKED_IPS=$(nft list set inet filter $BLOCK_SET_NAME | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | wc -l)
  fi
  while true; do
    choice=$(dialog --clear --title "NFT Threat List Admin" --menu "Select an option:" 20 60 10 \
  1 "View Current Blocked IPs" \
  2 "Manually Add IP to Blocklist" \
  3 "Manually Remove IP" \
  4 "Edit Feed URLs" \
  5 "Apply Manual IP Blocklist Now" \
  6 "Show Pending Manual IPs" \
  7 "Run Full Threatlist Update" \
  8 "Enable/Disable Daily Auto-Update" \
  9 "Service Control" \
  10 "Exit" \
  3>&1 1>&2 2>&3)

  case "$choice" in
  1) view_threatlist ;;
  2) add_ip ;;
  3) remove_ip ;;
  4) edit_feeds ;;
  5) apply_manual_blocklist ;;
  6) show_pending_manual ;;
  7) run_update ;;
  8) toggle_cron ;;
  9) service_control ;;
  10|*) clear; exit 0 ;;
esac

  done
}

main_menu
