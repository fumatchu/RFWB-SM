vlan_main(){
vlan_configurator
}

vlan_configurator() {
  DEBUG_LOG="/tmp/vlan_debug.txt"
  echo "=== VLAN Setup Log ===" > "$DEBUG_LOG"

  while true; do
    VLAN_INFO=$(nmcli -t -f NAME,DEVICE,TYPE connection show | grep ":vlan" | while IFS=: read -r name device type; do
      vlan_id="${device##*.}"
      ip=$(nmcli connection show "$name" | awk '/ipv4.addresses:/ {print $2}')
      echo "$device → $name (VLAN $vlan_id, ${ip:-No IP})"
    done)

    echo "$VLAN_INFO" > /tmp/vlan_map.txt
    dialog --title "Current VLAN Mappings" --textbox /tmp/vlan_map.txt 15 70

    dialog --menu "What would you like to do?" 12 50 4 \
      1 "Add a VLAN" \
      2 "Delete a VLAN" \
      3 "Exit" 2> /tmp/vlan_action

    case $(< /tmp/vlan_action) in
      1)
        IFS=$'\n' read -d '' -r -a interfaces < <(nmcli -t -f NAME,DEVICE connection show --active | grep -v '\.' | grep -v ':lo' && printf '\0'
)
        if [[ ${#interfaces[@]} -eq 0 ]]; then
          dialog --msgbox "No physical interfaces available." 5 40
          continue
        fi

        MENU_ITEMS=()
        for entry in "${interfaces[@]}"; do
          name="${entry%%:*}"
          dev="${entry##*:}"
          MENU_ITEMS+=("$dev" "$name")
        done

        dialog --menu "Select an interface for the VLAN:" 15 50 6 "${MENU_ITEMS[@]}" 2> /tmp/interface_choice
        selected_interface=$(< /tmp/interface_choice)

        while true; do
          dialog --inputbox "Enter VLAN ID (1-4094):" 8 40 2> /tmp/vlan_id
          vlan_id=$(< /tmp/vlan_id)

          existing_vlan_ifaces=$(nmcli -t -f DEVICE,TYPE connection show | grep ":vlan" | cut -d: -f1)
          for iface in $existing_vlan_ifaces; do
            if [[ "$iface" == "${selected_interface}.${vlan_id}" ]]; then
              dialog --msgbox "VLAN ID $vlan_id already exists on $selected_interface.\nPlease choose a different VLAN ID." 7 60
              continue 2
            fi
          done

          [[ "$vlan_id" =~ ^[0-9]+$ && "$vlan_id" -ge 1 && "$vlan_id" -le 4094 ]] && break
          dialog --msgbox "Invalid VLAN ID. Must be 1–4094." 5 40
        done

        while true; do
          dialog --inputbox "Enter IP address in CIDR format (e.g. 192.168.50.1/24):" 8 50 "192.168.10.1/24" 2> /tmp/vlan_ip
          vlan_ip=$(< /tmp/vlan_ip)

          if ! validate_cidr "$vlan_ip"; then
            dialog --msgbox "Invalid format. Use IP/CIDR format (e.g. 192.168.50.1/24)." 6 60
            continue
          fi

          if ! is_host_ip "$vlan_ip"; then
            dialog --msgbox "That IP is the network or broadcast address. Choose a valid host IP." 6 60
            continue
          fi

          host_ip="${vlan_ip%/*}"
          if ip -4 addr show | grep -q "$host_ip"; then
            dialog --msgbox "The IP address $host_ip is already assigned.\nPlease choose another." 6 60
            continue
          fi

          if ip -4 addr show | grep -q "$vlan_ip"; then
            dialog --msgbox "This exact CIDR is already in use.\nPlease use a different range." 6 60
            continue
          fi

          new_network=$(ipcalc -n "$vlan_ip" 2>/dev/null | awk -F= '/^NETWORK=/ {print $2}')
          if [[ -z "$new_network" ]]; then
            dialog --msgbox "Failed to calculate network. Please re-enter." 6 50
            continue
          fi

          subnet_in_use=0
          while IFS= read -r existing_ip; do
            existing_cidr=$(echo "$existing_ip" | awk '{print $2}')
            [[ -z "$existing_cidr" ]] && continue
            existing_network=$(ipcalc -n "$existing_cidr" 2>/dev/null | awk -F= '/^NETWORK=/ {print $2}')
            [[ "$existing_network" == "$new_network" ]] && subnet_in_use=1
          done < <(ip -4 addr show | grep -oP 'inet \K[\d./]+')

          if [[ "$subnet_in_use" -eq 1 ]]; then
            dialog --msgbox "The subnet $new_network is already in use.\nYou cannot assign it to multiple VLANs." 6 60
            continue
          fi

          break
        done

        while true; do
          dialog --inputbox "Enter a friendly name for the VLAN:" 8 50 2> /tmp/friendly_name
          friendly_name=$(< /tmp/friendly_name)

          if nmcli -t -f NAME connection show | grep -Fxq "$friendly_name"; then
            dialog --msgbox "The name \"$friendly_name\" already exists. Please choose another." 6 60
          else
            break
          fi
        done

        summary="Interface: $selected_interface
VLAN ID: $vlan_id
IP: $vlan_ip
Name: $friendly_name"

        dialog --yesno "Apply this configuration?\n\n$summary" 12 60 || continue

        vlan_conn="${selected_interface}.${vlan_id}"
        nmcli connection add type vlan con-name "$vlan_conn" dev "$selected_interface" id "$vlan_id" ip4 "$vlan_ip" >> "$DEBUG_LOG" 2>&1
        nmcli connection modify "$vlan_conn" connection.id "$friendly_name" >> "$DEBUG_LOG" 2>&1
        nmcli connection up "$friendly_name" >> "$DEBUG_LOG" 2>&1

        dialog --infobox "VLAN $vlan_id configured on $selected_interface as $friendly_name." 6 50
        sleep 3
        ;;

      2)
        VLAN_CONNS_RAW=($(nmcli -t -f NAME,DEVICE,TYPE connection show | grep ":vlan"))
        if [[ ${#VLAN_CONNS_RAW[@]} -eq 0 ]]; then
          dialog --msgbox "No VLAN connections found to delete." 5 50
          continue
        fi

        MENU_ITEMS=()
        for line in "${VLAN_CONNS_RAW[@]}"; do
          IFS=: read -r name device type <<< "$line"
          vlan_id="${device##*.}"
          ip=$(nmcli connection show "$name" | awk '/ipv4.addresses:/ {print $2}')
          display="${device} → $name (VLAN $vlan_id, ${ip:-No IP})"
          MENU_ITEMS+=("$name" "$display")
        done

        dialog --menu "Select a VLAN to delete:" 18 70 8 "${MENU_ITEMS[@]}" 2> /tmp/delete_choice
        selected_vlan=$(< /tmp/delete_choice)

        dialog --yesno "Are you sure you want to delete VLAN \"$selected_vlan\"?" 7 50 || continue

        nmcli connection delete "$selected_vlan" >> "$DEBUG_LOG" 2>&1
        dialog --infobox "VLAN \"$selected_vlan\" deleted successfully.\nContinuing..." 6 50
        sleep 3
        ;;

      3)
        break
        ;;
    esac
  done
}
