#!/usr/bin/env bash
# guest_vlan_cleanup.sh — Clean up guest interface, DHCP scope, reverse DNS, and firewall rules
set -euo pipefail

CONFIG="/etc/sysconfig/nftables.conf"
BACKUP_DIR="/etc/sysconfig"
BACKUP_FILE="$BACKUP_DIR/nftables.conf.bak.$(date +%Y%m%d%H%M%S)"
KEA_CONFIG="/etc/kea/kea-dhcp4.conf"
KEA_DDNS_CONFIG="/etc/kea/kea-dhcp-ddns.conf"
NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named"

# ───── Helpers ─────
die(){ echo "$*" >&2; exit 1; }
backup_nft(){ [[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"; cp "$CONFIG" "$BACKUP_FILE"; }
get_input_logdrop_handle(){ nft --handle list chain inet filter input | sed -n 's/.*log prefix "INPUT DROP: " drop.*# handle \([0-9]\+\).*/\1/p'; }

# ───── Cleanup Guest Scope and Interface ─────
remove_guest_interface_and_scope() {
  local con_name iface cidr

  con_name=$(nmcli -t -f NAME connection show | awk -F: '$1=="guest" || $1 ~ /-guest$/ {print $1; exit}')
  [ -z "$con_name" ] && { echo "No guest connection found."; return 1; }

  iface=$(nmcli -g GENERAL.DEVICES connection show "$con_name" | head -n1)
  cidr=$(nmcli -g IP4.ADDRESS connection show "$con_name" | awk -F/ '{print $1"/"$2}')

  echo "Removing guest scope for interface: $iface ($cidr)"

  # Remove firewall rules
  backup_nft
  mapfile -t IN_HANDLES < <(nft --handle list chain inet filter input | grep "iifname \"$iface\"" | awk '{print $NF}')
  for h in "${IN_HANDLES[@]}"; do nft delete rule inet filter input handle "$h" 2>/dev/null || :; done

  outside_if=$(nmcli -t -f DEVICE,NAME connection show --active 2>/dev/null | awk -F: '$2 ~ /-outside$/ {print $1; exit}')
  if [[ -n "$outside_if" ]]; then
    mapfile -t FW_HANDLES < <(nft --handle list chain inet filter forward | grep "iifname \"$iface\" oifname \"$outside_if\"" | awk '{print $NF}')
    for h in "${FW_HANDLES[@]}"; do nft delete rule inet filter forward handle "$h" 2>/dev/null || :; done
  fi

  # Delete the guest connection
  nmcli connection delete "$con_name" || :

  # Remove DHCP subnet
  tmpconf=$(mktemp)
  jq --arg iface "$iface" '.Dhcp4.subnet4 |= map(select(.interface != $iface))' "$KEA_CONFIG" > "$tmpconf" && mv "$tmpconf" "$KEA_CONFIG"

  # Remove reverse DNS zone from kea-dhcp-ddns
  rev_zone=$(echo "$cidr" | cut -d/ -f1 | awk -F. '{print $3"."$2"."$1}').in-addr.arpa.
  tmpddns=$(mktemp)
  jq --arg zone "$rev_zone" '.DhcpDdns["reverse-ddns"]["ddns-domains"] |= map(select(.name != $zone))' "$KEA_DDNS_CONFIG" > "$tmpddns" && mv "$tmpddns" "$KEA_DDNS_CONFIG"

# Remove from named.conf
tmpnamed=$(mktemp)
sed "/zone \"$rev_zone\" {/,/^};/d" "$NAMED_CONF" > "$tmpnamed"
sed -i "/zone \"${rev_zone%.}\" {/,/^};/d" "$tmpnamed"
mv "$tmpnamed" "$NAMED_CONF"


  # Remove zone file
  zone_file="$ZONE_DIR/db.${rev_zone%.in-addr.arpa.}"
  [ -f "$zone_file" ] && rm -f "$zone_file"

  # Restore permissions and context
  chown kea:kea "$KEA_CONFIG" "$KEA_DDNS_CONFIG"
  chmod 640 "$KEA_CONFIG" "$KEA_DDNS_CONFIG"
  chown named:named "$NAMED_CONF"
  chmod 640 "$NAMED_CONF"
  restorecon "$KEA_CONFIG" "$KEA_DDNS_CONFIG" "$NAMED_CONF"

  # Restart services
  systemctl restart kea-dhcp4 kea-dhcp-ddns named || {
    echo "[ERROR] One or more services failed to restart. Check logs."; exit 1;
  }

  echo "[SUCCESS] Guest scope cleanup completed."
}

# Entry point
remove_guest_interface_and_scope
