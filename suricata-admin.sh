#!/bin/bash

CONFIG_FILE="/etc/suricata/suricata.yaml"
EDITOR="${EDITOR:-vi}"
LOGFILE="/var/log/suricata-mode.log"
REQUIRED_BINARIES=(yq suricata-update nft nmcli)

# ===== Dependency Check =====
for bin in "${REQUIRED_BINARIES[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    echo "[ERROR] Missing required binary: $bin"
    exit 1
  fi
done

# ===== Dialog Helpers =====
input_box() {
  dialog --clear --inputbox "$2" 10 60 "$3" 2>"$TEMP_INPUT"
  result=$?
  if [ $result -eq 1 ]; then return 1; fi
  INPUT=$(<"$TEMP_INPUT")
  return 0
}

msg_box() {
  dialog --title "$1" --msgbox "$2" 8 60
}

yesno_box() {
  dialog --yesno "$1" 7 50
  return $?
}

# ===== Detect Outside Interface =====
find_interface() {
  local suffix="$1"
  nmcli -t -f DEVICE,CONNECTION device status | awk -F: -v suffix="$suffix" '$2 ~ suffix {print $1}'
}

OUTSIDE_INTERFACE=$(find_interface "-outside")
if [[ -z "$OUTSIDE_INTERFACE" ]]; then
  echo "[ERROR] No outside interface found (suffix -outside)."
  exit 1
fi

# ===== Field-by-Field Config Editor (via yq) =====
edit_config_fields() {
  TEMP_INPUT=$(mktemp)
  KEYS=( $(yq eval 'paths | join(".")' "$CONFIG_FILE") )

  while true; do
    menu_items=()
    for key in "${KEYS[@]}"; do
      value=$(yq eval ".$key" "$CONFIG_FILE")
      menu_items+=( "$key" "$value" )
    done
    menu_items+=( "save" "Save changes and exit" "back" "Cancel editing" )

    choice=$(dialog --clear --title "Suricata Config Editor" --menu "Select a field to edit:" 25 80 15 "${menu_items[@]}" 3>&1 1>&2 2>&3)

    case "$choice" in
      back|"") break ;;
      save)
        yesno_box "Save the modified configuration to $CONFIG_FILE?" || continue
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$CONFIG_FILE" "$TEMP_INPUT" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        msg_box "Success" "Configuration saved."
        break
        ;;
      *)
        current=$(yq eval ".$choice" "$CONFIG_FILE")
        input_box "$choice" "Current value: $current\nEnter new value:" "$current" || continue
        yq eval ".$choice = \"$INPUT\"" "$CONFIG_FILE" > "$TEMP_INPUT"
        ;;
    esac
  done

  rm -f "$TEMP_INPUT"
}

# ===== Manual Config Edit =====
edit_config_manually() {
  tmp=$(mktemp)
  cp "$CONFIG_FILE" "$tmp"
  out=$(mktemp)

  exec 3>&1; set +e
  dialog --clear --title "Editing Suricata Config" --editbox "$tmp" 25 80 2>"$out" 1>&3
  rc=$?; set -e; exec 3>&-
  rm -f "$tmp"

  [ $rc -ne 0 ] && { rm -f "$out"; return; }

  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$out" "$CONFIG_FILE"
  msg_box "Success" "Configuration updated."
}

# ===== Rule Category Toggle =====
manage_categories() {
  tmp=$(mktemp)
  enabled=$(suricata-update list-enabled | awk '{print $1}')
  disabled=$(suricata-update list-disabled | awk '{print $1}')
  sources=$(suricata-update list-sources)

  checklist=()
  for cat in $enabled; do
    desc=$(echo "$sources" | grep "^$cat" | cut -d' ' -f2-)
    checklist+=("$cat" "$desc (Enabled)" on)
  done
  for cat in $disabled; do
    desc=$(echo "$sources" | grep "^$cat" | cut -d' ' -f2-)
    checklist+=("$cat" "$desc (Disabled)" off)
  done

  exec 3>&1
  selections=$(dialog --clear --checklist "Enable/Disable Rule Categories:" 25 80 15 \
    "${checklist[@]}" 2>&1 1>&3)
  exec 3>&-

  [[ -z "$selections" ]] && return

  for cat in $enabled; do
    if ! grep -qw "$cat" <<< "$selections"; then
      suricata-update disable-source "$cat"
    fi
  done
  for cat in $disabled; do
    if grep -qw "$cat" <<< "$selections"; then
      suricata-update enable-source "$cat"
    fi
  done

  suricata-update

  # Confirm rule application
  updated_rules=$(ls -l /var/lib/suricata/rules/suricata.rules 2>/dev/null | wc -l)
  if [[ $updated_rules -gt 0 ]]; then
    msg_box "Update Complete" "Rule categories updated and ruleset applied."
  else
    msg_box "Warning" "Update may have failed. Please check the rules directory."
  fi
}

# ===== Manage Rule Sources =====
manage_sources() {
  suricata-update list-sources | dialog --title "Available Rule Sources" --textbox - 25 80
}

# ===== View Logs =====
view_logs() {
  log_file="/var/log/suricata/fast.log"
  if [[ -f "$log_file" ]]; then
    dialog --title "Suricata Logs" --textbox "$log_file" 25 100
  else
    msg_box "Log Not Found" "Suricata log file not found at $log_file"
  fi
}

# ===== Toggle Inline/Bypass Mode =====
toggle_inline_mode() {
  current_rule=$(nft list chain inet filter forward 2>/dev/null | grep 'queue num' || true)
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -n "$current_rule" ]]; then
    yesno_box "Inline mode is currently ENABLED.

Would you like to DISABLE inline mode (bypass)?"
    if [[ $? -eq 0 ]]; then
      nft delete rule inet filter forward handle $(nft list chain inet filter forward | grep -B1 'queue num' | head -1 | awk '{print $NF}')
      yq -i 'del(.af-packet)' "$CONFIG_FILE"
      echo "$timestamp - Set to BYPASS mode (removed NFQUEUE rules)." >> "$LOGFILE"
      systemctl restart suricata
      msg_box "Mode Switched" "Suricata is now in BYPASS mode. Service restarted."
    fi
  else
    yesno_box "Inline mode is currently DISABLED.

Would you like to ENABLE inline mode?"
    if [[ $? -eq 0 ]]; then
      nft add rule inet filter forward iif "$OUTSIDE_INTERFACE" ip protocol tcp queue num 0
      nft add rule inet filter forward iif "$OUTSIDE_INTERFACE" ip protocol udp queue num 0
      yq -i '.nfqueue += {"id": 0, "fail-open": true}' "$CONFIG_FILE"
      echo "$timestamp - Set to INLINE mode using NFQUEUE on $OUTSIDE_INTERFACE." >> "$LOGFILE"
      systemctl restart suricata
      msg_box "Mode Switched" "Suricata is now in INLINE mode on $OUTSIDE_INTERFACE. Service restarted."
    fi
  fi
    fi
  fi
}

# ===== Service Control =====
service_control() {
  while true; do
    choice=$(dialog --clear --title "Suricata Service Control" --menu "Select action:" 15 60 6 \
      start "Start Suricata" \
      stop "Stop Suricata" \
      restart "Restart Suricata" \
      status "View Suricata status" \
      back "Return to main menu" \
      3>&1 1>&2 2>&3)

    case "$choice" in
      start) systemctl start suricata && msg_box "Service" "Suricata started." ;;
      stop) systemctl stop suricata && msg_box "Service" "Suricata stopped." ;;
      restart) systemctl restart suricata && msg_box "Service" "Suricata restarted." ;;
      status)
        systemctl status suricata | tee /tmp/suri_status
        dialog --textbox /tmp/suri_status 20 80
        ;;
      back|*) break ;;
    esac
  done
}

# ===== Config Test Mode =====
config_test() {
  suricata -T -c "$CONFIG_FILE" > /tmp/suri_test 2>&1
  dialog --title "Suricata Config Test Output" --textbox /tmp/suri_test 25 100
}

# ===== EVE Stats Parser =====
view_stats_summary() {
  eve_file="/var/log/suricata/eve.json"
  if [[ ! -f "$eve_file" ]]; then
    msg_box "EVE File Missing" "$eve_file not found."
    return
  fi

  tmp_stats=$(mktemp)
  echo "Recent Suricata Alerts Summary:" > "$tmp_stats"
  jq -r 'select(.event_type == "alert") | .alert.category' "$eve_file" | sort | uniq -c | sort -rn >> "$tmp_stats"

  dialog --title "Suricata Alert Categories (EVE)" --textbox "$tmp_stats" 25 100
  rm -f "$tmp_stats"
}

# ===== Main Menu =====
main_menu() {
  # Detect current mode
  MODE="UNKNOWN"
  if nft list chain inet filter forward 2>/dev/null | grep -q 'queue num'; then
    MODE="INLINE"
  else
    MODE="BYPASS"
  fi
  while true; do
    choice=$(dialog --clear --title "Suricata Admin Menu [Mode: $MODE]" --menu "Choose an option:" 20 60 10 \
      1 "Edit Config (Field-by-Field)" \
      2 "Edit Config Manually" \
      3 "Manage Rule Categories" \
      10 "Manage Rule Sources" \
      4 "View Logs" \
      5 "Service Control" \
      6 "Toggle Inline/Bypass Mode" \
      7 "View Stats (EVE)" \
      8 "Test Config" \
      9 "Exit" \
      3>&1 1>&2 2>&3)

    case "$choice" in
      1) edit_config_fields ;;
      2) edit_config_manually ;;
      3) manage_categories ;;
      10) manage_sources ;;
      4) view_logs ;;
      5) service_control ;;
      6) toggle_inline_mode ;;
      7) view_stats_summary ;;
      8) config_test ;;
      9|*) clear; exit 0 ;;
    esac
  done
}

main_menu
