#!/usr/bin/env bash
set -euo pipefail

# ─── Profile & Routing Manager ───────────────────────────────────────────────
# Lists all NM connection profiles (excluding loopback/bridge/bond),
# sorted by ethernet → vlan → wifi → vpn → others. Shows primary IPv4 address
# and route metric, and lets you:
#   • Bring Up/Down
#   • Show IP
#   • Edit IPv4 (DHCP/Static)
#   • Edit Route Metric
#   • Set DHCP Hostname
#   • Restart Firewall
#   • Back to Profiles

# ─── Dependencies ────────────────────────────────────────────────────────────
for cmd in dialog nmcli systemctl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required." >&2
    exit 1
  fi
done

# ─── Firewall Prompt ─────────────────────────────────────────────────────────
maybe_restart_firewall() {
  dialog --yesno "Restart nftables firewall?" 6 60
  if [ $? -eq 0 ]; then
    systemctl restart nftables
    for svc in rfwb-portscan.service rfwb-ps-mon.service; do
      if systemctl list-unit-files --no-legend --no-pager \
           | awk '{print $1}' | grep -qx "$svc"; then
        systemctl restart "$svc"
      fi
    done
    dialog --msgbox "nftables + rfwb-* restarted." 6 60
  fi
}

# ─── Main Loop ────────────────────────────────────────────────────────────────
manage_profiles() {
  while true; do
    # 1) Gather all profiles, exclude loopback/bridge/bond
    mapfile -t raw < <(
      nmcli -t -f NAME,TYPE,DEVICE connection show \
        | grep -Ev ':(loopback|bridge|bond):'
    )
    [ ${#raw[@]} -gt 0 ] || { dialog --msgbox "No connection profiles found." 6 50; return; }

    # 2) Sort by type: ethernet → vlan → wifi → vpn → others
    sorted=()
    for t in ethernet vlan wifi vpn; do
      for entry in "${raw[@]}"; do
        [[ "${entry#*:}" =~ ^$t: ]] && sorted+=( "$entry" )
      done
    done
    for entry in "${raw[@]}"; do
      type="${entry#*:}"; type="${type%%:*}"
      case "$type" in
        ethernet|vlan|wifi|vpn) ;;
        *) sorted+=( "$entry" ) ;;
      esac
    done

    # 3) Build menu: tag=profile, desc="type on device [state] IP m:<metric>"
    menu=()
    for entry in "${sorted[@]}"; do
      name="${entry%%:*}"
      rest="${entry#*:}"
      type="${rest%%:*}"
      dev="${rest##*:}"

      state=$(nmcli -t -f NAME connection show --active | grep -qx "$name" && echo up || echo down)
      ip=$(nmcli -g IP4.ADDRESS connection show "$name" | head -n1 | cut -d/ -f1)
      [ -z "$ip" ] && ip="—"
      metric=$(nmcli -g ipv4.route-metric connection show "$name")
      [ -z "$metric" ] && metric="default"

      menu+=( "$name" "${type} on ${dev:-<none>} [${state}] ${ip} m:${metric}" )
    done
    menu+=( Back "Return to previous menu" )

    height=$(( ${#menu[@]} / 2 ))
    exec 3>&1
    choice=$(dialog --clear \
                    --title "Connection Profiles & Routing" \
                    --menu "Select profile (Back→exit):" \
                    22 100 "$height" \
                    "${menu[@]}" \
              2>&1 1>&3)
    rc=$?; exec 3>&-
    [ $rc -ne 0 ] || [ "$choice" = "Back" ] && return
    profile="$choice"

    # 4) Per‑profile submenu
    while true; do
      state=$(nmcli -t -f NAME connection show --active | grep -qx "$profile" && echo up || echo down)

      exec 3>&1
      action=$(dialog --clear \
                     --title "Manage: $profile" \
                     --menu "State: $state    Action:" \
                     22 100 8 \
                       1 "Bring Up" \
                       2 "Bring Down" \
                       3 "Show IP Address" \
                       4 "Edit IPv4 Config" \
                       5 "Edit Route Metric" \
                       6 "Set DHCP Hostname" \
                       7 "Restart Firewall" \
                       8 "Back to Profiles" \
               2>&1 1>&3)
      arc=$?; exec 3>&-
      [ $arc -ne 0 ] || [ "$action" = "8" ] && break

      case "$action" in
        1)
          nmcli connection up "$profile" && dialog --msgbox "$profile is now UP." 5 60
          ;;
        2)
          nmcli connection down "$profile" && dialog --msgbox "$profile is now DOWN." 5 60
          ;;
        3)
          nmcli -t -f IP4.ADDRESS connection show "$profile" \
            > "/tmp/${profile//\//_}_ip.txt"
          dialog --title "$profile IP Address" \
                 --textbox "/tmp/${profile//\//_}_ip.txt" 10 60
          ;;
        4)
          methods=( DHCP "Use DHCP" Static "Use Static" Back "Cancel" )
          mh=$(( ${#methods[@]} / 2 ))
          exec 3>&1
          method=$(dialog --clear \
                          --title "IPv4 Config: $profile" \
                          --menu "Method (Back→cancel):" \
                          10 60 "$mh" \
                          "${methods[@]}" \
                   2>&1 1>&3)
          mrc=$?; exec 3>&-
          [ $mrc -ne 0 ] || [ "$method" = "Back" ] && continue

          if [ "$method" = "DHCP" ]; then
            nmcli connection modify "$profile" ipv4.method auto \
              ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
            nmcli connection up "$profile"
            dialog --msgbox "$profile set to DHCP." 5 60
          else
            exec 3>&1; addr=$(dialog --inputbox "IP/prefix (e.g. 192.168.1.100/24):" 8 60 2>&1 1>&3)
            exec 3>&-; [ -z "$addr" ] && continue
            exec 3>&1; gw=$(dialog --inputbox "Gateway (e.g. 192.168.1.1):" 8 60 2>&1 1>&3)
            exec 3>&-; [ -z "$gw" ] && continue
            exec 3>&1; dns=$(dialog --inputbox "DNS (comma‑sep):" 8 70 2>&1 1>&3)
            exec 3>&-; [ -z "$dns" ] && dns=""
            nmcli connection modify "$profile" ipv4.method manual \
              ipv4.addresses "$addr" ipv4.gateway "$gw" ipv4.dns "$dns"
            nmcli connection up "$profile"
            dialog --msgbox "$profile static config applied." 5 60
          fi
          ;;
        5)
          current=$(nmcli -g ipv4.route-metric connection show "$profile")
          exec 3>&1
          newm=$(dialog --inputbox "Route metric (current: $current):" 8 60 "$current" 2>&1 1>&3)
          exec 3>&-
          [ -z "$newm" ] && continue
          nmcli connection modify "$profile" ipv4.route-metric "$newm"
          nmcli connection up "$profile"
          dialog --msgbox "Route metric set to $newm." 5 60
          ;;
        6)
          current=$(nmcli -g ipv4.dhcp-hostname connection show "$profile")
          exec 3>&1
          nh=$(dialog --inputbox "DHCP hostname (current: ${current:-none}):" 8 60 "$current" 2>&1 1>&3)
          exec 3>&-
          [ $? -eq 0 ] && nmcli connection modify "$profile" ipv4.dhcp-hostname "${nh:-""}"
          nmcli connection up "$profile"
          dialog --msgbox "DHCP hostname set to ${nh:-none}." 5 60
          ;;
        7)
          maybe_restart_firewall
          ;;
      esac
    done
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  manage_profiles
fi
