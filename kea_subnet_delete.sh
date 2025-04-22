DELETE A SUBNET for KEA

#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/kea/kea-dhcp4.conf"
BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
TMP="/tmp/kea-dhcp4.modified.json"
DIFF="/tmp/kea-dhcp4.diff.$(date +%s)"
MENU_HEIGHT=20
MENU_WIDTH=60

# Verify config exists
[[ ! -f "$CONFIG" ]] && { echo "[FAIL] Config not found: $CONFIG"; exit 1; }

# Extract list of comment labels
mapfile -t COMMENTS < <(jq -r '.Dhcp4.subnet4[] | select(.comment != null) | .comment' "$CONFIG")

if [[ ${#COMMENTS[@]} -eq 0 ]]; then
  dialog --msgbox "No subnets with comments found in config!" 6 50
  exit 1
fi

# Build menu
MENU_ITEMS=()
for comment in "${COMMENTS[@]}"; do
  subnet=$(jq -r --arg c "$comment" '.Dhcp4.subnet4[] | select(.comment == $c) | .subnet' "$CONFIG")
  MENU_ITEMS+=("$comment" "$subnet")
done

CHOICE=$(dialog --clear --title "Delete Subnet" \
  --menu "Choose subnet to delete:" $MENU_HEIGHT $MENU_WIDTH ${#MENU_ITEMS[@]} \
  "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)

[[ -z "$CHOICE" ]] && { echo "[INFO] Cancelled"; exit 0; }

dialog --yesno "Really delete subnet: $CHOICE?" 7 50
[[ $? -ne 0 ]] && { echo "[INFO] Aborted"; exit 0; }

# Backup original config
cp "$CONFIG" "$BACKUP"
echo "[INFO] Backup saved: $BACKUP"

# Remove subnet by comment
jq --arg c "$CHOICE" '
  .Dhcp4.subnet4 |= map(select(.comment != $c))
' "$CONFIG" > "$TMP"

# Validate modified config
if kea-dhcp4 -t "$TMP" 2> /tmp/kea_tmp_invalid.log; then
  echo "[SUCCESS] New config is valid."
else
  echo "[FAIL] Config broken after deletion:"
  cat /tmp/kea_tmp_invalid.log
  echo "[INFO] Restoring backup."
  exit 1
fi

# Show diff and prompt to apply
diff -u "$CONFIG" "$TMP" > "$DIFF" || true
dialog --yesno "Diff saved to $DIFF. Apply changes and reload Kea?" 10 60
[[ $? -ne 0 ]] && { echo "[INFO] Changes discarded."; exit 0; }

# Apply config and reload
cp "$TMP" "$CONFIG"
chmod 644 "$CONFIG"
systemctl restart kea-dhcp4 && echo "[SUCCESS] KEA restarted"
