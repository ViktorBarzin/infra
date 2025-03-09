#!/usr/bin/env bash

# This is used to run the main program on synology nas and log all messages to synology's log system

cd /var/services/homes/Administrator/server-power-cycle
echo "Starting powercheck"
./powercheck-armv8 -log_dir=./logs

echo "script completed successfully, logging to synlogy's logs"


while IFS= read -r line; do
# for line in $(cat ./logs/powercheck-armv8.INFO); do
    msg=$(echo $line | grep -E '^[IWEF][0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}'| awk '{$1=$2=$3=$4=""; print $0}' | sed 's/^ *//')
    #echo $line
    echo $msg
    if [[ -n $msg ]]; then
        synologset1 sys info 0x11800000 "$msg"
    fi
done < "./logs/powercheck-armv8.INFO"

# Cleanup logs
find ./logs -type f -mtime +7 -exec rm {} \;
