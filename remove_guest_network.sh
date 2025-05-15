#!/usr/bin/env bash
# guest_vlan_cleanup_diagnostic.sh — Clean up guest interface, DHCP scope, reverse DNS, and firewall rules with dialog-only output

set -euo pipefail

CONFIG="/etc/sysconfig/nftables.conf"
BACKUP_DIR="/etc/sysconfig"
BACKUP_FILE="$BACKUP_DIR/nftables.conf.bak.$(date +%Y%m%d%H%M%S)"
KEA_CONFIG="/etc/kea/kea-dhcp4.conf"
KEA_DDNS_CONFIG="/etc/kea/kea-dhcp-ddns.conf"
NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named"

backup_nft(){ [[ -f "$CONFIG" ]] || exit 1; cp "$CONFIG" "$BACKUP_FILE"; }

remove_guest_interface_and_scope() {
  local con_name iface vip ip_addr cidr_prefix cidr_base cidr rev_base zone_name_ddns zone_name_bind

  con_name=$(nmcli -t -f NAME connection show | awk -F: '$1=="guest" || $1 ~ /-guest$/ {print $1; exit}')
  [ -z "$con_name" ] && dialog --msgbox "No guest connection found." 6 40 && return 1

  iface=$(nmcli -g GENERAL.DEVICES connection show "$con_name" | head -n1)
  vip=$(nmcli -g IP4.ADDRESS connection show "$con_name" | head -n1)

  if [[ -n "$vip" && "$vip" == */* ]]; then
    ip_addr="${vip%/*}"
    cidr_prefix="${vip#*/}"
    IFS='.' read -r o1 o2 o3 _ <<< "$ip_addr"
    cidr_base="$o1.$o2.$o3.0"
    cidr="$cidr_base/$cidr_prefix"
  else
    cidr=""
  fi

  rev_base=$(echo "$cidr" | cut -d/ -f1 | awk -F. '{print $3"."$2"."$1}')
  zone_name_ddns="$rev_base.in-addr.arpa."
  zone_name_bind="$rev_base.in-addr.arpa"

  backup_nft
  mapfile -t IN_HANDLES < <(nft --handle list chain inet filter input | grep "iifname \"$iface\"" | awk '{print $NF}')
  for h in "${IN_HANDLES[@]}"; do nft delete rule inet filter input handle "$h" 2>/dev/null || :; done

  outside_if=$(nmcli -t -f DEVICE,NAME connection show --active 2>/dev/null | awk -F: '$2 ~ /-outside$/ {print $1; exit}')
  if [[ -n "$outside_if" ]]; then
    mapfile -t FW_HANDLES < <(nft --handle list chain inet filter forward | grep "iifname \"$iface\" oifname \"$outside_if\"" | awk '{print $NF}')
    for h in "${FW_HANDLES[@]}"; do nft delete rule inet filter forward handle "$h" 2>/dev/null || :; done

    nft --handle list chain inet filter forward_internet | while read -r line; do
      if [[ "$line" == *"ip saddr $cidr"* && "$line" == *"iifname \"$iface\""* && "$line" == *"oifname \"$outside_if\""* ]]; then
        handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]\+\)$/\1/p')
        [[ -n "$handle" ]] && nft delete rule inet filter forward_internet handle "$handle" 2>/dev/null || :
      fi
    done
  fi

  nmcli connection delete "$con_name" || :

  tmpconf=$(mktemp)
  jq --arg iface "$iface" '.Dhcp4.subnet4 |= map(select(.interface != $iface))' "$KEA_CONFIG" > "$tmpconf"
  mv "$tmpconf" "$KEA_CONFIG"

  tmpddns=$(mktemp)
  jq --arg zone "$zone_name_ddns" '.DhcpDdns["reverse-ddns"]["ddns-domains"] |= map(select(.name != $zone))' "$KEA_DDNS_CONFIG" > "$tmpddns"
  mv "$tmpddns" "$KEA_DDNS_CONFIG"

  tmpnamed=$(mktemp)
  awk -v zone="$zone_name_bind" '
    $0 ~ "^[[:space:]]*zone[[:space:]]+\"" zone "\"[[:space:]]*\\{" { skip=1; next }
    skip && /^[[:space:]]*};/ { skip=0; next }
    skip { next }
    { print }
  ' "$NAMED_CONF" > "$tmpnamed"

  if ! cmp -s "$NAMED_CONF" "$tmpnamed"; then
    mv "$tmpnamed" "$NAMED_CONF"
  else
    rm -f "$tmpnamed"
  fi

  zone_file="$ZONE_DIR/db.${rev_base}"
  [[ -f "$zone_file" ]] && rm -f "$zone_file"

  chown kea:kea "$KEA_CONFIG" "$KEA_DDNS_CONFIG"
  chmod 640 "$KEA_CONFIG" "$KEA_DDNS_CONFIG"
  chown named:named "$NAMED_CONF"
  chmod 640 "$NAMED_CONF"
  restorecon "$KEA_CONFIG" "$KEA_DDNS_CONFIG" "$NAMED_CONF"

  systemctl restart kea-dhcp4 kea-dhcp-ddns named || {
    dialog --msgbox "ERROR: One or more services failed to restart. Check logs." 6 60
    exit 1
  }

  TMP_NFT=$(mktemp)
  nft list ruleset > "$TMP_NFT"
  if nft -c -f "$TMP_NFT" &>/dev/null; then
    cp "$TMP_NFT" "$CONFIG"
    chmod 600 "$CONFIG"
    restorecon "$CONFIG"
  else
    cp "$BACKUP_FILE" "$CONFIG"
    restorecon "$CONFIG"
  fi
  rm -f "$TMP_NFT"

  dialog --msgbox "Guest VLAN cleanup completed successfully." 6 50
}

# Entry point
remove_guest_interface_and_scope
