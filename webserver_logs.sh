#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <access_log_path> <error_log_path>"
    exit 1
fi

access_log="$1"
error_log="$2"

# Check if access log exists and is readable
if [ ! -f "$access_log" ]; then
    echo "Error: Access log file not found at $access_log."
    exit 1
fi

# Check if error log exists and is readable
if [ ! -f "$error_log" ]; then
    echo "Error: Error log file not found at $error_log."
    exit 1
fi

# Analyze access log
echo -e "\nTop 10 IP addresses:"
awk '{print $1}' "$access_log" | sort | uniq -c | sort -nr | head -n 10

# Analyze error log
echo -e "\nErrors by type:"
awk '{print $9}' "$error_log" | sort | uniq -c | sort -nr | column -t
