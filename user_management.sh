#!/bin/bash

action="$1"
username="$2"

# Check if action and username are provided
if [ -z "$action" ] || [ -z "$username" ]; then
    echo "Usage: $0 {add|modify|delete} username"
    exit 1
fi

case $action in
    "add")
        useradd "$username"
        if [ $? -eq 0 ]; then
            echo "User '$username' added successfully."
        else
            echo "Error: Failed to add user '$username'."
        fi
        ;;

    "modify")
        usermod -s /bin/bash "$username"
        if [ $? -eq 0 ]; then
            echo "User '$username' modified successfully to use /bin/bash."
        else
            echo "Error: Failed to modify user '$username'."
        fi
        ;;

    "delete")
        userdel "$username"
        if [ $? -eq 0 ]; then
            echo "User '$username' deleted successfully."
        else
            echo "Error: Failed to delete user '$username'."
        fi
        ;;

    *)
        echo "Usage: $0 {add|modify|delete} username"
        exit 1
        ;;
esac
