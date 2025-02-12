#!/bin/bash

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with sudo -E $0" 1>&2
   exit 1
fi

# Validate the script arguments
if [ $# -ne 1 ]; then
  echo "Usage: $0 <target_kubernetes_version>"
  echo "Example: $0 1.31.0"
  exit 1
fi

TARGET_VERSION="$1"

# Validate target version format
if ! [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version format. Use x.y.z (e.g., 1.30.0)."
  exit 1
fi

# Retrieve the current Kubernetes cluster version
CURRENT_VERSION=$(kubeadm version -o short | tr -d 'v')
if [ -z "$CURRENT_VERSION" ]; then
  echo "Unable to determine the current Kubernetes version. Ensure kubeadm is configured correctly."
  exit 1
fi

echo "Current cluster version: $CURRENT_VERSION"
echo "Target cluster version: $TARGET_VERSION"

# Check if the target version is lower than the current version
if [[ "$(printf '%s\n' "$CURRENT_VERSION" "$TARGET_VERSION" | sort -V | head -n1)" == "$TARGET_VERSION" ]] && [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]]; then
  echo "Downgrade is not supported. The current version ($CURRENT_VERSION) is higher than the target version ($TARGET_VERSION)."
  exit 1
fi

# Update Kubernetes apt keyring
echo "Updating Kubernetes apt keyring..."
rm -rf /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v"${TARGET_VERSION%.*}"/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Function to update apt repository for a specific version
update_apt_repo() {
  local version=$1
  echo "Updating apt repository for version $version..."
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$version/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
  apt update || { echo "Failed to update apt repository for version $version"; exit 1; }
}

# Function to update kubeadm, kubelet, and kubectl to a specific version
update_kube_components() {
  local version=$1
  echo "Updating kubeadm, kubelet, and kubectl to version $version..."
  apt-mark unhold kubelet kubeadm kubectl
  apt install -y kubeadm="$version"-1.1 kubelet="$version"-1.1 kubectl="$version"-1.1 || { echo "Failed to install Kubernetes components for version $version"; exit 1; }
  apt-mark hold kubelet kubeadm kubectl
}

# Function to apply kubeadm upgrade
upgrade_kubeadm() {
  local version=$1
  echo "Applying kubeadm upgrade to version $version..."
  kubeadm upgrade apply "v$version" -y || { echo "Failed to apply kubeadm upgrade for version $version"; exit 1; }
  #systemctl restart kubelet
  sleep 30
}

# Get the latest available patch version for a given minor release
get_latest_patch_version() {
  apt-cache policy kubeadm | grep Candidate | awk '{print $2}' | cut -d'-' -f1
}

# Extract current and target minor versions
current_minor=$(echo "$CURRENT_VERSION" | cut -d'.' -f1,2)
target_minor=$(echo "$TARGET_VERSION" | cut -d'.' -f1,2)

# Update Kubernetes apt keyring
update_apt_repo "$current_minor"

while [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]]; do
  echo "Current cluster version: $CURRENT_VERSION"
  echo "Target cluster version: $TARGET_VERSION"

  # Estrai le parti della versione
  current_major=$(echo "$CURRENT_VERSION" | awk -F. '{print $1}')
  current_minor=$(echo "$CURRENT_VERSION" | awk -F. '{print $2}')
  current_patch=$(echo "$CURRENT_VERSION" | awk -F. '{print $3}')

  target_major=$(echo "$TARGET_VERSION" | awk -F. '{print $1}')
  target_minor=$(echo "$TARGET_VERSION" | awk -F. '{print $2}')
  target_patch=$(echo "$TARGET_VERSION" | awk -F. '{print $3}')

  # Verifica se siamo già aggiornati
  if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
    echo "Already at target version: $TARGET_VERSION"
    break
  fi

  # Ottieni l'ultima patch disponibile per la minor corrente
  latest_patch_version=$(get_latest_patch_version)
  if [ -z "$latest_patch_version" ]; then
    echo "Failed to retrieve the latest patch version. Check the repository."
    exit 1
  fi

  case 1 in
    # Se siamo nello stesso minor, ma con un patch inferiore
    $((current_minor == target_minor && current_patch < target_patch)))
      echo "Upgrading from $CURRENT_VERSION to $TARGET_VERSION (patch update)"
      update_kube_components "$TARGET_VERSION"
      upgrade_kubeadm "$TARGET_VERSION"
      CURRENT_VERSION=$TARGET_VERSION
      ;;

    # Se siamo in un minor inferiore, aggiorniamo prima all'ultimo patch disponibile
    $((current_minor < target_minor)))
      echo "Upgrading minor: Moving from $CURRENT_VERSION to latest patch $latest_patch_version"
      update_kube_components "$latest_patch_version"
      upgrade_kubeadm "$latest_patch_version"
      CURRENT_VERSION=$(kubeadm version -o short | tr -d 'v')

      # Se il minor è ancora inferiore dopo l'update, aggiorniamo l'APT per il prossimo minor
      if [[ "$current_minor" -lt "$target_minor" ]]; then
        next_minor=$((current_minor + 1))
        update_apt_repo "$current_major.$next_minor"
      fi
      ;;

    # Caso imprevisto (debug)
    *)
      echo "Unexpected case. Current version: $CURRENT_VERSION, Target: $TARGET_VERSION"
      exit 1
      ;;
  esac
done

# Apply Flannel if necessary
echo "Applying Flannel..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "Upgrade completed. Kubernetes has been upgraded to version $CURRENT_VERSION."
