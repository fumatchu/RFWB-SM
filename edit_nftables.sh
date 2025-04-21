#!/usr/bin/env bash
set -e

# Must be root
if (( EUID != 0 )); then
  echo "Please run as root." >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# Helpers to detect real interfaces via nmcli
find_interface() {
  nmcli -t -f DEVICE,CONNECTION device status \
    | awk -F: '$2 ~ /-inside$/ { print $1; exit }'
}
find_sub_interfaces() {
  local main=$1
  nmcli -t -f DEVICE device status \
    | grep -E "^${main}\\.[0-9]+" \
    | cut -d: -f1
}
find_outside() {
  nmcli -t -f DEVICE,CONNECTION device status \
    | awk -F: '$2 ~ /-outside$/ { print $1; exit }'
}

# Helper to center text
center_text() {
  local text="$1" width="$2" len padL padR
  len=${#text}
  (( width < len )) && width=$len
  padL=$(((width-len)/2)); padR=$((width-len-padL))
  printf "%*s%s%*s" "$padL" "" "$text" "$padR" ""
}

# ──────────────────────────────────────────────────────────────────────────────
# show_traffic_diagram (your original, unchanged logic)
show_traffic_diagram() {
  # 1) Build interface list
  local INSIDE=$(find_interface)
  local VLANS=($(find_sub_interfaces "$INSIDE"))
  local OUTSIDE=$(find_outside)
  local IFACES=("$INSIDE" "${VLANS[@]}" "$OUTSIDE")
  [[ -e /sys/class/net/tun0 ]] && IFACES+=("tun0")

  if [[ ${#IFACES[@]} -eq 0 || -z "${IFACES[0]}" ]]; then
    dialog --msgbox "Error: No network interfaces found." 10 50
    return 1
  fi

  # 2) Friendly labels via NMCLI
  declare -A friendly
  for dev in "${IFACES[@]}"; do
    [[ -z "$dev" ]] && continue
    local conn
    conn=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
                 | awk -F: -v d="$dev" '$2==d{print $1; exit}')
    case "$conn" in
      *-inside)  friendly[$dev]="Inside"  ;;
      *-outside) friendly[$dev]="Outside" ;;
      "" )       friendly[$dev]="$dev"    ;;
      * )        friendly[$dev]="$conn"   ;;
    esac
    [[ -z "${friendly[$dev]}" ]] && friendly[$dev]="$dev"
  done

  # 3) Parse forward-chain accept rules
  declare -A allowed
  if ! command -v nft &>/dev/null; then
    dialog --msgbox "Error: 'nft' command not found." 10 60
    return 1
  fi
  local out
  out=$(nft list chain inet filter forward 2>&1)
  if [[ $? -ne 0 ]]; then
    dialog --msgbox "Error running nft:\n\n$out" 15 70
    return 1
  fi
  while IFS= read -r line; do
    if [[ $line =~ iifname[[:space:]]+\"?([^\"]+)\"?.*oifname[[:space:]]+\"?([^\"]+)\"?.*accept ]]; then
      allowed["${BASH_REMATCH[1]},${BASH_REMATCH[2]}"]=1
    fi
  done < <(echo "$out" | sed 's/#.*//; s/[[:space:]]\+/ /g')

  # 4) Compute dimensions
  local roww=12 pad=1 maxlen=0
  for dev in "${IFACES[@]}"; do
    [[ -z "$dev" ]] && continue
    (( ${#friendly[$dev]} > maxlen )) && maxlen=${#friendly[$dev]}
  done
  (( maxlen<1 )) && maxlen=1
  local cellw=$((maxlen+pad*2))
  local totalw=$((roww + (cellw+1)*${#IFACES[@]} +1))

  # 5) Build matrix text
  local matrix="Connectivity Matrix (✓ = allowed):\n\n"
  matrix+="$(printf "%-${roww}s" "")"
  for dev in "${IFACES[@]}"; do
    matrix+="|$(center_text "${friendly[$dev]}" "$cellw")"
  done
  matrix+="|\n"
  matrix+="$(printf '%*s' "$totalw" '' | tr ' ' '-')\n"

  for src in "${IFACES[@]}"; do
    matrix+="$(printf "%-${roww}s" "${friendly[$src]}")"
    for dst in "${IFACES[@]}"; do
      local mark='-'
      [[ -v allowed["$src,$dst"] ]] && mark='✓'
      matrix+="|$(center_text "$mark" "$cellw")"
    done
    matrix+="|\n"
  done

  # 6) Show in a 40×140 dialog
  dialog --backtitle "Firewall Overview" \
         --title     "Traffic Flow Diagram" \
         --cr-wrap   \
         --msgbox    "$matrix" 40 140
}

# ──────────────────────────────────────────────────────────────────────────────
# Generic per-chain editor with backup/rollback/diff
edit_chain() {
  local spec="$1" chain="$2"
  local backup orig tmp err diff ret

  # backup entire table
  backup=$(mktemp /tmp/${spec// /_}_backup.XXXXXX)
  nft list table "$spec" >"$backup" 2>/dev/null

  orig=$(mktemp); tmp=$(mktemp); err=$(mktemp); diff=$(mktemp)

  # dump only that chain, strip nested header/footer
  {
    echo "table $spec {"
    nft list chain "$spec" "$chain" 2>>"$err" \
      | sed -e '/^table /d' -e '/^}$/d' -e 's/^/  /'
    echo "}"
  } >"$orig"

  # editbox → tmp
  dialog --backtitle "Firewall Overview" \
         --title     "Edit $spec / $chain" \
         --editbox   "$orig" 40 140 \
         2>"$tmp"
  ret=$?; (( ret!=0 )) && { rm -f "$backup" "$orig" "$tmp" "$err" "$diff"; return; }

  # flush chain
  if ! nft flush chain "$spec" "$chain" 2>>"$err"; then
    dialog --msgbox "Flush failed:\n\n$(<"$err")\nRolling back…" 12 70
    nft -f "$backup"
    diff -u "$backup" "$tmp" >"$diff"
    dialog --backtitle "Diff ($chain)" --textbox "$diff" 40 140
    rm -f "$backup" "$orig" "$tmp" "$err" "$diff"
    return
  fi

  # apply
  if nft -f "$tmp" 2>>"$err"; then
    dialog --msgbox "✅ $chain updated in $spec." 6 50
  else
    dialog --msgbox "Apply failed:\n\n$(<"$err")\nRolling back…" 12 70
    nft -f "$backup"
    diff -u "$backup" "$tmp" >"$diff"
    dialog --backtitle "Diff ($chain)" --textbox "$diff" 40 140
  fi

  rm -f "$backup" "$orig" "$tmp" "$err" "$diff"
}

# NAT prerouting/postrouting wrap
edit_nat_chain() {
  edit_chain "inet nat" "$1"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main menu
main_menu() {
  while true; do
    local choice
    choice=$(dialog --clear --backtitle "Firewall Overview" \
      --title "Main Menu" \
      --menu "Select an option:" 20 100 7 \
        1 "Edit FILTER INPUT"      \
        2 "Edit FILTER FORWARD"    \
        3 "Edit FILTER OUTPUT"     \
        4 "Edit NAT PREROUTING"    \
        5 "Edit NAT POSTROUTING"   \
        6 "Show Traffic Diagram"   \
        7 "Exit"                   \
      3>&1 1>&2 2>&3)

    case $choice in
      1) edit_chain     "inet filter" "input"      ;;
      2) edit_chain     "inet filter" "forward"    ;;
      3) edit_chain     "inet filter" "output"     ;;
      4) edit_nat_chain             "prerouting"   ;;
      5) edit_nat_chain             "postrouting"  ;;
      6) show_traffic_diagram                      ;;
      *) break                                     ;;
    esac
  done
  clear
}

main_menu
