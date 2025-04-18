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
  # ─── Step 1: Pick an interface ───────────────────────────────────────────────
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

  menu=()
  for iface in "${IFACES[@]}"; do
    menu+=( "$iface" "" )
  done

  TMPFILE_IFACE=$(mktemp)
  trap 'rm -f "$TMPFILE_IFACE"' EXIT

  dialog --clear --title "Open Port Wizard" \
    --menu "Step 1: Select interface" 15 50 "${#IFACES[@]}" \
    "${menu[@]}" 2> "$TMPFILE_IFACE"
  if [[ $? -ne 0 ]]; then
    dialog --msgbox "Cancelled." 6 50
    continue
  fi
  IFACE=$(< "$TMPFILE_IFACE")

  # ─── Step 2: Pick protocol (radiolist!) ─────────────────────────────────────
  TMPFILE_PROTO=$(mktemp)
  trap 'rm -f "$TMPFILE_PROTO"' EXIT

  dialog --clear --title "Open Port Wizard" \
    --radiolist "Step 2: Select protocol (use ←/→ keys):" 10 50 2 \
      tcp "TCP (stream)" on \
      udp "UDP (datagram)" off \
      2> "$TMPFILE_PROTO"
  if [[ $? -ne 0 ]]; then
    dialog --msgbox "Cancelled." 6 50
    continue
  fi
  PROTO=$(< "$TMPFILE_PROTO")

  # ─── Step 3: Enter port or range ─────────────────────────────────────────────
  TMPFILE_PORT=$(mktemp)
  trap 'rm -f "$TMPFILE_PORT"' EXIT

  dialog --clear --title "Open Port Wizard" \
    --inputbox "Step 3: Enter port or port‑range\n(e.g. 80 or 8000-8100):" 8 50 2> "$TMPFILE_PORT"
  if [[ $? -ne 0 ]]; then
    dialog --msgbox "Cancelled." 6 50
    continue
  fi
  PORT=$(< "$TMPFILE_PORT")

  # ─── Apply the rule just after the threat_block drop ────────────────────────
  RULE="iifname \"$IFACE\" $PROTO dport $PORT accept"

  # Ensure chain is loaded
  if ! nft list chain inet filter input &>/dev/null; then
    nft -f "$CONFIG"
  fi

  # Check for existing rule to avoid duplicates
  if nft list chain inet filter input | grep -Fq "iifname \"$IFACE\" $PROTO dport $PORT accept"; then
    dialog --msgbox "ERROR: Rule already exists for $IFACE, $PROTO, port $PORT." 6 50
    continue
  fi

  # Find handle
  HANDLE=$(
    nft --handle list chain inet filter input |
      sed -n 's/.*ip saddr @threat_block drop.*# handle \([0-9]\+\).*/\1/p'
  )
  if [[ -z "$HANDLE" ]]; then
    dialog --msgbox "ERROR: Cannot find threat_block drop handle." 6 50
    continue
  fi

  # Insert rule
  if ! nft add rule inet filter input position "$HANDLE" "$RULE"; then
    dialog --msgbox "ERROR: failed to insert rule." 6 50
    continue
  fi

  # Show confirmation in dialog
  RESULT=$(nft list chain inet filter input | grep -F "$RULE")
  dialog --msgbox "✅ Inserted after handle $HANDLE:\n$RESULT" 10 70
done
