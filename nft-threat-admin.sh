#!/bin/bash
########COMPLETE################
THREAT_SCRIPT="/usr/local/bin/update_nft_threatlist.sh"
BLOCK_SET_NAME="threat_block"
NFTABLES_TABLE="inet filter"
NFTABLES_CHAIN="input"
THREAT_FEEDS_FILE="/etc/nft-threatlist-feeds.txt"
LOGFILE="/var/log/nft-threatlist.log"
MANUAL_BLOCK_LIST="/etc/nft-threat-list/manual_block_list.txt"
MANUAL_BLOCK_LIST_V6="/etc/nft-threat-list/manual_block_list_v6.txt"

EDITOR="${EDITOR:-vi}"

# ===== CLI Argument Parsing =====
if [[ $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --add-ip)
        shift
        NEW_IP="$1"
        shift
        if [[ "$1" == "--v6" ]]; then
          # IPv6 handling
          if ! grep -qxF "$NEW_IP" "$MANUAL_BLOCK_LIST_V6"; then
            echo "$NEW_IP" >> "$MANUAL_BLOCK_LIST_V6"
          else
            echo "[INFO] $NEW_IP already in manual block list."
          fi

          if ! nft list set inet filter threat_block_v6 | grep -q "$NEW_IP"; then
            nft add element inet filter threat_block_v6 { $NEW_IP } 2>/dev/null
            logger -t "$LOG_TAG" "Added $NEW_IP to threat_block_v6 (manual)"
            echo "[SUCCESS] $NEW_IP added to threatlist."
          else
            echo "[SKIPPED] $NEW_IP is already present in threat_block_v6 set."
          fi
        else
          # IPv4 handling
          if ! grep -qxF "$NEW_IP" "$MANUAL_BLOCK_LIST"; then
            echo "$NEW_IP" >> "$MANUAL_BLOCK_LIST"
          else
            echo "[INFO] $NEW_IP already in manual block list."
          fi

          if ! nft list set inet filter threat_block | grep -q "$NEW_IP"; then
            nft add element inet filter threat_block { $NEW_IP } 2>/dev/null
            logger -t "$LOG_TAG" "Added $NEW_IP to threat_block (manual)"
            echo "[SUCCESS] $NEW_IP added to threatlist."
          else
            echo "[SKIPPED] $NEW_IP is already present in threat_block set."
          fi
        fi
        exit 0
        ;;
      *)
        echo "[ERROR] Unknown option: $1"
        exit 1
        ;;
    esac
  done
fi

# ===== Dialog Helpers =====
msg_box() { dialog --title "$1" --msgbox "$2" 8 60; }
input_box() {
  dialog --inputbox "$2" 10 60 "$3" 2>"$TEMP_INPUT"
  result=$?
  [[ $result -ne 0 ]] && return 1
  INPUT=$(<"$TEMP_INPUT")
  return 0
}
# ==== Show all Temp Blocks in NFT =======
view_temp_blocks() {
  local TMP=$(mktemp)
  local BLOCK_SET_NAME="threat_block"
  local BLOCK_SET_NAME_V6="threat_block_v6"

  parse_set_raw() {
    local set_name="$1"
    nft list set inet filter "$set_name" 2>/dev/null | \
      sed -n '/elements = {/,/}/p' | tr ',' '\n' | \
      grep 'timeout' | \
      sed -E 's/(expires [^,]+).*/\1/' || echo "  (none)"
  }

  {
    echo "Active Temporary Blocks"
    echo "────────────────────────────────────────────────────────────────────────────"
    echo "IPv4:"
    parse_set_raw "$BLOCK_SET_NAME"
    echo ""
    echo "IPv6:"
    parse_set_raw "$BLOCK_SET_NAME_V6"
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────"
    echo "Each line shows: IP timeout duration and remaining expires time only."
  } > "$TMP"

  dialog --title "Temporary Threat Blocks" --textbox "$TMP" 26 105
  rm -f "$TMP"
}

# ===== View Current IPs =====
view_threatlist() {
  local tmp=$(mktemp)
  local BLOCK_SET_NAME_V6="threat_block_v6"

  # Extract IPv4 addresses
  mapfile -t ipv4_list < <(
    nft list set inet filter "$BLOCK_SET_NAME" 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u
  )

  # Extract IPv6 addresses
  mapfile -t ipv6_list < <(
    nft list set inet filter "$BLOCK_SET_NAME_V6" 2>/dev/null | \
    grep -oE '([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}' | sort -u
  )

  local count_v4=${#ipv4_list[@]}
  local count_v6=${#ipv6_list[@]}
  local total=$((count_v4 + count_v6))

  {
    echo "Current Threat Blocked IPs"
    echo "────────────────────────────────────────────────────────────────────────────"
    printf " ✅ IPv4: %d\t ✅ IPv6: %d\t Total: %d\n" "$count_v4" "$count_v6" "$total"
    echo ""
    echo "===== IPv4 ====="
    if (( count_v4 > 0 )); then
      printf "%s\n" "${ipv4_list[@]}"
    else
      echo "(none)"
    fi
    echo ""
    echo "===== IPv6 ====="
    if (( count_v6 > 0 )); then
      printf "%s\n" "${ipv6_list[@]}"
    else
      echo "(none)"
    fi
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────"
    printf " ✅ IPv4: %d\t ✅ IPv6: %d\t Total: %d\n" "$count_v4" "$count_v6" "$total"
  } > "$tmp"

  dialog --title "Blocked IPs (IPv4 + IPv6)" --textbox "$tmp" 26 105
  rm -f "$tmp"
}

# ===== Search for IP =====
search_threatlist() {
  local TMP_INPUT=$(mktemp)
  local ip_list_v4=$(mktemp)
  local ip_list_v6=$(mktemp)
  local match_result=$(mktemp)
  local BLOCK_SET_NAME_V6="threat_block_v6"

  # Step 1: Choose action
  dialog --title "Threatlist Search Menu" --menu "Choose an action:" 12 60 3 \
    1 "Search IP in Blocklist" \
    2 "Add IP to Blocklist" \
    3 "Remove IP from Blocklist" 2>"$TMP_INPUT"
  local action=$(<"$TMP_INPUT")
  rm -f "$TMP_INPUT"
  [[ -z "$action" ]] && return

  # Step 2: IP input
  dialog --inputbox "Enter full or partial IP (e.g. 192.168. or 2001:db8::):" 10 60 2>"$TMP_INPUT"
  local query=$(<"$TMP_INPUT")
  rm -f "$TMP_INPUT"
  [[ -z "$query" ]] && return

  # Step 3: Route to add/remove if chosen
  case "$action" in
    2) add_ip "$query"; return ;;
    3) remove_ip "$query"; return ;;
  esac

  # Step 4: Run search
  nft list set inet filter "$BLOCK_SET_NAME" 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u > "$ip_list_v4"

  nft list set inet filter "$BLOCK_SET_NAME_V6" 2>/dev/null | \
    grep -oEi '([0-9a-f]{1,4}:){1,7}[0-9a-f]{1,4}' | sort -u > "$ip_list_v6"

  {
    echo "Search: $query"
    echo "────────────────────────────────────────────────────────────────────────────"
    echo "IPv4 Matches:"
    grep -iF "$query" "$ip_list_v4" || echo "(none)"
    echo ""
    echo "IPv6 Matches:"
    grep -iF "$query" "$ip_list_v6" || echo "(none)"
  } > "$match_result"

  dialog --title "Search Results for '$query'" --textbox "$match_result" 22 90

  rm -f "$ip_list_v4" "$ip_list_v6" "$match_result"
}



# ===== Manually Add IP =====
add_ip() {
  local ip="$1"

  if [[ -z "$ip" ]]; then
    local TEMP_INPUT=$(mktemp)
    input_box "Add IP" "Enter IP or CIDR to block (IPv4 or IPv6):" "" || return
    ip="$INPUT"
    rm -f "$TEMP_INPUT"
  fi

  local ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$'
  local ipv6_regex='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?$'
  local list_file="" nft_set="" timeout_arg=""

  if [[ "$ip" =~ $ipv4_regex ]]; then
    list_file="$MANUAL_BLOCK_LIST"
    nft_set="threat_block"
  elif [[ "$ip" =~ $ipv6_regex ]]; then
    list_file="$MANUAL_BLOCK_LIST_V6"
    nft_set="threat_block_v6"
  else
    msg_box "Invalid IP" "'$ip' is not a valid IPv4 or IPv6 address (with optional CIDR)."
    return
  fi

  # Check for duplicate in list file
  if grep -qxF "$ip" "$list_file"; then
    msg_box "Already Exists" "$ip is already in the manual block list."
    return
  fi

  # Check if IP already exists in nft set
  if nft list set inet filter "$nft_set" | grep -q "$ip"; then
    msg_box "Already Blocked" "$ip is already in the nftables $nft_set set."
    return
  fi

  # Prompt for permanent or temporary block
  dialog --title "Block Type" --menu "Block type for $ip:" 10 60 2 \
    1 "Permanent (default)" \
    2 "Temporary (prompt for timeout duration)" 2>/tmp/block_choice
  local block_choice=$(< /tmp/block_choice)
  rm -f /tmp/block_choice

  if [[ "$block_choice" == "2" ]]; then
    dialog --inputbox "Enter timeout (e.g. 10m, 1h, 2d):" 8 40 "1h" 2>/tmp/block_timeout
    local user_timeout=$(< /tmp/block_timeout)
    rm -f /tmp/block_timeout
    if [[ -n "$user_timeout" ]]; then
      timeout_arg=" timeout $user_timeout"
    fi
  fi

  if nft add element inet filter "$nft_set" { "$ip$timeout_arg" } 2>/dev/null; then
    echo "$ip" >> "$list_file"
    echo "[$(date)] Added $ip to $nft_set (manual block)$timeout_arg" >> "$LOGFILE"
    msg_box "Success" "$ip was added to $nft_set${timeout_arg:+ with timeout $user_timeout}."
  else
    msg_box "nftables Error" "Failed to add '$ip' to $nft_set."
  fi
}

# ===== Manually Remove IP =====
remove_ip() {
  local ip="$1"

  if [[ -z "$ip" ]]; then
    local TEMP_INPUT=$(mktemp)
    input_box "Remove IP" "Enter IP to remove from blocklist:" "" || return
    ip="$INPUT"
    rm -f "$TEMP_INPUT"
  fi

  ip=$(echo "$ip" | xargs)  # Trim whitespace

  if grep -qE "^\s*${ip}\s*$" /etc/nft-threat-list/manual_block_list.txt; then
    grep -vE "^\s*${ip}\s*$" /etc/nft-threat-list/manual_block_list.txt > /tmp/filtered_blocklist && \
    mv /tmp/filtered_blocklist /etc/nft-threat-list/manual_block_list.txt
    nft delete element inet filter threat_block { $ip } 2>/dev/null
    echo "[$(date)] Removed $ip from manual block list" >> "$LOGFILE"
    msg_box "Removed" "$ip removed from manual block list and nftables."
  elif grep -qE "^\s*${ip}\s*$" /etc/nft-threat-list/manual_block_list_v6.txt; then
    grep -vE "^\s*${ip}\s*$" /etc/nft-threat-list/manual_block_list_v6.txt > /tmp/filtered_blocklist_v6 && \
    mv /tmp/filtered_blocklist_v6 /etc/nft-threat-list/manual_block_list_v6.txt
    nft delete element inet filter threat_block_v6 { $ip } 2>/dev/null
    echo "[$(date)] Removed $ip from manual block list (v6)" >> "$LOGFILE"
    msg_box "Removed" "$ip removed from manual v6 block list and nftables."
  else
    msg_box "Not Found" "$ip was not found in the manual block lists."
  fi
}



# ===== EDIT FEEDS =====
edit_feeds() {
  local FEED_DIR="/etc/nft-threat-list"
  local FEEDS_V4="$FEED_DIR/feeds-v4.list"
  local FEEDS_V6="$FEED_DIR/feeds-v6.list"
  local TMP_EDIT=$(mktemp)
  local TMP_FINAL=$(mktemp)

  local choice
  dialog --menu "Select which feed list to edit:" 12 50 2 \
    "IPv4" "Edit IPv4 feed list" \
    "IPv6" "Edit IPv6 feed list" 2>"$TMP_EDIT"

  choice=$(<"$TMP_EDIT")
  rm -f "$TMP_EDIT"

  [[ -z "$choice" ]] && msg_box "Cancelled" "Feed edit cancelled." && return

  local TARGET_FILE
  [[ "$choice" == "IPv4" ]] && TARGET_FILE="$FEEDS_V4"
  [[ "$choice" == "IPv6" ]] && TARGET_FILE="$FEEDS_V6"

  [[ ! -f "$TARGET_FILE" ]] && touch "$TARGET_FILE"

  cp "$TARGET_FILE" "${TARGET_FILE}.bak.$(date +%Y%m%d%H%M%S)"

  dialog --editbox "$TARGET_FILE" 20 70 2>"$TMP_FINAL"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    if [[ ! -s "$TMP_FINAL" ]]; then
      msg_box "Empty Feed List" "Feed list cannot be empty. Keeping original."
    else
      cp "$TMP_FINAL" "$TARGET_FILE"
      msg_box "Feed Updated" "$choice feed list updated successfully."
    fi
  else
    msg_box "Cancelled" "No changes made to $choice feed list."
  fi

  rm -f "$TMP_FINAL"
}

# ===== Run Update Script =====
run_update() {
  local TMP_LOG="/tmp/threatlist-update.log"
  local TMP_SYSLOG=$(mktemp)
  local DEBUG_LOG="/var/log/nft-threatlist-debug.log"
  local UPDATE_TAG="nft-threat-list"
  local START_TIME=$(date --date='1 minute ago' '+%Y-%m-%d %H:%M:%S')

  echo "[DEBUG] ===== run_update() started at $(date) =====" >> "$DEBUG_LOG"
  echo "[DEBUG] Using THREAT_SCRIPT=$THREAT_SCRIPT" >> "$DEBUG_LOG"
  : > "$TMP_LOG"

  # Staged, readable progress bar — script launched *inside* so we can wait safely
  {
    echo 10
    echo "XXX"
    echo "Initializing update..."
    echo "XXX"
    sleep 0.5

    echo 30
    echo "XXX"
    echo "Downloading threat feeds..."
    echo "XXX"
    sleep 0.5

    echo 50
    echo "XXX"
    echo "Parsing and validating IPs..."
    echo "XXX"
    sleep 0.5

    echo 70
    echo "XXX"
    echo "Applying blocks to nftables..."
    echo "XXX"

    # Launch and wait inside gauge block
    "$THREAT_SCRIPT" >"$TMP_LOG" 2>&1
    echo 100
    echo "XXX"
    echo "Finalizing..."
    echo "XXX"
    sleep 0.3
  } | dialog --title "Updating Threat List" --gauge "Starting..." 10 70 0

  # Pull fresh logs from journal
  journalctl -t "$UPDATE_TAG" --since "$START_TIME" --no-pager > "$TMP_SYSLOG"

  # Parse results
  local v4_count v6_count fail_count
  v4_count=$(grep -oP 'IPv4 threat list update complete: \K[0-9]+' "$TMP_SYSLOG" || echo "0")
  v6_count=$(grep -oP 'IPv6 threat list update complete: \K[0-9]+' "$TMP_SYSLOG" || echo "0")
  fail_count=$(grep -c "\[WARN\] Failed to download" "$TMP_SYSLOG" || echo "0")

  {
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────"
    printf " ✅ IPv4: %s IPs | ✅ IPv6: %s IPs | ⚠️  Failed Feeds: %s\n" "$v4_count" "$v6_count" "$fail_count"
  } >> "$TMP_SYSLOG"

  dialog --title "Threat List Update Log" --textbox "$TMP_SYSLOG" 26 105

  {
    echo ""
    echo "[DEBUG] Last 200 lines of TMP_LOG:"
    tail -n 200 "$TMP_LOG"
    echo ""
    echo "[DEBUG] Contents of TMP_SYSLOG:"
    cat "$TMP_SYSLOG"
    echo "[DEBUG] ===== run_update() ended at $(date) ====="
  } >> "$DEBUG_LOG"

  rm -f "$TMP_SYSLOG" "$TMP_LOG"
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
  local cron_file="/etc/cron.d/nft-threatlist"

  dialog --title "Threat List Cron" --menu "Enable or disable auto-update?" 10 50 2 \
    1 "Enable (schedule auto-update)" \
    2 "Disable (remove cron job)" 2>/tmp/cron_action
  local action=$(< /tmp/cron_action)
  rm -f /tmp/cron_action

  if [[ "$action" == "2" ]]; then
    if [[ -f "$cron_file" ]]; then
      rm -f "$cron_file"
      msg_box "Cron Disabled" "Auto-update cron job disabled."
    else
      msg_box "Already Disabled" "No cron job was found."
    fi
    return
  fi

  dialog --title "Schedule Time" --menu "Select schedule time format:" 12 60 3 \
    1 "Default: 3:30 AM" \
    2 "Custom (12-hour e.g. 3:30 PM)" \
    3 "Custom (24-hour e.g. 15:30)" 2>/tmp/cron_time_choice
  local time_choice=$(< /tmp/cron_time_choice)
  rm -f /tmp/cron_time_choice

  local hour="3"
  local min="30"

  if [[ "$time_choice" == "2" ]]; then
    dialog --inputbox "Enter time (e.g. 3:30 PM or 07:15 am):" 8 45 "03:30 AM" 2>/tmp/cron_time
    local user_input=$(< /tmp/cron_time)
    rm -f /tmp/cron_time

    # Normalize
    user_input=$(echo "$user_input" | tr '[:lower:]' '[:upper:]' | sed 's/ *AM/ AM/; s/ *PM/ PM/')

    if [[ ! "$user_input" =~ ^([0]?[1-9]|1[0-2]):[0-5][0-9]\ (AM|PM)$ ]]; then
      msg_box "Invalid Format" "Time must be in HH:MM AM/PM format (e.g., 9:15 PM or 03:30 AM)."
      return
    fi

    IFS=' :' read -r h m period <<< "$user_input"

    if [[ "$period" == "AM" ]]; then
      hour=$((10#$h % 12))
    else
      hour=$(( (10#$h % 12) + 12 ))
    fi
    min=$((10#$m))

  elif [[ "$time_choice" == "3" ]]; then
    dialog --inputbox "Enter 24-hour time (e.g. 15:30):" 8 40 "15:30" 2>/tmp/cron_time
    local user_input=$(< /tmp/cron_time)
    rm -f /tmp/cron_time

    if [[ ! "$user_input" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      msg_box "Invalid Format" "Time must be in HH:MM (24-hour) format."
      return
    fi

    IFS=: read -r hour min <<< "$user_input"
    hour=$((10#$hour))
    min=$((10#$min))
  fi

  # Final sanity check
  if [[ $hour -lt 0 || $hour -gt 23 || $min -lt 0 || $min -gt 59 ]]; then
    msg_box "Invalid Time" "Hour or minute is outside valid range for cron."
    return
  fi

  echo "$min $hour * * * root $THREAT_SCRIPT" > "$cron_file"
  chmod 644 "$cron_file"

  # Display time in user-friendly format
  local suffix="AM"
  local display_hour=$hour
  if (( hour == 0 )); then
    display_hour=12
  elif (( hour >= 12 )); then
    suffix="PM"
    (( hour > 12 )) && display_hour=$((hour - 12))
  fi

  msg_box "Cron Enabled" "Auto-update scheduled daily at $(printf "%d:%02d %s" "$display_hour" "$min" "$suffix")."
}

# ===== View Logs =====
view_logs() {
  local MSG_LOG="/var/log/messages"
  local TMP_BLOCK=$(mktemp)
  local TMP_FINAL=$(mktemp)
  local UPDATE_TAG="nft-threat-list"

  # Get last 4 update start lines in log order (already chronological)
  local start_lines
  mapfile -t start_lines < <(grep -n "$UPDATE_TAG.*Starting threat list update..." "$MSG_LOG" | tail -n 4 | cut -d: -f1)

  if [[ ${#start_lines[@]} -eq 0 ]]; then
    dialog --title "Last Runs" --msgbox "No threat list updates found in /var/log/messages." 8 60
    return
  fi

  > "$TMP_FINAL"

  for line in "${start_lines[@]}"; do
    # Extract up to 40 lines for this update
    sed -n "${line},+40p" "$MSG_LOG" | grep "$UPDATE_TAG" > "$TMP_BLOCK"

    # Parse timestamps and duration
    local timestamp time_start time_end duration_str
    timestamp=$(head -n1 "$TMP_BLOCK" | awk '{print $1, $2, $3}')
    time_start=$(head -n1 "$TMP_BLOCK" | awk '{print $3}')
    time_end=$(tail -n1 "$TMP_BLOCK" | awk '{print $3}')

    IFS=: read -r sh sm ss <<< "$time_start"
    IFS=: read -r eh em es <<< "$time_end"
    local start_sec=$((10#$sh * 3600 + 10#$sm * 60 + 10#$ss))
    local end_sec=$((10#$eh * 3600 + 10#$em * 60 + 10#$es))
    local duration_sec=$((end_sec - start_sec))
    [[ $duration_sec -lt 0 ]] && duration_sec=0

    if (( duration_sec >= 60 )); then
      local mins=$((duration_sec / 60))
      local secs=$((duration_sec % 60))
      duration_str="${mins}m ${secs}s"
    else
      duration_str="${duration_sec}s"
    fi

    # Extract stats
    local v4_count v6_count fail_count
    v4_count=$(grep -oP 'IPv4 threat list update complete: \K[0-9]+' "$TMP_BLOCK" || echo "0")
    v6_count=$(grep -oP 'IPv6 threat list update complete: \K[0-9]+' "$TMP_BLOCK" || echo "0")
    fail_count=$(grep -c "\[WARN\] Failed to download" "$TMP_BLOCK" || echo "0")

    # Build section
    {
      echo "Update: $timestamp (Duration: $duration_str)"
      echo "────────────────────────────────────────────────────────────────────────────"
      sed 's/^[A-Z][a-z]\{2\} [ 0-9][0-9] [0-9:]\{8\} //' "$TMP_BLOCK"
      echo ""
      echo "────────────────────────────────────────────────────────────────────────────"
      printf " ✅ IPv4: %s IPs | ✅ IPv6: %s IPs | ⚠️  Failed Feeds: %s\n" "$v4_count" "$v6_count" "$fail_count"
      echo ""
      echo ""
    } >> "$TMP_FINAL"
  done

  dialog --title "Last 4 Threat List Runs" --textbox "$TMP_FINAL" 26 105
  rm -f "$TMP_BLOCK" "$TMP_FINAL"
}

# ===== Show Last run  =====
show_last_run() {
  local MSG_LOG="/var/log/messages"
  local TMP_LOG=$(mktemp)
  local TMP_FINAL=$(mktemp)
  local UPDATE_TAG="nft-threat-list"

  # Find last 'start' line
  local start_line
  start_line=$(grep -n "$UPDATE_TAG.*Starting threat list update..." "$MSG_LOG" | tail -n1 | cut -d: -f1)

  if [[ -z "$start_line" ]]; then
    dialog --title "Last Run" --msgbox "No previous threat list update found in /var/log/messages." 8 60
    return
  fi

  # Extract log block: 20 lines max
  sed -n "${start_line},+20p" "$MSG_LOG" | grep "$UPDATE_TAG" > "$TMP_LOG"

  # Extract timestamp from first + last log lines
  local time_start time_end
  time_start=$(head -n1 "$TMP_LOG" | awk '{print $3}')
  time_end=$(tail -n1 "$TMP_LOG" | awk '{print $3}')

  # Convert HH:MM:SS to seconds
  IFS=: read -r sh sm ss <<< "$time_start"
  IFS=: read -r eh em es <<< "$time_end"
  local start_sec=$((10#$sh * 3600 + 10#$sm * 60 + 10#$ss))
  local end_sec=$((10#$eh * 3600 + 10#$em * 60 + 10#$es))
  local duration_sec=$((end_sec - start_sec))
  [[ $duration_sec -lt 0 ]] && duration_sec=0

  local duration_str="${duration_sec}s"
  if (( duration_sec >= 60 )); then
    local mins=$((duration_sec / 60))
    local secs=$((duration_sec % 60))
    duration_str="${mins}m ${secs}s"
  fi

  # Get full timestamp for header
  local timestamp
  timestamp=$(head -n1 "$TMP_LOG" | awk '{print $1, $2, $3}')

  # Count IPs and failures
  local v4_count v6_count fail_count
  v4_count=$(grep -oP 'IPv4 threat list update complete: \K[0-9]+' "$TMP_LOG" || echo "0")
  v6_count=$(grep -oP 'IPv6 threat list update complete: \K[0-9]+' "$TMP_LOG" || echo "0")
  fail_count=$(grep -c "\[WARN\] Failed to download" "$TMP_LOG" || echo "0")

  # Build final output
  {
    echo "Last Threat List Update: $timestamp (Duration: $duration_str)"
    echo "────────────────────────────────────────────────────────────────────────────"
    sed 's/^[A-Z][a-z]\{2\} [ 0-9][0-9] [0-9:]\{8\} //' "$TMP_LOG"
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────"
    printf " ✅ IPv4: %s IPs | ✅ IPv6: %s IPs | ⚠️  Failed Feeds: %s\n" "$v4_count" "$v6_count" "$fail_count"
  } > "$TMP_FINAL"

  dialog --title "Last Threat List Run" --textbox "$TMP_FINAL" 26 105

  rm -f "$TMP_LOG" "$TMP_FINAL"
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
  2 "View Temporary Blocks" \
  3 "Search IP's in Threatlist" \
  4 "Manually Add IP to Blocklist" \
  5 "Manually Remove IP" \
  6 "Edit Feed URLs" \
  7 "Run Full Threatlist Update" \
  8 "Enable/Disable Daily Auto-Update" \
  9 "View Recent Logs" \
  10 "Show Last update log" \
  11 "Exit" \
  3>&1 1>&2 2>&3)

  case "$choice" in
  1) view_threatlist ;;
  2) view_temp_blocks ;;
  3) search_threatlist ;;
  4) add_ip ;;
  5) remove_ip ;;
  6) edit_feeds ;;
  7) run_update ;;
  8) toggle_cron ;;
  9) view_logs ;;
  10) show_last_run ;;
  11|*) clear; exit 0 ;;
esac

  done
}

main_menu
