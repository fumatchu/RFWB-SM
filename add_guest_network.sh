#!/usr/bin/env bash
#
# guest_vlan_setup.sh
# ──────────────────────────────────────────────────────────────────────────────
# Dialog‑driven setup/reset for a “Guest” interface + nftables lockdown:
#  • On existing guest iface, optionally reset (cleanup old rules & conns)
#  • Create new guest (physical or VLAN)
#  • Allow ONLY DHCP, DNS, NTP on INPUT, and guest→outside in FORWARD
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

CONFIG="/etc/sysconfig/nftables.conf"
BACKUP_DIR="/etc/sysconfig"
BACKUP_FILE="$BACKUP_DIR/nftables.conf.bak.$(date +%Y%m%d%H%M%S)"

die(){ echo "$*" >&2; exit 1; }

backup_nft(){
  [[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"
  cp "$CONFIG" "$BACKUP_FILE"
}

get_input_handle(){
  nft --handle list chain inet filter input \
    | sed -n 's/.*ip saddr @threat_block drop.*# handle \([0-9]\+\).*/\1/p'
}

get_input_est_handle(){
  nft --handle list chain inet filter input \
    | sed -n 's/.*ct state established,related accept.*# handle \([0-9]\+\).*/\1/p'
}

get_forward_handle(){
  nft --handle list chain inet filter forward \
    | sed -n 's/.*ct state established,related accept.*# handle \([0-9]\+\).*/\1/p'
}
get_input_logdrop_handle(){
  nft --handle list chain inet filter input \
    | sed -n 's/.*log prefix "INPUT DROP: " drop.*# handle \([0-9]\+\).*/\1/p'
}

#── 0) DETECT & OPTIONALLY RESET EXISTING GUEST ------------------------------

exist_phys=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
  | awk -F: '$1 ~ /-guest$/ {print $1":"$2; exit}') || exist_phys=""
exist_phys=${exist_phys:-}

exist_vlan=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
  | awk -F: '$1=="guest"{print $1":"$2; exit}') || exist_vlan=""
exist_vlan=${exist_vlan:-}

if [[ -n "$exist_phys" || -n "$exist_vlan" ]]; then
  if [[ -n "$exist_phys" ]]; then
    guest_profile="${exist_phys%%:*}"
    guest_iface="${exist_phys##*:}"
  else
    guest_profile="${exist_vlan%%:*}"
    guest_iface="${exist_vlan##*:}"
  fi

  dialog --clear --title "Reset Existing Guest?" \
    --yesno "Detected existing guest interface:\n\n  $guest_iface ($guest_profile)\n\nReset and start over?" 10 60
  if [[ $? -eq 0 ]]; then
    backup_nft

    mapfile -t IN_HANDLES < <(
      nft --handle list chain inet filter input \
        | grep "iifname \"$guest_iface\"" \
        | awk '{print $NF}'
    )
    for h in "${IN_HANDLES[@]}"; do
      nft delete rule inet filter input handle "$h" 2>/dev/null || :
    done

    outside_if=$(nmcli -t -f DEVICE,NAME connection show --active 2>/dev/null \
      | awk -F: '$2 ~ /-outside$/ {print $1; exit}')
    if [[ -n "$outside_if" ]]; then
      mapfile -t FW_HANDLES < <(
        nft --handle list chain inet filter forward \
          | grep "iifname \"$guest_iface\" oifname \"$outside_if\"" \
          | awk '{print $NF}'
      )
      for h in "${FW_HANDLES[@]}"; do
        nft delete rule inet filter forward handle "$h" 2>/dev/null || :
      done
    fi

    if [[ -n "$exist_phys" ]]; then
      orig=${guest_profile%-guest}
      nmcli connection modify "$guest_profile" connection.id "$orig"
      nmcli connection up "$orig"
    else
      nmcli connection delete guest
    fi

    dialog --msgbox "✅ Cleanup complete.\nStarting fresh..." 6 50
  else
    clear; echo "Aborted."; exit 0
  fi
fi

#── 1) CREATE NEW GUEST INTERFACE -------------------------------------------

dialog --clear --title "Guest VLAN Setup" \
  --menu "Create guest as:" 12 60 2 \
    1 "Dedicated PHYSICAL port" \
    2 "Tagged VLAN named 'guest'" 2>/tmp/_mode
mode=$(< /tmp/_mode); rm -f /tmp/_mode

case "$mode" in
  1)  # Improved physical port detection
      dialog --msgbox "Unplug your spare port, click OK, then plug it in." 8 50

# Store interfaces that currently have carrier
mapfile -t OLD_CARRIER < <(find /sys/class/net -maxdepth 1 -type l \
  | grep -vE '/lo$' \
  | while read -r dev; do
      iface=$(basename "$dev")
      [[ "$(cat "$dev/carrier")" == "1" ]] && echo "$iface"
    done)

dialog --infobox "Waiting for a new link to show carrier…" 5 50

for attempt in {1..20}; do
  sleep 1
  mapfile -t NEW_CARRIER < <(find /sys/class/net -maxdepth 1 -type l \
    | grep -vE '/lo$' \
    | while read -r dev; do
        iface=$(basename "$dev")
        [[ "$(cat "$dev/carrier")" == "1" ]] && echo "$iface"
      done)

  for i in "${NEW_CARRIER[@]}"; do
    [[ ! " ${OLD_CARRIER[*]} " =~ " $i " ]] && { guest_iface="$i"; break 2; }
  done
done

if [[ -z "${guest_iface:-}" ]]; then
  dialog --msgbox "⚠️ No new physical link detected within timeout." 6 60
  exit 1
fi

dialog --infobox "Detected new physical link: $guest_iface" 6 50; sleep 1

# Now try to find any connection profile and apply guest tag
prof=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
  | awk -F: -v d="$guest_iface" '$2==d{print $1}')
if [[ -n "$prof" ]]; then
  nmcli connection modify "$prof" connection.id "${prof}-guest"
  nmcli connection up "${prof}-guest"
else
  # No profile exists — create one
  nmcli connection add type ethernet ifname "$guest_iface" con-name "${guest_iface}-guest"
  nmcli connection up "${guest_iface}-guest"
fi
;;
  2)  # VLAN
    mapfile -t PHYS < <(
      nmcli -t -f DEVICE,TYPE device status \
        | awk -F: '$2=="ethernet"{print $1}'
    )
    (( ${#PHYS[@]} )) || die "No Ethernet interfaces found."
    menu=(); for i in "${PHYS[@]}"; do menu+=("$i" ""); done
    dialog --clear --title "Guest VLAN" \
      --menu "Select parent interface:" 12 60 "${#PHYS[@]}" "${menu[@]}" 2>/tmp/_parent
    parent=$(< /tmp/_parent); rm -f /tmp/_parent

    dialog --inputbox "Enter VLAN ID (1–4094):" 8 40 2>/tmp/_vid
    vid=$(< /tmp/_vid); rm -f /tmp/_vid

    dialog --inputbox "Enter Guest IP/CIDR (e.g. 192.168.50.1/24):" 8 60 2>/tmp/_vip
    vip=$(< /tmp/_vip); rm -f /tmp/_vip

    nmcli connection add type vlan con-name guest dev "$parent" id "$vid" ip4 "$vip"
    nmcli connection up guest
    guest_iface="${parent}.${vid}"
    ;;
  *)
    clear; echo "Aborted."; exit 0
    ;;
esac

#── 2) AUTO‑DETECT OUTSIDE INTERFACE ----------------------------------------

outside_if=$(nmcli -t -f DEVICE,NAME connection show --active 2>/dev/null \
  | awk -F: '$2 ~ /-outside$/ {print $1; exit}')
[[ -n "$outside_if" ]] || die "Could not detect an '-outside' interface"

#── 3) LOCKDOWN FIREWALL ----------------------------------------------------

backup_nft

drop_handle=$(get_input_logdrop_handle)

drop_handle=$(get_input_logdrop_handle)

for rule in \
  "iifname \"$guest_iface\" udp dport 67  accept" \
  "iifname \"$guest_iface\" udp dport 68  accept" \
  "iifname \"$guest_iface\" udp dport 53  accept" \
  "iifname \"$guest_iface\" tcp dport 53  accept" \
  "iifname \"$guest_iface\" udp dport 123 accept"; do
  nft insert rule inet filter input handle "$drop_handle" $rule
done

fwd_rule="iifname \"$guest_iface\" oifname \"$outside_if\" ct state new accept"
nft add rule inet filter forward position "$(get_forward_handle)" $fwd_rule

dialog --msgbox \
  "Guest interface $guest_iface ready!\n\n\
INPUT: DHCP(67,68), DNS(53), NTP(123) inserted below established,related accept\n\
FORWARD: guest → outside inserted below established,related accept\n\n\
Other traffic is dropped by policy." \
 12 75

clear
echo "Guest VLAN setup complete."
