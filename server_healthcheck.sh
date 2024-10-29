#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <server_list_file> <alert_email>"
    exit 1
fi

server_list_file="$1"
alert_email="$2"

# Check if the server list file exists
if [ ! -f "$server_list_file" ]; then
    echo "Error: Server list file not found at $server_list_file."
    exit 1
fi

# Read server names from the file into an array
mapfile -t servers < "$server_list_file"

# Loop through each server and check reachability
for server in "${servers[@]}"; do
    if ping -c 1 "$server" &> /dev/null; then
        echo "Server $server is reachable"
    else
        echo "Server $server is unreachable"
        echo "Alert: Server $server is unreachable!" | mail -s "Server Unreachable Alert" "$alert_email"
        echo "Alert sent to $alert_email"
    fi
done
