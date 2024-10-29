#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <db_user> <db_pass> <db_name> <backup_dir>"
  exit 1
fi

db_user="$1"
db_pass="$2"
db_name="$3"
backup_dir="$4"
timestamp=$(date +"%Y%m%d%H%M%S")

# Create a backup using mysqldump and gzip
mysqldump -u "$db_user" -p"$db_pass" "$db_name" | gzip > "$backup_dir/db_backup_$timestamp.sql.gz"

if [ $? -eq 0 ]; then
    echo "Backup of database '$db_name' completed successfully and saved to '$backup_dir/db_backup_$timestamp.sql.gz'."
else
    echo "Error occurred during the backup process."
fi
