#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <log_file> <max_size_in_bytes>"
  exit 1
fi

log_file="$1"
max_size="$2"

# Check if the log file exists
if [ ! -f "$log_file" ]; then
  echo "Log file not found: $log_file"
  exit 1
fi

# Check if the log file size exceeds the maximum size
if [ $(wc -c < "$log_file") -gt "$max_size" ]; then
    mv "$log_file" "$log_file.old"
    touch "$log_file"
    echo "Log file $log_file has been rotated."
else
    echo "Log file $log_file size is within limits."
fi
