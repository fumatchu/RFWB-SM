# /root/.rfwb-admin/lib.sh

# Initialize breadcrumb with root
reset_backtitle() {
  export BACKTITLE="RFWB Admin"
}

# Add to breadcrumb
add_to_backtitle() {
  BACKTITLE+=" → $1"
  export BACKTITLE
}

# Show where we are (optional echo)
show_backtitle() {
  echo -e "\e[1m$BACKTITLE\e[0m"
}
