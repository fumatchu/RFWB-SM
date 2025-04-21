#!/usr/bin/env bash
# RFWB Systems Manager
# Provides a top-level dialog menu for various RFWB administrative scripts

set -euo pipefail

PROFILE_TITLE="RFWB Systems Manager"

while true; do
  CHOICE=$(dialog \
    --clear \
    --backtitle "$PROFILE_TITLE" \
    --title "Main Menu" \
    --menu "Select an option:" 15 50 2 \
      1 "DNS Administration" \
      2 "Service Admin" \
      3 "Exit" \
    3>&1 1>&2 2>&3)

  case "$CHOICE" in
    1)

      /root/.rfwb-admin/dns-admin.sh
      ;;
    2)
     /root/.rfwb-admin/service-admin.sh
      ;;
    *)
      clear
      exit 0
      ;;
  esac

done
