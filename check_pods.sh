#!/bin/bash

# Main script logic here

# Function to check CoreDNS pod status
check_coredns_pods() {
  NAMESPACE="kube-system"
  POD_LABEL="k8s-app=kube-dns"

  while true; do
    kubectl get pods -n $NAMESPACE -l $POD_LABEL -o jsonpath='{.items[*].status.phase}' | grep -q "Running"
    if [ $? -eq 0 ]; then
      echo "CoreDNS pods are up and running!"
      break
    else
      echo "CoreDNS pods are not yet up. Checking again in 5 seconds..."
      sleep 5
    fi
  done
}

# Call the function to check CoreDNS pods
check_coredns_pods

# Additional logic for your main script
echo "Proceeding with the rest of the script after CoreDNS is ready."
