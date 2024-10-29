#!/bin/bash
NAMESPACE="metallb-system"

# Function to check if MetalLB pods are running
function wait_for_metallb {
    echo "Waiting for MetalLB pods to be running..."
    while true; do
        # Get the status of MetalLB pods
        STATUS=$(kubectl get pods -n $NAMESPACE -l app=metallb -o jsonpath="{.items[*].status.phase}")

        # Check if all pods are in the 'Running' state
        if [[ $(echo "$STATUS" | tr ' ' '\n' | sort -u) == "Running" ]]; then
            echo "All MetalLB pods are running."
            break
        else
            echo "Current status: $STATUS. Waiting..."
            sleep 5
        fi
    done
}

# Call the function
wait_for_metallb


