GUEST SETUP VLAN
#!/usr/bin/env bash
#
# guest_vlan_setup.sh
# ──────────────────────────────────────────────────────────────────────────────
# Dialog‑driven setup/reset for a “Guest” interface + nftables lockdown:
#  • On existing guest iface, optionally reset (cleanup old rules & conns)
#  • Create new guest (physical or VLAN)
#  • Allow ONLY DHCP, DNS, NTP on INPUT, and guest→outside in FORWARD,
#    each inserted just below the matching ct/threat rules.
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

# Get handle of the threat_block drop in INPUT
get_input_handle(){
  nft --handle list chain inet filter input \
    | sed -n 's/.*ip saddr @threat_block drop.*# handle \([0-9]\+\).*/\1/p'
}

# NEW: Get handle of the established,related accept in INPUT
get_input_est_handle(){
  nft --handle list chain inet filter input \
    | sed -n 's/.*ct state established,related accept.*# handle \([0-9]\+\).*/\1/p'
}

# Get handle of the established,related accept in FORWARD
get_forward_handle(){
  nft --handle list chain inet filter forward \
    | sed -n 's/.*ct state established,related accept.*# handle \([0-9]\+\).*/\1/p'
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

    # Remove all INPUT rules for this guest_iface
    mapfile -t IN_HANDLES < <(
      nft --handle list chain inet filter input \
        | grep "iifname \"$guest_iface\"" \
        | awk '{print $NF}'
    )
    for h in "${IN_HANDLES[@]}"; do
      nft delete rule inet filter input handle "$h" 2>/dev/null || :
    done

    # Remove all FORWARD rules for guest_iface → outside
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

    # Clean up the old connection profile
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
  1)  # Physical
    dialog --msgbox "Unplug your spare port, click OK, then plug it in." 8 50
    mapfile -t OLD < <(
      nmcli -t -f DEVICE,STATE device status \
        | awk -F: '$2=="connected"{print $1}'
    )
    dialog --infobox "Waiting for guest port…" 5 50
    while :; do
      mapfile -t NOW < <(
        nmcli -t -f DEVICE,STATE device status \
          | awk -F: '$2=="connected"{print $1}'
      )
      for i in "${NOW[@]}"; do
        [[ ! " ${OLD[*]} " =~ " $i " ]] && { guest_iface="$i"; break 2; }
      done
      sleep .5
    done
    dialog --infobox "Detected: $guest_iface" 6 50; sleep 1
    prof=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
      | awk -F: -v d="$guest_iface" '$2==d{print $1}')
    nmcli connection modify "$prof" connection.id "${prof}-guest"
    nmcli connection up "${prof}-guest"
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

# INPUT chain: insert DHCP, DNS, and NTP rules *after* established,related accept
for rule in \
  "iifname \"$guest_iface\" udp dport 67  accept" \
  "iifname \"$guest_iface\" udp dport 68  accept" \
  "iifname \"$guest_iface\" udp dport 53  accept" \
  "iifname \"$guest_iface\" tcp dport 53  accept" \
  "iifname \"$guest_iface\" udp dport 123 accept"; do
  nft add rule inet filter input position "$(get_input_est_handle)" $rule
done

# FORWARD chain: insert guest→outside *after* established,related accept
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
