#!/bin/bash

CONFIG_FILE="/etc/suricata/suricata.yaml"
EDITOR="${EDITOR:-vi}"
REQUIRED_BINARIES=(yq suricata-update nft)

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
  if [[ -n "$current_rule" ]]; then
    yesno_box "Inline mode is currently ENABLED.\n\nWould you like to DISABLE inline mode (bypass)?"
    if [[ $? -eq 0 ]]; then
      nft delete rule inet filter forward handle $(nft list chain inet filter forward | grep -B1 'queue num' | head -1 | awk '{print $NF}')
      msg_box "Mode Switched" "Suricata is now in BYPASS mode."
    fi
  else
    yesno_box "Inline mode is currently DISABLED.\n\nWould you like to ENABLE inline mode?"
    if [[ $? -eq 0 ]]; then
      nft add rule inet filter forward ip protocol tcp queue num 0
      nft add rule inet filter forward ip protocol udp queue num 0
      msg_box "Mode Switched" "Suricata is now in INLINE mode using NFQUEUE."
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

# ===== Main Menu =====
main_menu() {
  while true; do
    choice=$(dialog --clear --title "Suricata Admin Menu" --menu "Choose an option:" 20 60 10 \
      1 "Edit Config (Field-by-Field)" \
      2 "Edit Config Manually" \
      3 "Manage Rule Sources" \
      4 "View Logs" \
      5 "Service Control" \
      6 "Toggle Inline/Bypass Mode" \
      7 "Exit" \
      3>&1 1>&2 2>&3)

    case "$choice" in
      1) edit_config_fields ;;
      2) edit_config_manually ;;
      3) manage_sources ;;
      4) view_logs ;;
      5) service_control ;;
      6) toggle_inline_mode ;;
      7|*) clear; exit 0 ;;
    esac
  done
}

main_menu
