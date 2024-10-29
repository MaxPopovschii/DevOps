#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 <schedule> <command> <description>"
    echo "Example: $0 \"0 2 * * *\" \"/path/to/your/script.sh\" \"Daily backup job\""
    exit 1
}

# Check if the correct number of arguments is provided
if [ "$#" -ne 3 ]; then
    usage
fi

# Assign variables
schedule="$1"
command="$2"
description="$3"

# Check if the command is executable
if ! command -v $command &> /dev/null; then
    echo "Error: Command '$command' not found or not executable."
    exit 1
fi

# Prepare the cron job entry
cron_job="$schedule $command # $description"

# Add the cron job to the user's crontab
if (crontab -l 2>/dev/null | grep -F -q "$command"); then
    echo "Cron job already exists: $cron_job"
else
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    echo "Cron job added: $cron_job"
fi
