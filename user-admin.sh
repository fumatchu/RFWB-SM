#!/bin/bash

# Paths
USER_MAP="/var/lib/user-admin/user-map.txt"
GROUP_LIST="/var/lib/user-admin/groups.txt"
USER_GROUPS="/var/lib/user-admin/user-groups.txt"
RADIUS_USERS="/etc/raddb/mods-config/files/authorize"
RADIUS_SITE="/etc/raddb/sites-enabled/default"
RADIUS_MOD="/etc/raddb/mods-enabled/files"
DEFAULT_GROUP="default-users"
TEMPFILE=$(mktemp)

# Ensure base directories exist
mkdir -p "$(dirname "$USER_MAP")"
touch "$USER_MAP" "$GROUP_LIST" "$USER_GROUPS"
touch "$RADIUS_USERS"

cleanup() {
    [ -f "$TEMPFILE" ] && rm -f "$TEMPFILE"
}
trap cleanup EXIT

# --- Ensure permissions and config ---
ensure_permissions_and_config() {
    chown root:radiusd "$RADIUS_USERS"
    chmod 640 "$RADIUS_USERS"

    if ! grep -q '^[[:space:]]*files' "$RADIUS_SITE"; then
        dialog --msgbox "Warning: 'files' module is not enabled in $RADIUS_SITE under 'authorize'. Add it manually to use flat file auth." 10 60
    fi

    if [ ! -e "$RADIUS_MOD" ]; then
        dialog --msgbox "Warning: 'files' module is not enabled (no symlink at $RADIUS_MOD). Run:\n\nln -s ../mods-available/files $RADIUS_MOD" 10 60
    fi
}

# --- Main menu ---
main_menu() {
    ensure_permissions_and_config

    while true; do
        dialog --clear --backtitle "FreeRADIUS User Admin" \
        --title "Main Menu" \
        --menu "Choose an option:" 15 50 6 \
        1 "Create Group" \
        2 "Create FreeRADIUS User" \
        3 "List Users and Groups" \
        4 "Delete User" \
        5 "Exit" 2>"$TEMPFILE"

        CHOICE=$(<"$TEMPFILE")
        case "$CHOICE" in
            1) create_group ;;
            2) create_radius_user ;;
            3) list_users ;;
            4) delete_user ;;
            5) clear; exit ;;
        esac
    done
}

# --- Group creation ---
create_group() {
    dialog --inputbox "Enter new group name:" 8 40 2>"$TEMPFILE"
    GROUP=$(<"$TEMPFILE")

    if grep -qx "$GROUP" "$GROUP_LIST"; then
        dialog --msgbox "Group already exists." 6 30
    elif [[ -n "$GROUP" ]]; then
        echo "$GROUP" >> "$GROUP_LIST"
        dialog --msgbox "Group '$GROUP' created." 6 30
    fi
}

# --- Radius user creation ---
create_radius_user() {
    dialog --inputbox "Enter new FreeRADIUS username:" 8 40 2>"$TEMPFILE"
    USERNAME=$(<"$TEMPFILE")

    if grep -q "^$USERNAME[[:space:]]" "$RADIUS_USERS"; then
        dialog --msgbox "User already exists in RADIUS file." 6 40
        return
    fi

    dialog --insecure --passwordbox "Enter password for $USERNAME:" 8 40 2>"$TEMPFILE"
    PASSWORD=$(<"$TEMPFILE")

    # Build checklist
    OPTIONS=()
    while IFS= read -r GROUP; do
        OPTIONS+=("$GROUP" "" off)
    done < "$GROUP_LIST"

    if [ ${#OPTIONS[@]} -eq 0 ]; then
        dialog --msgbox "No groups defined. Using default group '$DEFAULT_GROUP'." 6 50
        echo "$DEFAULT_GROUP" >> "$GROUP_LIST"
        GROUPS="$DEFAULT_GROUP"
    else
        dialog --checklist "Select group(s) for this user:" 15 50 8 "${OPTIONS[@]}" 2>"$TEMPFILE"
        GROUPS=$(<"$TEMPFILE" | tr -d '"')
        [[ -z "$GROUPS" ]] && GROUPS="$DEFAULT_GROUP"
    fi

    # Write to temp, then atomically append to RADIUS users file
    {
        echo "$USERNAME Cleartext-Password := \"$PASSWORD\""
        echo "    Group-Name := \"$GROUPS\""
        echo
    } > "${TEMPFILE}.entry"

    cat "${TEMPFILE}.entry" >> "$RADIUS_USERS" && rm -f "${TEMPFILE}.entry"
    echo "$USERNAME:radius" >> "$USER_MAP"
    echo "$USERNAME:$GROUPS" >> "$USER_GROUPS"

    dialog --msgbox "User '$USERNAME' created and added to group(s): $GROUPS" 7 60
}

# --- List users and groups ---
list_users() {
    {
        echo "--- Users ---"
        [ -s "$USER_MAP" ] && column -t -s ':' "$USER_MAP" || echo "No users."
        echo ""
        echo "--- Group Membership ---"
        [ -s "$USER_GROUPS" ] && column -t -s ':' "$USER_GROUPS" || echo "No group assignments."
        echo ""
        echo "--- Groups ---"
        [ -s "$GROUP_LIST" ] && cat "$GROUP_LIST" || echo "No groups created."
    } > "$TEMPFILE"
    dialog --textbox "$TEMPFILE" 20 60
}

# --- Delete user ---
delete_user() {
    dialog --inputbox "Enter username to delete:" 8 40 2>"$TEMPFILE"
    USERNAME=$(<"$TEMPFILE")

    if ! grep -q "^$USERNAME:" "$USER_MAP"; then
        dialog --msgbox "User not found." 6 30
        return
    fi

    sed -i "/^$USERNAME[[:space:]]/,+1d" "$RADIUS_USERS"
    sed -i "/^$USERNAME:/d" "$USER_MAP"
    sed -i "/^$USERNAME:/d" "$USER_GROUPS"
    dialog --msgbox "User '$USERNAME' deleted." 6 30
}

main_menu
