#!/bin/bash

# Check if the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please, execute the script with root priviliges."
  exit 1
fi

# Check the script arguments
if [ $# -ne 1 ]; then
  echo "Usage: $0 <target_version_kubernetes>"
  echo "Example: $0 1.29.0"
  exit 1
fi

TARGET_VERSION=$1

# Get the current cluster version
CURRENT_VERSION=$(kubeadm version -o short | tr -d 'v')
if [ -z "$CURRENT_VERSION" ]; then
  echo "Unable to determine the current Kubernetes version. Ensure that kubeadm is properly configured."
  exit 1
fi

echo "Current cluster version: $CURRENT_VERSION"
echo "Target cluster version: $TARGET_VERSION"

# Validate the target version format
if ! [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid target version format. Use the format x.y.z (e.g., 1.29.0)."
  exit 1
fi

# Function to update the apt repository
update_apt_repo() {
    local version=$1
    echo "Updating apt repository for version $version..."
    sudo rm -rf /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$version/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v$version/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
}

# Function to update kubeadm, kubelet, and kubectl
update_kube_components() {
  local version=$1
  echo "Updating kubeadm, kubelet, and kubectl to version $version..."
  sudo apt-mark unhold kubelet kubeadm kubectl
  sudo apt clean
  sudo apt update
  sudo apt install -y kubeadm=$version-1.1 kubelet=$version-1.1 kubectl=$version-1.1
  sudo apt-mark hold kubelet kubeadm kubectl
}

# Function to apply kubeadm upgrades
upgrade_kubeadm() {
  local version=$1
  echo "Applying kubeadm upgrade to version $version..."
  sudo kubeadm upgrade plan
  sudo kubeadm upgrade apply "v$version" --yes
  sudo systemctl restart kubelet
}

while [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]]; do
    echo "Current cluster version: $CURRENT_VERSION"
    echo "Target cluster version: $TARGET_VERSION"
    candidate=$(apt-cache policy kubeadm | grep Candidate | awk '{print $2}' | cut -d'-' -f1)
    # Upgrade to the latest accessible version
    if [[ "$CURRENT_VERSION" != "$candidate" ]]; then
        # Determine the latest version
        version_apt=$(apt-cache policy kubeadm | grep Candidate | awk '{print $2}' | cut -d'-' -f1 | cut -d'.' -f1-2)
        update_apt_repo "$version_apt"
        update_kube_components "$candidate"
        upgrade_kubeadm "$candidate"
    else 
        apt=$(echo "$TARGET_VERSION" | cut -d'.' -f1-2)
        update_apt_repo "$apt"
        update_kube_components "$TARGET_VERSION"
        upgrade_kubeadm "$TARGET_VERSION"
    fi
    CURRENT_VERSION=$(kubeadm version -o short | tr -d 'v')
done

# Apply Flannel networking (if necessary)
echo "Applying Flannel..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "Upgrade complete. Kubernetes has been updated to version $CURRENT_VERSION."


