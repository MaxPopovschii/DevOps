#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <cpu_threshold> <mem_threshold> <alert_email>"
  exit 1
fi

cpu_threshold="$1"
mem_threshold="$2"
alert_email="$3"

# Get current CPU and memory usage
cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
mem_usage=$(free | grep Mem | awk '{print $3/$2 * 100.0}')

# Check if CPU or memory usage exceeds the specified thresholds
if (( $(echo "$cpu_usage > $cpu_threshold" | bc -l) )) || (( $(echo "$mem_usage > $mem_threshold" | bc -l) )); then
    echo "High CPU or memory usage detected!" | mail -s "Alert: High Resource Usage" "$alert_email"
    echo "Alert sent to $alert_email"
else
    echo "CPU usage: $cpu_usage%, Memory usage: $mem_usage%"
fi
