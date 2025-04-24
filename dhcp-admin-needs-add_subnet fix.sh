#!/bin/bash
# Dialog helpers
input_box() {
    local backtitle="$1" title="$2" message="$3" default_value="$4"
    exec 3>&1
    result=$(dialog --clear --backtitle "$backtitle" --title "$title" \
                   --inputbox "$message" 8 40 "$default_value" 2>&1 1>&3)
    rc=$?;
    exec 3>&-
    [[ $rc -ne 0 ]] && return 1
    echo "$result"
}

msg_box() {
    dialog --clear --backtitle "$1" --title "$2" --msgbox "$3" 10 50
}

yesno_box() {
    dialog --clear --backtitle "$1" --title "$2" --yesno "$3" 8 40
    return $?
}
#================== CONFIG ==================#
CONFIG_FILE="/etc/kea/kea-dhcp4.conf"
LOG_FILE="/var/log/kea-admin.log"
SERVICE_NAME="kea-dhcp4"

#================= SETUP ====================#
touch "$LOG_FILE"

#================= FUNCTIONS =================#

log_action() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

add_subnet() {
INPUT_CONFIG="/etc/kea/kea-dhcp4.conf"
TMP_CONFIG="/tmp/kea-dhcp4.conf.tmp"
NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named/"

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
TEXTRESET="\e[0m"

# Validate CIDR
validate_cidr() {
    local cidr=${1-}  # Use default value to prevent unbound variable error
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    local n="(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
    [[ $ip =~ ^$n(\.$n){3}$ ]] && [[ $prefix -ge 0 && $prefix -le 32 ]]
}

# Validate IP
validate_ip() {
    local ip=${1-}  # Use default value to prevent unbound variable error
    local n="(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
    [[ $ip =~ ^$n(\.$n){3}$ ]]
}

# Extract domain name
get_domain() {
    hostnamectl | awk -F. '/Static hostname/ {print $2"."$3}'
}

# Reverse IP for zone
reverse_ip() {
    local ip="$1"
    echo "$ip" | awk -F '.' '{print $3"."$2"."$1}'
}

# Function to display a dialog menu
#select_interface() {
#    local interfaces=("$@")
#    local options=()
#    for i in "${!interfaces[@]}"; do
#        options+=("$i" "${interfaces[$i]}")
#    done
#    local choice
#    choice=$(dialog --clear --backtitle "Interface Selection" --title "Available Interfaces" \
#        --menu "Select an interface:" 15 40 4 "${options[@]}" 3>&1 1>&2 2>&3)
#    echo "${interfaces[$choice]}"
#}


select_interface() {
    local interfaces=("$@")
    local options=()
    for i in "${!interfaces[@]}"; do
        options+=("$i" "${interfaces[$i]}")
    done

    local choice
    exec 3>&1
    choice=$(dialog --clear --backtitle "Interface Selection" --title "Available Interfaces" \
        --menu "Select an interface:" 15 40 4 "${options[@]}" 2>&1 1>&3)
    local status=$?
    exec 3>&-

    if [ $status -ne 0 ]; then
        return 1  # Cancel or ESC
    fi

    echo "${interfaces[$choice]}"
}

# Function to display a dialog input box with default value handling
input_box() {
    local backtitle="${1-}"
    local title="${2-}"
    local message="${3-}"
    local default_value="${4-}"

    local result
    result=$(dialog --clear --backtitle "$backtitle" --title "$title" --inputbox "$message" 8 40 "$default_value" 3>&1 1>&2 2>&3)
    echo "$result"
}

# Function to display a dialog yes/no box
yesno_box() {
    local backtitle="${1-}"
    local title="${2-}"
    local message="${3-}"

    dialog --clear --backtitle "$backtitle" --title "$title" --yesno "$message" 8 40
    return $?
}

# Function to display a dialog message box
msg_box() {
    local backtitle="${1-}"
    local title="${2-}"
    local message="${3-}"

    dialog --clear --backtitle "$backtitle" --title "$title" --msgbox "$message" 10 50
}

# Function to display examples in a message box
show_examples() {
    local examples="Standard: tftp-server-name = 192.168.50.10\n\
Advanced: code=150 name=tftp-server-name space=dhcp4 data=192.168.50.10\n\
More examples: bootfile-name, time-servers, log-servers, domain-name"

    msg_box "Examples" "DHCP Option Examples" "$examples"
}

# Function to display an info box
info_box() {
    local backtitle="${1-}"
    local title="${2-}"
    local message="${3-}"

    dialog --clear --backtitle "$backtitle" --title "$title" --infobox "$message" 10 50
}

while true; do
  USED_INTERFACES=$(jq -r '.Dhcp4.subnet4[].interface' "$INPUT_CONFIG")
  BASE_IFACE=$(nmcli -t -f DEVICE,CONNECTION device status | awk -F: '$2 ~ /-inside$/ {print $1}')
  ALL_IFACES=$(nmcli -t -f DEVICE,CONNECTION device status | awk -F: -v base="$BASE_IFACE" '$1 == base || $1 ~ base"\\.[0-9]+" {print $1}')

  AVAILABLE_INTERFACES=()
  for iface in $ALL_IFACES; do
    if ! grep -q "\"$iface\"" <<< "$USED_INTERFACES"; then
      AVAILABLE_INTERFACES+=("$iface")
    fi
  done

  if [[ ${#AVAILABLE_INTERFACES[@]} -eq 0 ]]; then
    msg_box "Error" "No available interfaces found for assignment." "No available interfaces found for assignment."
    exit 1
  fi

if ! SELECTED_IFACE=$(select_interface "${AVAILABLE_INTERFACES[@]}"); then
  return  # or break, depending on context
fi

dns_server_ip=$(nmcli -g IP4.ADDRESS device show "$SELECTED_IFACE" | awk -F/ '{print $1}')
if [ -z "$dns_server_ip" ]; then
  msg_box "Error" "No IP found for interface $SELECTED_IFACE" "No IP found for interface $SELECTED_IFACE"
  return
fi



#  SELECTED_IFACE=$(select_interface "${AVAILABLE_INTERFACES[@]}")
#  dns_server_ip=$(nmcli -g IP4.ADDRESS device show "$SELECTED_IFACE" | awk -F/ '{print $1}')
#  if [ -z "$dns_server_ip" ]; then
#    msg_box "Error" "No IP found for interface $SELECTED_IFACE" "No IP found for interface $SELECTED_IFACE"
#    exit 1
#  fi

  domain=$(get_domain)
  MAX_ID=$(jq '.Dhcp4.subnet4[].id' "$INPUT_CONFIG" | sort -n | tail -n1)
  NEW_ID=$((MAX_ID + 1))

  description=$(input_box "Subnet Configuration" "Description" "Enter a friendly description for this subnet:")

  while true; do
      CIDR=$(input_box "Subnet Configuration" "CIDR" "Enter subnet in CIDR format (e.g., 192.168.50.0/24):")
      if validate_cidr "$CIDR"; then break; else msg_box "Error" "Invalid CIDR. Try again." "Invalid CIDR. Try again."; fi
  done

  DEFAULT_START="$(echo "$CIDR" | awk -F. '{print $1"."$2"."$3".10"}')"
  DEFAULT_END="$(echo "$CIDR" | awk -F. '{print $1"."$2"."$3".100"}')"

  while true; do
      pool_start=$(input_box "Subnet Configuration" "Start IP" "Enter start IP for pool [$DEFAULT_START]:" "$DEFAULT_START")
      if validate_ip "$pool_start"; then break; else msg_box "Error" "Invalid IP. Try again." "Invalid IP. Try again."; fi
  done

  while true; do
      pool_end=$(input_box "Subnet Configuration" "End IP" "Enter end IP for pool [$DEFAULT_END]:" "$DEFAULT_END")
      if validate_ip "$pool_end"; then break; else msg_box "Error" "Invalid IP. Try again." "Invalid IP. Try again."; fi
  done

  while true; do
      router_address=$(input_box "Subnet Configuration" "Router IP" "Enter router address [default: $dns_server_ip]:" "$dns_server_ip")
      if validate_ip "$router_address"; then break; else msg_box "Error" "Invalid IP. Try again." "Invalid IP. Try again."; fi
  done

  EXTRA_OPTIONS=()
  if yesno_box "DHCP Options" "Custom Options" "Would you like to add custom DHCP options?"; then
    while true; do
      opt_type=$(dialog --clear --backtitle "DHCP Options" --title "Option Type" --menu "Choose option type:" 10 40 3 \
        1 "Standard option (name + value)" \
        2 "Advanced option (code + name + value)" \
        3 "Show examples" 3>&1 1>&2 2>&3)

      case "$opt_type" in
        1)
          opt_name=$(input_box "DHCP Options" "Option Name" "Enter option name:")
          opt_value=$(input_box "DHCP Options" "Option Value" "Enter value for $opt_name:")
          EXTRA_OPTIONS+=("{\"name\": \"$opt_name\", \"data\": \"$opt_value\"}")
          ;;
        2)
          opt_code=$(input_box "DHCP Options" "Option Code" "Enter option code (e.g. 150):")
          opt_name=$(input_box "DHCP Options" "Option Name" "Enter option name (e.g. tftp-server-name):")
          opt_value=$(input_box "DHCP Options" "Option Value" "Enter value for $opt_name:")
          opt_space=$(input_box "DHCP Options" "Option Space" "Enter space (default: dhcp4):" "dhcp4")
          EXTRA_OPTIONS+=("{\"code\": $opt_code, \"name\": \"$opt_name\", \"space\": \"$opt_space\", \"data\": \"$opt_value\"}")
          ;;
        3)
          show_examples
          ;;
        *)
          msg_box "Error" "Invalid choice. Try again." "Please enter a valid option from the menu."
          continue
          ;;
      esac

      if ! yesno_box "DHCP Options" "Add Another" "Add another option?"; then
        break
      fi
    done
  fi

  EXTRA_JSON=$(IFS=,; echo "${EXTRA_OPTIONS[*]}")

  dialog --clear --backtitle "Review Settings" --title "Configuration Review" --msgbox \
    "Friendly Name: $description\nNetwork Scheme: $CIDR\nInterface: $SELECTED_IFACE\nIP Pool Range: $pool_start - $pool_end\nRouter Address: $ro
uter_address\nNTP Server: $dns_server_ip\nDNS Server: $dns_server_ip\nClient suffix: $domain\nClient Search Domain: $domain\n\nCustom DHCP Optio
ns:\n$(IFS=$'\n'; echo "${EXTRA_OPTIONS[*]}" | jq -r '. | "- " + (if .code then "[code=" + (.code|tostring) + "] " else "" end) + .name + " = "
+ .data')" 20 70

  if yesno_box "Confirmation" "Review" "Is this configuration correct?"; then
      pool_range="$pool_start - $pool_end"
      NEW_SUBNET=$(jq -n \
        --arg cidr "$CIDR" \
        --arg iface "$SELECTED_IFACE" \
        --arg pool_range "$pool_range" \
        --arg desc "$description" \
        --arg router "$router_address" \
        --arg dns "$dns_server_ip" \
        --arg dom "$domain" \
        --argjson id "$NEW_ID" \
        --argjson extras "[${EXTRA_JSON:-}]" '
{
  comment: $desc,
  id: $id,
  subnet: $cidr,
  interface: $iface,
  pools: [ { pool: $pool_range } ],
  "option-data": (
    [
      { name: "routers", data: $router },
      { name: "domain-name-servers", data: $dns },
      { name: "ntp-servers", data: $dns },
      { name: "domain-search", data: $dom },
      { name: "domain-name", data: $dom }
    ] + $extras
  )}')

      jq --argjson new_subnet "$NEW_SUBNET" '.Dhcp4.subnet4 += [$new_subnet]' "$INPUT_CONFIG" > "$TMP_CONFIG"

      if jq . "$TMP_CONFIG" > "$INPUT_CONFIG"; then
          info_box "Success" "Operation Status" "Subnet added successfully.\nRestarting KEA DHCP service..."
          sleep 1
          if systemctl restart kea-dhcp4; then
              msg_box "Success" "KEA DHCP Restarted" "KEA DHCP restarted."
          else
              msg_box "Error" "Failed Operation" "Failed to restart KEA DHCP."
          fi
      else
          msg_box "Failure" "Operation Failed" "Failed to validate updated config. Reverting."
          exit 1
      fi

      ip_portion="$(echo "$CIDR" | cut -d'/' -f1)"
      reversed_ip="$(reverse_ip "$ip_portion")"
      reverse_zone="${reversed_ip}.in-addr.arpa"
      reverse_zone_file="${ZONE_DIR}db.${reversed_ip}"
      full_hostname=$(hostnamectl status | awk '/Static hostname:/ {print $3}')
      hostname="${full_hostname%%.*}"
      domain="${full_hostname#*.}"

      info_box "Info" "Zone Check" "Checking for reverse zone: ${reverse_zone}"
      sleep 1

      if ! grep -q "zone \"$reverse_zone\"" "$NAMED_CONF"; then
          msg_box "Info" "Reverse Zone Creation" "Reverse zone ${reverse_zone} not found. Creating..."
          cat >> "$NAMED_CONF" <<EOF

zone "$reverse_zone" {
    type master;
    file "$reverse_zone_file";
    allow-update { key "Kea-DDNS"; };
};
EOF

          cat > "$reverse_zone_file" <<EOF
\$TTL 86400
@   IN  SOA   $full_hostname. admin.$domain. (
    2023100501 ; serial
    3600       ; refresh
    1800       ; retry
    604800     ; expire
    86400      ; minimum
)
@   IN  NS    $full_hostname.
${dns_server_ip##*.}  IN  PTR   $full_hostname.
EOF

          chmod 640 "$reverse_zone_file"
          chown named:named "$reverse_zone_file"
          chown root:named "$NAMED_CONF"
          chmod 640 "$NAMED_CONF"
          restorecon -v /etc/named.conf
          info_box "Success" "Reverse Zone Added" "Reverse zone ${reverse_zone} added to DNS."
          sleep 1
      else
          msg_box "Success" "Reverse Zone Status" "Reverse zone ${reverse_zone} already exists."
      fi
      if systemctl restart named; then
    if systemctl is-active --quiet named; then
        msg_box "Success" "Named Service Status" "Named restarted successfully and is running."
    else
        msg_box "Warning" "Named Service Warning" "Named was restarted, but it is not currently running.\n\nCheck logs:\n  journalctl -u named"
    fi
    else
        msg_box "Error" "Named Restart Failed" "Failed to restart named.\n\nCheck logs:\n  journalctl -xe"
fi

      break
  else
      msg_box "Info" "Retry Configuration" "Let's try that again..."
  fi

done
}







delete_subnet() {
  CONFIG="/etc/kea/kea-dhcp4.conf"
  BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  TMP="/tmp/kea-dhcp4.modified.json"
  DIFF="/tmp/kea-dhcp4.diff.$(date +%s)"
  MENU_HEIGHT=20
  MENU_WIDTH=60

  [[ ! -f "$CONFIG" ]] && {
    dialog --msgbox "KEA config not found: $CONFIG" 6 50
    return
  }

  mapfile -t COMMENTS < <(jq -r '.Dhcp4.subnet4[] | select(.comment != null) | .comment' "$CONFIG")

  if [[ ${#COMMENTS[@]} -eq 0 ]]; then
    dialog --msgbox "No subnets found!" 6 50
    return
  fi

  MENU_ITEMS=()
  for comment in "${COMMENTS[@]}"; do
    subnet=$(jq -r --arg c "$comment" '.Dhcp4.subnet4[] | select(.comment == $c) | .subnet' "$CONFIG")
    MENU_ITEMS+=("$comment" "$subnet")
  done

  exec 3>&1
CHOICE=$(dialog --clear --title "Delete Subnet" \
  --menu "Choose subnet to delete:" $MENU_HEIGHT $MENU_WIDTH ${#MENU_ITEMS[@]} \
  "${MENU_ITEMS[@]}" 2>&1 1>&3)
rc=$?
exec 3>&-
[[ $rc -ne 0 ]] && return
[[ -z "$CHOICE" ]] && return

  dialog --yesno "Really delete subnet: $CHOICE?" 7 50
  [[ $? -ne 0 ]] && return

  cp "$CONFIG" "$BACKUP"
  dialog --msgbox "Backup saved to:\n$BACKUP" 7 60

  jq --arg c "$CHOICE" '
    .Dhcp4.subnet4 |= map(
      if .comment != $c then
        if .["option-data"] then
          .["option-data"] |= map(
            if (.code? != null) and (.data | test("^\\d+\\.\\d+\\.\\d+\\.\\d+$")) then
              .data = ((.data | split(".") | map(tonumber) | map(tostring)) | map("0" + .) | map(.[-2:]) | join(":"))
            else . end
          )
        else . end
      else empty end
    )' "$CONFIG" > "$TMP"

  if kea-dhcp4 -t "$TMP" 2> /tmp/kea_tmp_invalid.log; then
    dialog --msgbox "New configuration is valid." 6 50
  else
    dialog --title "Validation Failed" --textbox /tmp/kea_tmp_invalid.log 20 70
    dialog --msgbox "Config test failed. Backup was not replaced." 6 60
    return
  fi

  diff -u "$CONFIG" "$TMP" > "$DIFF" || true
  dialog --yesno "Subnet removed successfully.\n\nDiff saved to:\n$DIFF\n\nApply changes and restart KEA?" 10 60
  [[ $? -ne 0 ]] && return

  cp "$TMP" "$CONFIG"
  chmod 644 "$CONFIG"
  systemctl restart kea-dhcp4

  dialog --msgbox "Subnet deleted and KEA restarted successfully." 6 60
}


edit_config() {
  [ -f "$CONFIG_FILE" ] || {
    dialog --msgbox "KEA config not found at $CONFIG_FILE" 6 60
    return
  }

  tmp=$(mktemp)
  out=$(mktemp)
  cp "$CONFIG_FILE" "$tmp"

  exec 3>&1
  dialog --clear --title "Manual Edit: kea-dhcp4.conf" \
    --editbox "$tmp" 25 80 2>"$out" 1>&3
  erc=$?
  exec 3>&-
  rm -f "$tmp"

  [ $erc -ne 0 ] && { rm -f "$out"; return; }

  # Validate JSON
  if ! jq . "$out" >/dev/null 2>&1; then
    dialog --msgbox "Invalid JSON syntax. Changes discarded." 7 60
    rm -f "$out"
    log_action "Invalid JSON edit attempted. Discarded changes."
    return
  fi

  exec 3>&1
  dialog --clear --title "Apply Changes?" \
    --yesno "Save changes to $CONFIG_FILE?" 7 60
  arc=$?
  exec 3>&-

  if [ $arc -eq 0 ]; then
    backup="$CONFIG_FILE.bak.$(date '+%Y%m%d%H%M%S')"
    cp "$CONFIG_FILE" "$backup"
    mv "$out" "$CONFIG_FILE"
    dialog --msgbox "Changes saved. Backup created at: $backup" 6 60
    log_action "Manual edit applied to $CONFIG_FILE"
  else
    rm -f "$out"
    dialog --msgbox "Changes discarded." 6 40
  fi
}

restart_service() {
  systemctl restart "$SERVICE_NAME"
  dialog --msgbox "Service $SERVICE_NAME restarted." 6 40
  log_action "Service $SERVICE_NAME restarted"
}

show_status() {
  tmpfile=$(mktemp)
  systemctl status "$SERVICE_NAME" --no-pager | fold -s -w 110 > "$tmpfile"
  dialog --title "$SERVICE_NAME Service Status" --textbox "$tmpfile" 30 120
  rm -f "$tmpfile"
  log_action "Viewed service status for $SERVICE_NAME"
}

view_logs() {
  tail -n 50 "$LOG_FILE" > /tmp/kea-admin-log.txt
  dialog --title "KEA Admin Logs (Last 50 lines)" --textbox /tmp/kea-admin-log.txt 25 80
  rm -f /tmp/kea-admin-log.txt
}

kea_service_menu() {
  while true; do
    exec 3>&1
    choice=$(
      dialog --clear \
             --title "KEA Service Control" \
             --menu "Choose an action (Cancel→main menu):" \
             25 70 10 \
             1 "Show kea-dhcp4 status" \
             2 "View kea-dhcp4 logs" \
             3 "Restart kea-dhcp4" \
             4 "Show kea-dhcp-ddns status" \
             5 "View kea-dhcp-ddns logs" \
             6 "Restart kea-dhcp-ddns" \
             7 "Back to Main Menu" \
        2>&1 1>&3
    )
    rc=$?
    exec 3>&-

    [ $rc -ne 0 ] && break

    case "$choice" in
      1)
        tmpfile=$(mktemp)
        systemctl status kea-dhcp4 --no-pager | fold -s -w 110 > "$tmpfile"
        dialog --title "kea-dhcp4 Service Status" --textbox "$tmpfile" 30 120
        rm -f "$tmpfile"
        log_action "Viewed service status for kea-dhcp4"
        ;;
      2)
        journalctl -u kea-dhcp4 -n 200 --no-pager > /tmp/kea4-journal.log
        dialog --title "kea-dhcp4 Logs (last 200 lines)" \
               --tailbox /tmp/kea4-journal.log 30 120
        rm -f /tmp/kea4-journal.log
        log_action "Viewed logs for kea-dhcp4"
        ;;
      3)
        systemctl restart kea-dhcp4
        dialog --msgbox "kea-dhcp4 restarted successfully." 6 50
        log_action "Service kea-dhcp4 restarted"
        ;;
      4)
        tmpfile=$(mktemp)
        systemctl status kea-dhcp-ddns --no-pager | fold -s -w 110 > "$tmpfile"
        dialog --title "kea-dhcp-ddns Service Status" --textbox "$tmpfile" 30 120
        rm -f "$tmpfile"
        log_action "Viewed service status for kea-dhcp-ddns"
        ;;
      5)
        journalctl -u kea-dhcp-ddns -n 200 --no-pager > /tmp/keaddns-journal.log
        dialog --title "kea-dhcp-ddns Logs (last 200 lines)" \
               --tailbox /tmp/keaddns-journal.log 30 120
        rm -f /tmp/keaddns-journal.log
        log_action "Viewed logs for kea-dhcp-ddns"
        ;;
      6)
        systemctl restart kea-dhcp-ddns
        dialog --msgbox "kea-dhcp-ddns restarted successfully." 6 50
        log_action "Service kea-dhcp-ddns restarted"
        ;;
      7)
        break
        ;;
    esac
  done
}

#================== MAIN MENU ==================#
main_menu() {
  while true; do
    exec 3>&1
    CHOICE=$(dialog --clear --backtitle "KEA DHCP Admin Tool" \
      --title "Main Menu" \
      --menu "Choose an option:" 15 60 6 \
      1 "Add Subnet" \
      2 "Delete Subnet" \
      3 "Edit kea-dhcp4.conf manually" \
      4 "KEA Service Control" \
      5 "Exit" \
      2>&1 1>&3)
    menu_exit=$?
    exec 3>&-

    if [ $menu_exit -ne 0 ]; then
      break  # Cancel or ESC was pressed
    fi

    case "$CHOICE" in
      1) add_subnet ;;
      2) delete_subnet ;;
      3) edit_config ;;
      4) kea_service_menu ;;
      5) break ;;
    esac
  done
}

main_menu
clear
