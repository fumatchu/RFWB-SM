#!/bin/bash

CONF_FILE="/etc/rfwb/portscan.conf"
IGNORE_NETWORKS_FILE="/etc/nftables/ignore_networks.conf"
IGNORE_PORTS_FILE="/etc/nftables/ignore_ports.conf"
LOG_FILE="/var/log/rfwb-portscan.log"
THREATLIST_ADMIN="/root/.rfwb-admin/nft-threat-admin.sh"

EDITOR="${EDITOR:-vi}"

# ===== Dialog Helpers =====
msg_box() { dialog --title "$1" --msgbox "$2" 10 70; }

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

# ===== View Blocked IP ====
view_blocked_ips() {
  tmp=$(mktemp)

  {
    echo "IPv4 Blocked:"
    nft list set inet filter dynamic_block 2>/dev/null | grep -oP '([0-9]{1,3}\.){3}[0-9]{1,3}' || echo "(none)"

    echo ""
    echo "IPv6 Blocked:"
    nft list set inet filter dynamic_block_v6 2>/dev/null | grep -oP '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' || echo "(none)"
  } > "$tmp"

  dialog --title "Blocked IPs (Dynamic)" --textbox "$tmp" 25 80
  rm -f "$tmp"
}
#==== Edit Ignore Ports ====
edit_ignore_ports_safe() {
  local PORT_FILE="/etc/nftables/ignore_ports.conf"
  local TMP_PORTS=$(mktemp)
  local TMP_VALID=$(mktemp)
  local BACKUP="${PORT_FILE}.bak.$(date +%Y%m%d%H%M%S)"

  [[ ! -f "$PORT_FILE" ]] && {
    echo "# Enter one TCP port per line (1–65535)" > "$PORT_FILE"
    echo "# This will be flattened into a single line for nftables" >> "$PORT_FILE"
    echo "22" >> "$PORT_FILE"
  }

  # Expand the line to 1 port per line
  grep -vE '^#' "$PORT_FILE" | tr ',' '\n' | sed 's/ //g' > "$TMP_PORTS"

  dialog --title "Edit Ignored Ports" --editbox "$TMP_PORTS" 20 60 2>"$TMP_VALID"
  local rc=$?
  [[ $rc -ne 0 ]] && { msg_box "Cancelled" "No changes made."; rm -f "$TMP_PORTS" "$TMP_VALID"; return; }

  local valid=true
  local flattened=()

  while IFS= read -r line; do
    line=$(echo "$line" | xargs)  # trim
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^[0-9]{1,5}$ ]] && (( line >= 1 && line <= 65535 )); then
      flattened+=("$line")
    else
      valid=false
      break
    fi
  done < "$TMP_VALID"

  if ! $valid; then
    msg_box "Invalid Input" "Only port numbers 1–65535 or comments are allowed.\nNo ranges or protocols."
    rm -f "$TMP_PORTS" "$TMP_VALID"
    return
  fi

  # Save and re-flatten to single-line format
  cp "$PORT_FILE" "$BACKUP"
  IFS=,; echo "${flattened[*]}" > "$PORT_FILE"
  unset IFS

  rm -f "$TMP_PORTS" "$TMP_VALID"

  # Restart service to apply changes
  systemctl restart rfwb-portscan 2>/dev/null
  if systemctl is-active --quiet rfwb-portscan; then
    msg_box "Success" "Ignored ports updated.\nService restarted successfully and rules are now live."
  else
    msg_box "Error" "Ports saved, but rfwb-portscan failed to restart.\nCheck logs with: journalctl -u rfwb-portscan"
  fi
}



# ===== CIDR-safe Edit for Ignore Networks (IPv4 + IPv6) =====
edit_ignore_networks_safe() {
  tmp=$(mktemp)
  cp "$IGNORE_NETWORKS_FILE" "$tmp"
  out=$(mktemp)
  cleaned=$(mktemp)

  dialog --title "Editing ignore_networks.conf" --editbox "$tmp" 25 80 2>"$out"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    msg_box "Cancelled" "Edit cancelled. No changes were made."
    rm -f "$tmp" "$out" "$cleaned"
    return
  fi

  # Step 1: Clean input
  awk 'NF' "$out" | sed 's/ *, */,/g' | sed 's/^,*//' | sed 's/,*$//' > "$cleaned"

  # Step 2: Validate using system routing logic
  invalid=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if [[ "$line" == *:* ]]; then
      ip -6 route get "$line" &>/dev/null || invalid+=("$line")
    else
      ip -4 route get "$line" &>/dev/null || invalid+=("$line")
    fi
  done < "$cleaned"

  if (( ${#invalid[@]} > 0 )); then
    err_list=$(printf "%s\n" "${invalid[@]}")
    msg_box "Invalid Entries" "The following lines are not valid IPv4/IPv6 CIDRs:\n\n$err_list"
    rm -f "$tmp" "$out" "$cleaned"
    return
  fi

  # Step 3: Save and restart
  if ! cmp -s "$IGNORE_NETWORKS_FILE" "$cleaned"; then
    cp "$cleaned" "$IGNORE_NETWORKS_FILE"
    systemctl restart rfwb-portscan && sleep 1
    if systemctl is-active --quiet rfwb-portscan; then
      msg_box "Updated" "ignore_networks.conf updated.\n\n[SUCCESS] rfwb-portscan is running."
    else
      msg_box "Error" "File saved, but rfwb-portscan failed to restart.\nCheck:\n  journalctl -u rfwb-portscan"
    fi
  else
    msg_box "No Changes" "No changes were made."
  fi

  rm -f "$tmp" "$out" "$cleaned"
}


# ===== Promote to nft-threatlist =====

promote_blocked_to_threatlist() {
  LOGFILE="/tmp/threatlist-promotion.log"
  echo "[DEBUG] ===== Starting RFWB Portscan Promotion at $(date) =====" > "$LOGFILE"

  THREATLIST_ADMIN="/root/.rfwb-admin/nft-threat-admin.sh"
  [[ ! -x "$THREATLIST_ADMIN" ]] && {
    msg_box "Error" "Threatlist admin script not found or not executable: $THREATLIST_ADMIN"
    echo "[ERROR] Missing or non-executable: $THREATLIST_ADMIN" >> "$LOGFILE"
    return
  }

  tmp=$(mktemp)
  checklist=$(mktemp)

  # Extract IPv4 and IPv6 IPs into checklist (no quotes)
  {
    nft list set inet filter dynamic_block 2>>"$LOGFILE" | grep -oP '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | while read -r ip; do
      echo "$ip IPv4_Block off"
    done
    nft list set inet filter dynamic_block_v6 2>>"$LOGFILE" | grep -oP '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | while read -r ip; do
      echo "$ip IPv6_Block off"
    done
  } | sort -u > "$checklist"

  echo "[DEBUG] Built checklist file:" >> "$LOGFILE"
  cat "$checklist" >> "$LOGFILE"

  if [[ ! -s "$checklist" ]]; then
    msg_box "No IPs" "No dynamically blocked IPs found by rfwb-portscan."
    echo "[DEBUG] No IPs found. Exiting." >> "$LOGFILE"
    rm -f "$tmp" "$checklist"
    return
  fi

  # Run dialog and parse user selections
  IFS=$'\n' read -rd '' -a selected < <(dialog --separate-output --checklist \
    "Select IPs from rfwb-portscan to promote to nft-threatlist:" 25 70 20 \
    $(<"$checklist") 3>&1 1>&2 2>&3)

  if [[ ${#selected[@]} -eq 0 ]]; then
    msg_box "Cancelled" "No IPs selected."
    echo "[DEBUG] No IPs selected. Exiting." >> "$LOGFILE"
    rm -f "$tmp" "$checklist"
    return
  fi

  for ip in "${selected[@]}"; do
    if [[ "$ip" == *:* ]]; then
      echo "[DEBUG] Promoting IPv6: $ip" >> "$LOGFILE"
      "$THREATLIST_ADMIN" --add-ip "$ip" --v6 >> "$LOGFILE" 2>&1
    else
      echo "[DEBUG] Promoting IPv4: $ip" >> "$LOGFILE"
      "$THREATLIST_ADMIN" --add-ip "$ip" >> "$LOGFILE" 2>&1
    fi
  done

  msg_box "Success" "Selected IPs promoted to nft-threatlist."
  echo "[DEBUG] Promotion complete." >> "$LOGFILE"
  rm -f "$tmp" "$checklist"
}

# ===== Service Control =====
service_control() {
  while true; do
    choice=$(dialog --title "Service Control" --menu "Choose action:" 15 60 5 \
      1 "Start rfwb-portscan" \
      2 "Stop rfwb-portscan" \
      3 "Restart rfwb-portscan" \
      4 "Status rfwb-portscan" \
      5 "Back" \
      3>&1 1>&2 2>&3)

    case $choice in
      1) systemctl start rfwb-portscan && msg_box "Started" "rfwb-portscan started." ;;
      2) systemctl stop rfwb-portscan && msg_box "Stopped" "rfwb-portscan stopped." ;;
      3) systemctl restart rfwb-portscan && msg_box "Restarted" "rfwb-portscan restarted." ;;
      4) systemctl status rfwb-portscan | tee /tmp/status && dialog --textbox /tmp/status 20 70 ;;
      5|*) break ;;
    esac
  done
}

# ===== Main Menu =====
main_menu() {
  while true; do
    choice=$(dialog --clear --title "rfwb-portscan Admin" --menu "Choose an option:" 25 60 10 \
      1 "View Blocked IPs (v4/v6)" \
      2 "Promote Blocked IPs to Threatlist" \
      3 "Edit Detection Settings" \
      4 "Edit Ignore Networks" \
      5 "Edit Ignore Ports" \
      6 "View Logs" \
      7 "Service Control" \
      8 "Exit" \
      3>&1 1>&2 2>&3)

    case $choice in
      1) view_blocked_ips ;;
      2) promote_blocked_to_threatlist ;;
      3) edit_file "$CONF_FILE" ;;
      4) edit_ignore_networks_safe ;;
      5) edit_ignore_ports_safe ;;
      6) view_logs ;;
      7) service_control ;;
      8|*) clear; exit 0 ;;
    esac
  done
}

main_menu
