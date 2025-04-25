#!/usr/bin/env bash
#######COMPLETE#########
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named"
STAGING_DIR="/tmp/dns-admin-staging"
mkdir -p "$STAGING_DIR"

# ─── named Service Control ───────────────────────────────────────────────────
named_service_menu() {
  while true; do
    exec 3>&1; set +e
    choice=$(dialog --clear \
      --title "named Service Control" \
      --menu "Choose an action (Cancel→main menu):" 20 60 4 \
      1 "Show service status" \
      2 "View recent logs" \
      3 "Restart named" \
      4 "Back to Main Menu" \
      2>&1 1>&3)
    rc=$?; set -e; exec 3>&-
    [ $rc -ne 0 ] && break

    case $choice in
      1)
        systemctl status named --no-pager | fold -s -w 110 > /tmp/named_status.txt
        dialog --title "named Service Status" --textbox /tmp/named_status.txt 30 120
        ;;
      2)
        journalctl -u named -n 200 --no-pager > /tmp/named_journal.log
        dialog --title "named Logs (last 200 lines)" --tailbox /tmp/named_journal.log 30 120
        ;;
      3)
        systemctl restart named
        dialog --msgbox "named restarted successfully." 6 50
        ;;
      4) break ;;
    esac
  done
}


# ─── Utility Functions ────────────────────────────────────────────────────────

list_zones() {
  grep 'zone\s\+"' "$NAMED_CONF" | cut -d'"' -f2
}

validate_zone_name() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]
}

show_zones() {
  mapfile -t zones < <(list_zones)
  if [ ${#zones[@]} -eq 0 ]; then
    dialog --msgbox "No zones defined." 6 40
  else
    msg=$(printf "• %s\n" "${zones[@]}")
    dialog --title "All Defined Zones" --msgbox "$msg" 20 60
  fi
}

finalize_file() {
  local file="$1"
  chown named:named "$file"
  chmod 640 "$file"
  restorecon "$file"
}

increment_soa_serial() {
  local file="$1"
  awk '
    BEGIN { in_soa=0; updated=0 }
    /SOA/ { in_soa=1 }
    in_soa && /[0-9]+[ 	]*;[ 	]*serial/ && !updated {
      sub(/[0-9]+/, $1+1)
      updated=1
    }
    /)/ && in_soa { in_soa=0 }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}


# ─── Zone‑Management Handlers ─────────────────────────────────────────────────

add_zone() {
  rm -f "$STAGING_DIR"/db.* "$STAGING_DIR"/*.db.*
  while true; do
    exec 3>&1
    zone=$(dialog --inputbox "New forward zone (e.g. example.com):" 8 50 2>&1 1>&3)
    exec 3>&-
    [ -z "$zone" ] && return
    if ! validate_zone_name "$zone"; then
      dialog --msgbox "Invalid zone name." 6 40
      continue
    fi
    grep -q "zone \"$zone\"" "$NAMED_CONF" && dialog --yesno "Zone exists. Try another?" 7 50 && continue || break
  done

  host=$(hostnamectl status | awk '/Static hostname:/ {print $3}')
  name="${host%%.*}"
  ip=$(hostname -I | awk '{print $1}')

  cat > "$ZONE_DIR/db.$zone" <<EOF
\$TTL 86400
@ IN SOA $host. admin.$zone. (
    2023100501 ; serial
    3600       ; refresh
    1800       ; retry
    604800     ; expire
    86400      ; minimum
)
@ IN NS $host.
$name IN A $ip
EOF

  printf "\nzone \"%s\" {\n    type master;\n    file \"/var/named/db.%s\";\n    allow-update { key \"Kea-DDNS\"; };\n};\n" "$zone" "$zone" >> "$NAMED_CONF"

  finalize_file "$ZONE_DIR/db.$zone"
  finalize_file "$NAMED_CONF"
  rndc freeze "$zone" || true
  systemctl reload named || rndc reload || true
  rndc thaw "$zone" || true

  dialog --msgbox "Zone '$zone' created and applied." 6 50
}

delete_zone() {
  mapfile -t zones < <(list_zones | grep -v '\.in-addr\.arpa')
  if [ ${#zones[@]} -eq 0 ]; then
    dialog --msgbox "No forward zones found to delete." 6 40
    return
  fi

  menu_args=()
  for z in "${zones[@]}"; do menu_args+=( "$z" "$z" ); done

  exec 3>&1
  selected_zone=$(dialog --clear --title "Delete forward zone" --menu "Select a zone to delete:" 20 60 10 "${menu_args[@]}" 2>&1 1>&3)
  sel_rc=$?; exec 3>&-
  [ $sel_rc -ne 0 ] || [ -z "$selected_zone" ] && return

  dialog --yesno "Are you sure you want to delete forward zone '$selected_zone'?" 7 50 || return

  rndc freeze "$selected_zone" || true

  awk -v zone="$selected_zone" '
    $0 ~ "zone \"" zone "\"" { skip=1; next }
    skip && /^};/ { skip=0; next }
    skip { next }
    { print }
  ' "$NAMED_CONF" > "$STAGING_DIR/named.conf"

  mv "$STAGING_DIR/named.conf" "$NAMED_CONF"
  rm -f "$ZONE_DIR/db.${selected_zone}"
  finalize_file "$NAMED_CONF"
  systemctl reload named || rndc reload || true
  rndc thaw "$selected_zone" || true

  dialog --msgbox "Forward zone '$selected_zone' deleted and BIND reloaded." 6 50
}

add_reverse_zone() {
  rm -f "$STAGING_DIR"/db.* "$STAGING_DIR"/*.db.*
  while true; do
    exec 3>&1
    base=$(dialog --inputbox "Reverse base (e.g. 192.168.100.0):" 8 50 2>&1 1>&3)
    exec 3>&-
    [ -z "$base" ] && return
    rev=$(echo "$base" | awk -F. '{print $3"."$2"."$1}')
    full="$rev.in-addr.arpa"
    grep -q "zone \"$full\"" "$NAMED_CONF" && dialog --yesno "Zone exists. Try another?" 7 50 && continue || break
  done

  host=$(hostnamectl status | awk '/Static hostname:/ {print $3}')
  last=${base##*.}

  cat > "$ZONE_DIR/db.$rev" <<EOF
\$TTL 86400
@ IN SOA $host. admin.localdomain. (
    2023100501 ; serial
    3600       ; refresh
    1800       ; retry
    604800     ; expire
    86400      ; minimum
)
@ IN NS $host.
$last IN PTR $host.
EOF

  printf "\nzone \"%s\" {\n    type master;\n    file \"/var/named/db.%s\";\n    allow-update { key \"Kea-DDNS\"; };\n};\n" "$full" "$rev" >> "$NAMED_CONF"

  finalize_file "$ZONE_DIR/db.$rev"
  finalize_file "$NAMED_CONF"
  rndc freeze "$full" || true
  systemctl reload named || rndc reload || true
  rndc thaw "$full" || true

  dialog --msgbox "Reverse zone '$full' created and applied." 6 50
}
delete_reverse_zone() {
  mapfile -t zones < <(list_zones | grep '\.in-addr\.arpa')
  if [ ${#zones[@]} -eq 0 ]; then
    dialog --msgbox "No reverse zones found to delete." 6 40
    return
  fi

  menu_args=()
  for z in "${zones[@]}"; do menu_args+=( "$z" "$z" ); done

  exec 3>&1
  selected_zone=$(dialog --clear --title "Delete reverse zone" --menu "Select a reverse zone to delete:" 20 60 10 "${menu_args[@]}" 2>&1 1>&3)
  sel_rc=$?; exec 3>&-
  [ $sel_rc -ne 0 ] || [ -z "$selected_zone" ] && return

  dialog --yesno "Are you sure you want to delete reverse zone '$selected_zone'?" 7 50 || return

  rndc freeze "$selected_zone" || true

  awk -v zone="$selected_zone" '
    $0 ~ "zone \"" zone "\"" { skip=1; next }
    skip && /^};/ { skip=0; next }
    skip { next }
    { print }
  ' "$NAMED_CONF" > "$STAGING_DIR/named.conf"

  mv "$STAGING_DIR/named.conf" "$NAMED_CONF"
  rm -f "$ZONE_DIR/db.${selected_zone%.in-addr.arpa}"
  finalize_file "$NAMED_CONF"
  systemctl reload named || rndc reload || true
  rndc thaw "$selected_zone" || true

  dialog --msgbox "Reverse zone '$selected_zone' deleted and BIND reloaded." 6 50
}

# ─── Manual Edit Function ─────────────────────────────────────────────────────
edit_dns_records() {
  while true; do
    mapfile -t zones < <(list_zones)
    [ ${#zones[@]} -gt 0 ] || { dialog --msgbox "No zones to edit." 6 40; return; }
    menu=(); for z in "${zones[@]}"; do menu+=( "$z" "$z" ); done

    exec 3>&1; set +e
    sel=$(dialog --clear --title "Select zone" --menu "Cancel→back:" 20 60 10 \
          "${menu[@]}" 2>&1 1>&3)
    rc=$?; set -e; exec 3>&-
    [ $rc -ne 0 ] && return

    file=$([[ "$sel" =~ \.in-addr\.arpa$ ]] \
           && echo "$ZONE_DIR/db.${sel%.in-addr.arpa}" \
           || echo "$ZONE_DIR/db.$sel")
    [ -f "$file" ] || { dialog --msgbox "Not found." 6 40; continue; }

    rndc freeze "$sel" >/dev/null 2>&1 || true
    tmp=$(mktemp); cp "$file" "$tmp"; out=$(mktemp)

    exec 3>&1; set +e
    dialog --clear --title "Editing $sel" --editbox "$tmp" 25 80 \
      2>"$out" 1>&3
    erc=$?; set -e; exec 3>&-
    rm -f "$tmp"
    if [ $erc -eq 0 ]; then
      mv "$out" "$file"
      finalize_file "$file"
      systemctl reload named || rndc reload || true
      dialog --msgbox "Zone '$sel' updated and applied." 6 50
    else
      rm -f "$out"
    fi
    rndc thaw "$sel" >/dev/null 2>&1 || true
  done
}

# ─── Structured Record Manager ───────────────────────────────────────────────
manage_dns_records() {
  while true; do
    mapfile -t zones < <(list_zones)
    [ ${#zones[@]} -eq 0 ] && { dialog --msgbox "No DNS zones found." 6 40; return; }

    menu_args=(); for z in "${zones[@]}"; do menu_args+=( "$z" "$z" ); done
    exec 3>&1; set +e
    selected_zone=$(dialog --clear --title "Manage DNS Records" --menu "Select a zone (Cancel→main menu):" 20 60 10 "${menu_args[@]}" 2>&1 1>&3)
    sel_rc=$?; set -e; exec 3>&-
    [ $sel_rc -ne 0 ] && return

    zone_file="$ZONE_DIR/db.${selected_zone%.in-addr.arpa}"
    [ -f "$zone_file" ] || { dialog --msgbox "Zone file not found." 6 40; continue; }
    rndc freeze "$selected_zone" >/dev/null 2>&1 || true

    is_reverse=false
    [[ "$selected_zone" =~ \.in-addr\.arpa$ ]] && is_reverse=true

    while true; do
      exec 3>&1; set +e
      action=$(dialog --clear --title "Zone: $selected_zone" --menu "Choose action (Cancel→zone select):" 20 60 6 \
        1 "Add Record" \
        2 "Delete Record" \
        3 "Return" \
        2>&1 1>&3)
      act_rc=$?; set -e; exec 3>&-
      [ $act_rc -ne 0 ] && break

      case "$action" in
        1)
          if $is_reverse; then rec_menu=( PTR "PTR Record" )
          else rec_menu=( A "A Record" PTR "PTR Record" MX "MX Record" SRV "SRV Record" OTHER "Other" ); fi

          exec 3>&1; set +e
          rtype=$(dialog --clear --title "Add Record" --menu "Select type (Cancel→back):" 15 50 $(( ${#rec_menu[@]} / 2 )) "${rec_menu[@]}" 2>&1 1>&3)
          rt_rc=$?; set -e; exec 3>&-
          [ $rt_rc -ne 0 ] && continue

          case "$rtype" in
            A)
              exec 3>&1; name=$(dialog --inputbox "Hostname (e.g. www):" 8 40 2>&1 1>&3); exec 3>&-
              exec 3>&1; ip=$(dialog --inputbox "IP address:" 8 40 2>&1 1>&3); exec 3>&-
              [[ -n "$name" && -n "$ip" ]] && echo -e "$name	IN	A	$ip" >> "$zone_file"
              ;;
            PTR)
              mapfile -t fwdzones < <(list_zones | grep -v '\.in-addr\.arpa')
              if [ ${#fwdzones[@]} -gt 1 ]; then
                fwd_menu=(); for z in "${fwdzones[@]}"; do fwd_menu+=( "$z" "$z" ); done
                exec 3>&1; set +e
                chosen_fwd=$(dialog --clear --title "Select forward zone" --menu "Which zone for PTR target?" 15 60 ${#fwdzones[@]} "${fwd_menu[@]}" 2>&1 1>&3)
                set -e; exec 3>&-
                [ -z "$chosen_fwd" ] && continue
              else
                chosen_fwd="${fwdzones[0]}"
              fi
              exec 3>&1; host=$(dialog --inputbox "Hostname in $chosen_fwd (no dot):" 8 50 2>&1 1>&3); exec 3>&-
              exec 3>&1; ip=$(dialog --inputbox "IP address:" 8 40 2>&1 1>&3); exec 3>&-
              last=${ip##*.}
              fqdn="$host.$chosen_fwd."
              [[ -n "$last" && -n "$fqdn" ]] && echo -e "$last	IN	PTR	$fqdn" >> "$zone_file"
              ;;
            MX)
              exec 3>&1; prio=$(dialog --inputbox "MX priority:" 8 40 2>&1 1>&3); exec 3>&-
              exec 3>&1; mail=$(dialog --inputbox "Mail server (FQDN):" 8 60 2>&1 1>&3); exec 3>&-
              [[ -n "$prio" && -n "$mail" ]] && echo -e "@	IN	MX	$prio $mail" >> "$zone_file"
              ;;
            SRV)
              exec 3>&1; srv=$(dialog --inputbox "SRV name (_svc._proto):" 8 60 2>&1 1>&3); exec 3>&-
              exec 3>&1; val=$(dialog --inputbox "Priority Weight Port Target:" 8 60 2>&1 1>&3); exec 3>&-
              [[ -n "$srv" && -n "$val" ]] && echo -e "$srv	IN	SRV	$val" >> "$zone_file"
              ;;
            OTHER)
              exec 3>&1; raw=$(dialog --inputbox "Raw BIND line:" 10 70 2>&1 1>&3); exec 3>&-
              [ -n "$raw" ] && echo "$raw" >> "$zone_file"
              ;;
          esac
          increment_soa_serial "$zone_file"
          finalize_file "$zone_file"
          systemctl reload named || rndc reload || true
          dialog --msgbox "$rtype record added." 5 40
          ;;

        2)
          mapfile -t recs < <(grep -v '^[[:space:]]*$' "$zone_file")
          [ ${#recs[@]} -gt 0 ] || { dialog --msgbox "No records." 5 40; continue; }
          menu_args=(); for i in "${!recs[@]}"; do idx=$((i+1)); menu_args+=( "$idx" "${recs[i]}" ); done
          exec 3>&1; set +e
          sel=$(dialog --clear --title "Delete Record" --menu "Cancel→back:" 20 70 15 "${menu_args[@]}" 2>&1 1>&3)
          drc=$?; set -e; exec 3>&-
          [ $drc -ne 0 ] && continue
          sed -i "${sel}d" "$zone_file"
          increment_soa_serial "$zone_file"
          finalize_file "$zone_file"
          systemctl reload named || rndc reload || true
          dialog --msgbox "Record deleted." 5 40
          ;;
        3)
          rndc thaw "$selected_zone" >/dev/null 2>&1 || true
          break 2
          ;;
        esac
      done

    rndc thaw "$selected_zone" >/dev/null 2>&1 || true
  done
}

# ─── Modify Zones Submenu ────────────────────────────────────────────────────

modify_zones_menu() {
  while true; do
    exec 3>&1
    c=$(dialog --clear --title "Modify Zones" --menu "" 15 60 6 \
      1 "List All Zones" \
      2 "Add Forward Zone" \
      3 "Delete Forward Zone" \
      4 "Add Reverse Zone" \
      5 "Delete Reverse Zone" \
      6 "Back" \
      2>&1 1>&3)
    rc=$?; exec 3>&-
    [ $rc -ne 0 ] && break
    case $c in
      1) show_zones ;;
      2) add_zone ;;
      3) delete_zone ;;
      4) add_reverse_zone ;;
      5) delete_reverse_zone ;;
      6) break ;;
    esac
  done
}

# ─── Main Menu ────────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    exec 3>&1; set +e
    c=$(
      dialog --clear --title "DNS Management" \
             --menu "" 15 60 5 \
               1 "Modify Zones" \
               2 "Manage DNS Records" \
               3 "Manually Edit Zone Records" \
               4 "named Service Control" \
               5 "Exit" \
        2>&1 1>&3
    )
    rc=$?; set -e; exec 3>&-
    [ $rc -ne 0 ] && break

    case $c in
      1) modify_zones_menu   ;;
      2) manage_dns_records ;;
      3) edit_dns_records   ;;
      4) named_service_menu ;;
      5) clear; exit 0      ;;
    esac
  done
  clear
}

# ─── Startup ─────────────────────────────────────────────────────────────────
if ! command -v dialog &>/dev/null; then
  echo "Error: dialog not installed." >&2
  exit 1
fi

main_menu
