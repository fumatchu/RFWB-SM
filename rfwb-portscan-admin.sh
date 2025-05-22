#!/bin/bash

CONF_FILE="/etc/rfwb/portscan.conf"
IGNORE_NETWORKS_FILE="/etc/nftables/ignore_networks.conf"
IGNORE_PORTS_FILE="/etc/nftables/ignore_ports.conf"
LOG_FILE="/var/log/rfwb-portscan.log"
THREATLIST_ADMIN="/usr/local/bin/nft-threatlist-admin.sh"

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

# ===== View Blocked IPs =====
view_blocked_ips() {
  tmp=$(mktemp)
  {
    echo "IPv4 Blocked:"
    nft list set inet portscan dynamic_block 2>/dev/null || echo "(none)"
    echo ""
    echo "IPv6 Blocked:"
    nft list set inet portscan dynamic_block_v6 2>/dev/null || echo "(none)"
  } > "$tmp"
  dialog --title "Blocked IPs" --textbox "$tmp" 25 80
  rm -f "$tmp"
}

# ===== Promote to nft-threatlist =====
promote_blocked_to_threatlist() {
  tmp=$(mktemp)
  {
    echo "# IPv4"
    nft list set inet portscan dynamic_block 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+'
    echo "# IPv6"
    nft list set inet portscan dynamic_block_v6 2>/dev/null | grep -oP '([0-9a-fA-F:]+:+)+[0-9a-fA-F]+'
  } | sort -u | grep -v '^#' > "$tmp"

  if [[ ! -s "$tmp" ]]; then
    msg_box "No IPs" "No dynamically blocked IPs found."
    rm -f "$tmp"
    return
  fi

  checklist=$(mktemp)
  while read -r ip; do
    echo "$ip" "" off
  done < "$tmp" > "$checklist"

  mapfile -t selected < <(dialog --separate-output --checklist "Select IPs to promote to nft-threatlist:" 25 70 20 \
    --file "$checklist" 3>&1 1>&2 2>&3)

  [[ ${#selected[@]} -eq 0 ]] && rm -f "$tmp" "$checklist" && return

  for ip in "${selected[@]}"; do
    if [[ $ip == *:* ]]; then
      "$THREATLIST_ADMIN" --add-ip "$ip" --v6
    else
      "$THREATLIST_ADMIN" --add-ip "$ip"
    fi
  done

  msg_box "Success" "Selected IPs promoted to threatlist."
  rm -f "$tmp" "$checklist"
}

# ===== View Logs =====
view_logs() {
  tmp=$(mktemp)
  journalctl -u rfwb-portscan -n 500 --no-pager > "$tmp" || echo "No logs found." > "$tmp"
  dialog --title "rfwb-portscan Logs" --textbox "$tmp" 25 100
  rm -f "$tmp"
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
      5) edit_file "$IGNORE_PORTS_FILE" ;;
      6) view_logs ;;
      7) service_control ;;
      8|*) clear; exit 0 ;;
    esac
  done
}

main_menu
