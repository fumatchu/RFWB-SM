#!/bin/bash

CONFIG_FILE="/etc/rfwb-qos.conf"
SERVICE_NAME="rfwb-qos"
EDITOR="${EDITOR:-vi}"

declare -A CONFIG_KEYS=(
  [percentage_bandwidth]="Bandwidth reservation %"
  [adjust_interval_hours]="Adjustment interval (hours)"
  [wifi_calling_ports]="Wi-Fi calling ports"
  [sip_ports]="SIP ports"
  [rtp_ports]="RTP port range"
  [rtsp_ports]="RTSP ports"
  [h323_port]="H.323 port"
  [webrtc_ports]="WebRTC port range"
  [mpeg_ts_port]="MPEG-TS port"
)

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
  dialog --title "$1" --yesno "$2" 8 60
  return $?
}

# ===== Load Config File =====
load_config() {
  declare -gA CONFIG_VALUES
  while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    CONFIG_VALUES[$key]="$value"
  done < "$CONFIG_FILE"
}

# ===== Save Config with Backup and Confirm =====
save_config_safely() {
  tmp=$(mktemp)
  {
    echo "# rfwb-qos Configuration"
    for key in "${!CONFIG_KEYS[@]}"; do
      echo "$key=${CONFIG_VALUES[$key]}"
    done
  } > "$tmp"

  yesno_box "Apply Changes?" "Save this configuration to $CONFIG_FILE?"
  [[ $? -ne 0 ]] && { rm -f "$tmp"; return; }

  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$tmp" "$CONFIG_FILE"
  msg_box "Success" "Configuration saved and backed up."
}

# ===== Field Validators =====
validate_percentage() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 0 ] && [ "$1" -le 100 ]
}
validate_interval() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}
validate_ports() {
  [[ "$1" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]
}
validate_single_port() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_field() {
  key="$1"; value="$2"
  case "$key" in
    percentage_bandwidth) validate_percentage "$value" ;;
    adjust_interval_hours) validate_interval "$value" ;;
    *_ports) validate_ports "$value" ;;
    h323_port|mpeg_ts_port) validate_single_port "$value" ;;
    *) return 1 ;;
  esac
}

# ===== Config Menu =====
edit_qos_settings() {
  TEMP_INPUT=$(mktemp)
  load_config

  while true; do
    menu_items=()
    for key in "${!CONFIG_KEYS[@]}"; do
      menu_items+=( "$key" "${CONFIG_KEYS[$key]} = ${CONFIG_VALUES[$key]}" )
    done
    menu_items+=( "save" "Save Config" "back" "Return to Main Menu" )

    choice=$(dialog --clear --title "Edit QoS Settings" --menu "Select setting to edit:" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)

    case "$choice" in
      back|"") break ;;
      save) save_config_safely ;;
      *)
        label="${CONFIG_KEYS[$choice]}"
        current="${CONFIG_VALUES[$choice]}"
        input_box "$label" "Current: $current\n\nEnter new value:" "$current" || continue

        if validate_field "$choice" "$INPUT"; then
          CONFIG_VALUES[$choice]="$INPUT"
          msg_box "Updated" "$label updated to: $INPUT"
        else
          msg_box "Invalid Input" "The value '$INPUT' is not valid for $label."
        fi
        ;;
    esac
  done

  rm -f "$TEMP_INPUT"
}

# ===== Edit Config File (Dialog-Based) =====
edit_qos_conf_dialog() {
  tmp=$(mktemp)
  cp "$CONFIG_FILE" "$tmp"
  out=$(mktemp)

  exec 3>&1; set +e
  dialog --clear --title "Editing QoS Config" --editbox "$tmp" 25 80 2>"$out" 1>&3
  rc=$?; set -e; exec 3>&-
  rm -f "$tmp"

  [ $rc -ne 0 ] && { rm -f "$out"; return; }

  yesno_box "Apply Changes?" "Apply edits to '$CONFIG_FILE'?"
  [[ $? -ne 0 ]] && { rm -f "$out"; return; }

  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$out" "$CONFIG_FILE"
  msg_box "Success" "Configuration updated."
}

# ===== QoS Stats Viewer =====
view_qos_stats() {
  iface=$(grep 'QoS applied on' /var/log/messages | tail -1 | awk '{print $NF}')
  if [[ -z "$iface" ]]; then
    msg_box "QoS Stats" "No interface found in logs. Cannot display stats."
    return
  fi

  tmp_stats=$(mktemp)
  if tc -s class show dev "$iface" > "$tmp_stats" 2>/dev/null; then
    dialog --title "QoS Stats for $iface" --textbox "$tmp_stats" 25 100
  else
    msg_box "QoS Stats" "Failed to retrieve stats for $iface. Interface may be inactive."
  fi
  rm -f "$tmp_stats"
}

# ===== Service Control =====
service_control() {
  while true; do
    choice=$(dialog --clear --title "QoS Service Control" --menu "Choose action:" 18 60 8 \
      start "Start rfwb-qos service" \
      stop "Stop rfwb-qos service" \
      restart "Restart service" \
      status "Show service status" \
      viewlog "View filtered syslog activity" \
      viewerr "View error log" \
      back "Return to main menu" \
      3>&1 1>&2 2>&3)

    case "$choice" in
      start) systemctl start "$SERVICE_NAME" && msg_box "Service" "QoS service started." ;;
      stop) systemctl stop "$SERVICE_NAME" && msg_box "Service" "QoS service stopped." ;;
      restart) systemctl restart "$SERVICE_NAME" && msg_box "Service" "QoS service restarted." ;;
      status)
        systemctl status "$SERVICE_NAME" | tee /tmp/qos_status
        dialog --textbox /tmp/qos_status 20 80
        ;;
      viewlog)
        tmp_log=$(mktemp)
        grep 'rfwb-qos\.sh' /var/log/messages | tail -n 100 > "$tmp_log"
        if [[ -s "$tmp_log" ]]; then
          dialog --title "rfwb-qos Activity Log (/var/log/messages)" --textbox "$tmp_log" 25 100
        else
          msg_box "No Entries Found" "No recent rfwb-qos.sh activity found in /var/log/messages."
        fi
        rm -f "$tmp_log"
        ;;
      viewerr)
        if [[ -f /var/log/rfwb-qos-errors.log ]]; then
          dialog --title "Error Log" --textbox /var/log/rfwb-qos-errors.log 20 80
        else
          msg_box "Log Not Found" "Error log file not found."
        fi
        ;;
      back|*) break ;;
    esac
  done
}

# ===== Main Menu =====
main_menu() {
  while true; do
    choice=$(dialog --clear --title "QoS Admin Menu" --menu "Choose an option:" 18 60 8 \
      1 "Edit QoS Settings (Menu)" \
      2 "Edit Config File (Dialog-Based)" \
      3 "QoS Service Control" \
      4 "Exit" \
      5 "View QoS Stats" \
      3>&1 1>&2 2>&3)

    case "$choice" in
      1) edit_qos_settings ;;
      2) edit_qos_conf_dialog ;;
      3) service_control ;;
      4) clear; exit 0 ;;
      5) view_qos_stats ;;
    esac
  done
}

main_menu
