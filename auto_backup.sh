#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <backup_dir> <source_dir>"
  exit 1
fi

backup_dir="$1"
source_dir="$2"
timestamp=$(date +"%Y%m%d%H%M%S")

# Create a backup
tar -czf "$backup_dir/backup_$timestamp.tar.gz" "$source_dir"

echo "Backup of $source_dir completed and saved to $backup_dir/backup_$timestamp.tar.gz"
