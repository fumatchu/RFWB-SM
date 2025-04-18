#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/sysconfig/nftables.conf"
BACKUP="/etc/sysconfig/nftables.conf.bak.$(date +%Y%m%d%H%M%S)"

# ─── Backup ──────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
  dialog --msgbox "ERROR: $CONFIG not found." 6 50
  exit 1
fi
cp "$CONFIG" "$BACKUP"

while true; do
  # ─── Step 1: Pick an interface ───────────────────────────────────────────────
  mapfile -t IFACES < <(
    ip -o link show |
      awk -F': ' '/^[0-9]+: /{print $2}' |
      grep -Ev '^(lo|tun)' |
      sed 's/@.*//'
  )
  if (( ${#IFACES[@]} == 0 )); then
    dialog --msgbox "ERROR: no interfaces found." 6 50
    exit 1
  fi

  MENU=()
  for iface in "${IFACES[@]}"; do
    MENU+=( "$iface" "" )
  done

  dialog --clear --title "Open Port Wizard" \
    --menu "Step 1: Select interface" 15 50 "${#IFACES[@]}" \
    "${MENU[@]}" 2> /tmp/_iface
  if [[ $? -ne 0 ]]; then
    dialog --msgbox "Cancelled." 6 50
    continue
  fi
  IFACE=$(< /tmp/_iface); rm -f /tmp/_iface

  # ─── Step 2: Pick protocol ───────────────────────────────────────────────────
  dialog --clear --title "Open Port Wizard" \
    --radiolist "Step 2: Select protocol (←/→ to toggle):" 10 50 2 \
      tcp "TCP (stream)" on \
      udp "UDP (datagram)" off \
      2> /tmp/_proto
  if [[ $? -ne 0 ]]; then
    dialog --msgbox "Cancelled." 6 50
    continue
  fi
  PROTO=$(< /tmp/_proto); rm -f /tmp/_proto

  # ─── Step 3: Enter port or range ─────────────────────────────────────────────
  dialog --clear --title "Open Port Wizard" \
    --inputbox "Step 3: Enter port or range (e.g. 80 or 8000-8100):" 8 50 2> /tmp/_port
  if [[ $? -ne 0 ]]; then
    dialog --msgbox "Cancelled." 6 50
    continue
  fi
  PORT=$(< /tmp/_port); rm -f /tmp/_port

  # ─── Prepare the rule ────────────────────────────────────────────────────────
  RULE="iifname \"$IFACE\" $PROTO dport $PORT accept"

  # Ensure the chain is loaded
  if ! nft list chain inet filter input &>/dev/null; then
    nft -f "$CONFIG"
  fi

  # Avoid duplicates
  if nft list chain inet filter input | grep -Fq "$RULE"; then
    dialog --msgbox "ERROR: Rule already exists for $IFACE, $PROTO port $PORT." 6 50
    continue
  fi

  # ─── Find handle of the established,related rule ─────────────────────────────
  HANDLE=$(
    nft --handle list chain inet filter input \
      | sed -n 's/.*ct state established,related accept.*# handle \([0-9]\+\).*/\1/p'
  )
  if [[ -z "$HANDLE" ]]; then
    dialog --msgbox "ERROR: Cannot find handle for established,related accept." 6 50
    continue
  fi

  # ─── Insert the rule after that handle ───────────────────────────────────────
  if ! nft add rule inet filter input position "$HANDLE" $RULE; then
    dialog --msgbox "ERROR: Failed to insert rule." 6 50
    continue
  fi

  # ─── Confirmation ────────────────────────────────────────────────────────────
  RESULT=$(nft list chain inet filter input | grep -F "$RULE")
  dialog --msgbox "✅ Inserted after handle $HANDLE:\n$RESULT" 10 70
done
