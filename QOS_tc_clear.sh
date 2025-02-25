#!/bin/bash

LOG_FILE="/var/log/tc-clear.log"
ERROR_LOG_FILE="/var/log/tc-clear-errors.log"

echo "Starting TC clearing process..." | tee -a $LOG_FILE

# Get a list of all network interfaces
interfaces=$(ls /sys/class/net)

# Iterate over each interface and clear tc settings
for interface in $interfaces; do
    echo "Clearing tc settings on interface: $interface" | tee -a $LOG_FILE
    sudo tc qdisc del dev $interface root 2>>$ERROR_LOG_FILE || echo "No tc settings to clear on $interface" | tee -a $LOG_FILE
done

echo "TC clearing process complete." | tee -a $LOG_FILE
