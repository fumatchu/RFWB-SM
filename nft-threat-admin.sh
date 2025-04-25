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

# ===== Search for IP =====
search_threatlist() {
  TEMP_INPUT=$(mktemp)
  ip_list=$(mktemp)
  match_result=$(mktemp)

  # Extract all current blocked IPs
  nft list set inet filter $BLOCK_SET_NAME 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u > "$ip_list"

  dialog --inputbox "Enter full or partial IP to search (e.g. 192.168. or 10.0.0.5):" 10 60 2>"$TEMP_INPUT"
  result=$?
  [[ $result -ne 0 ]] && { rm -f "$TEMP_INPUT" "$ip_list" "$match_result"; return; }

  query=$(<"$TEMP_INPUT")
  grep -F "$query" "$ip_list" > "$match_result"

  if [[ -s "$match_result" ]]; then
    dialog --title "Matches for '$query'" --textbox "$match_result" 20 60
  else
    msg_box "No Matches" "No IPs matching '$query' were found in the current threat list."
  fi

  rm -f "$TEMP_INPUT" "$ip_list" "$match_result"
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
      nft add element inet filter threat_block { $ip } 2>/dev/null
      msg_box "Success" "$ip added to manual block list and applied to nftables."

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
      nft delete element inet filter threat_block { $ip } 2>/dev/null
      echo "[$(date)] Removed $ip from manual block list" >> "$LOGFILE"
      msg_box "Removed" "$ip removed from manual block list and nftables."

    else
      msg_box "Not Found" "$ip was not found in the manual block list."
    fi
  fi
  rm -f "$TEMP_INPUT"
}
# ===== EDIT FEEDS =====
edit_feeds() {
  local updater_script="/usr/local/bin/update_nft_threatlist.sh"
  local backup="${updater_script}.bak.$(date +%Y%m%d%H%M%S)"
  local tmp_clean=$(mktemp)
  local tmp_edit=$(mktemp)
  local tmp_final=$(mktemp)
  local tmp_new=$(mktemp)

  awk '/^THREAT_LISTS=\(/,/^\)/ {
  if ($0 ~ /^THREAT_LISTS=\(/ || $0 ~ /^\)/) next
  gsub(/"/, "", $0)
  sub(/^[[:space:]]+/, "", $0)
  sub(/[[:space:]]+$/, "", $0)
  print $0
  }' "$updater_script" > "$tmp_clean"


  dialog --editbox "$tmp_clean" 20 70 2>"$tmp_edit"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    cp "$updater_script" "$backup"

    if [[ ! -s "$tmp_edit" ]]; then
      msg_box "Empty Feed List" "Feed list cannot be empty.\nRestoring default feeds."
      cat > "$tmp_edit" <<EOF
https://iplists.firehol.org/files/firehol_level1.netset
https://www.abuseipdb.com/blacklist.csv
https://rules.emergingthreats.net/blockrules/compromised-ips.txt
EOF
    fi

    {
     echo "THREAT_LISTS=("
     sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "$tmp_edit" | sed 's/^/  "/;s/$/"/'
     echo ")"
    } > "$tmp_final"

    awk -v new_block="$tmp_final" '
      BEGIN {
        while ((getline line < new_block) > 0) {
          block[++i] = line
        }
        close(new_block)
      }
      /^THREAT_LISTS=\(/ { in_block = 1; for (j = 1; j <= i; j++) print block[j]; next }
      in_block && /^\)/ { in_block = 0; next }
      !in_block { print }
    ' "$updater_script" > "$tmp_new"

    mv "$tmp_new" "$updater_script"
    chmod +x "$updater_script"

    msg_box "Feeds Updated" "Feed list updated successfully.\nBackup saved: $backup"
  else
    msg_box "Cancelled" "Feed edit cancelled. No changes made."
  fi

  rm -f "$tmp_clean" "$tmp_edit" "$tmp_final" "$tmp_new"
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

# ===== View Logs =====
view_logs() {
  if [[ -f "$LOGFILE" ]]; then
    dialog --title "Threat List Logs" --textbox "$LOGFILE" 25 100
  else
    msg_box "No Logs" "Log file not found: $LOGFILE"
  fi
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

# ===== Show Last run  =====
show_last_run() {
  local syslog="/var/log/messages"
  local tmp_log=$(mktemp)

  # Grab the last starting point of an update
  local start_line
  start_line=$(grep -n 'nft-threat-list' "$syslog" | grep 'Starting NFTables threat list update' | tail -n 1 | cut -d: -f1)

  if [[ -z "$start_line" ]]; then
    msg_box "Last Update Status" "No successful update found."
    return
  fi

  # Grab 20 lines from the start (safe window)
  sed -n "$start_line,$((start_line + 20))p" "$syslog" > "$tmp_log"

  # Extract data
  local timestamp ip_count
  timestamp=$(grep 'Starting NFTables threat list update' "$tmp_log" | awk '{print $1, $2, $3}')
  ip_count=$(grep 'Threat list update completed' "$tmp_log" | grep -oE '[0-9]+ IPs')

  mapfile -t urls < <(grep 'Downloading' "$tmp_log" | awk -F'Downloading ' '{print $2}')

  # Build summary
  local summary="Last Update: $timestamp\n$ip_count\n\nDownloaded Feeds:"
  if [[ ${#urls[@]} -eq 0 ]]; then
    summary+="\n(no feeds logged)"
  else
    for url in "${urls[@]}"; do
      summary+="\n- $url"
    done
  fi

  dialog --title "Last Update Status" --msgbox "$summary" 20 90
  rm -f "$tmp_log"
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
  2 "Search IP's in Threatlist" \
  3 "Manually Add IP to Blocklist" \
  4 "Manually Remove IP" \
  5 "Edit Feed URLs" \
  6 "Run Full Threatlist Update" \
  7 "Enable/Disable Daily Auto-Update" \
  8 "View Recent Logs" \
  9 "Show Last update log" \
  10 "Exit" \
  3>&1 1>&2 2>&3)

  case "$choice" in
  1) view_threatlist ;;
  2) search_threatlist ;;
  3) add_ip ;;
  4) remove_ip ;;
  5) edit_feeds ;;
  6) run_update ;;
  7) toggle_cron ;;
  8) view_logs ;;
  9) show_last_run ;;
  10|*) clear; exit 0 ;;
esac

  done
}

main_menu
