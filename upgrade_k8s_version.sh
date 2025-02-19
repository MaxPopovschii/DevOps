#!/bin/bash

# k8s_upgrade-version - script for upgrade kubernetes cluster
# version 2.0.0
# authors Stefano Talpo <stefano.talpo@comelit.it>, Maxim Popovschii <maxim.popovschii@comelit.it>

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
	sleep 120	#TODO: Change in dynamic wait check
}

# Function to apply kubeadm upgrade
upgrade_kubeadm() {
	local version=$1
	echo "Applying kubeadm upgrade to version $version..."
	#TODO: Add check if manual upgrade is required checking result of kubadm upgrade plan
	kubeadm upgrade apply "v$version" --v=5 -y || { echo "Failed to apply kubeadm upgrade for version $version"; exit 1; }
	sleep 120	#TODO: Change in dynamic wait check
}

# Get current Kubernetes cluster version
get_current_version() {
	printf $(kubeadm version -o short | tr -d 'v')
}

# Get the latest available patch version for a given minor release
get_latest_version() {
	apt-cache policy kubeadm | grep Candidate | awk '{print $2}' | cut -d'-' -f1
}

# Check upgrading version
check_upgrading_version() {
    local current_major=$1 current_minor=$2 current_patch=$3
    local target_major=$4 target_minor=$5 target_patch=$6
    local next_minor=$7 latest_current_patch=$8

	ret_code=-1

    if (( current_major == target_major )); then
        if (( current_minor == target_minor || current_minor > target_minor)); then
            if (( current_patch == target_patch )); then
                ret_code=0
            elif (( current_patch < target_patch )); then
                ret_code=1
            else
                ret_code=-10
            fi
        elif (( next_minor == target_minor )); then
            if (( current_minor == target_minor )); then
                if (( current_patch < target_patch )); then
                    ret_code=1
                else
                    ret_code=-10
                fi
            elif (( current_minor < target_minor )); then
                ret_code=10
            fi
        elif (( next_minor < target_minor )); then
            if (( current_minor < target_minor )); then
                if (( current_patch == latest_current_patch )); then
                    ret_code=100
                elif (( current_patch < latest_current_patch )); then
                    ret_code=1000
                else
                    ret_code=-10
                fi
            fi
        fi
	elif (( current_major > target_major )); then
		 	ret_code=-10
    fi

    echo $ret_code
}


# Update Kubernetes apt keyring
echo "Updating Kubernetes apt keyring..."
rm -rf /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v"${TARGET_VERSION%.*}"/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Extract target versions
read target_major target_minor target_patch <<< $(awk -F'.' '{print $1, $2, $3}' <<< "$TARGET_VERSION")


while true; do

	CURRENT_VERSION=$(get_current_version)
	
	echo "Current cluster version: $CURRENT_VERSION"
	echo "Target cluster version: $TARGET_VERSION"
	
	# Extract current versions
    read current_major current_minor current_patch <<< $(awk -F'.' '{print $1, $2, $3}' <<< "$CURRENT_VERSION")
	# Set next minor
	next_minor=$((current_minor + 1))
	# Get latest current version
	latest_current_version=$(get_latest_version)
	# Extract latest current versions
    read latest_current_major latest_current_minor latest_current_patch <<< $(awk -F'.' '{print $1, $2, $3}' <<< "$latest_current_version")
	
	# Get upgrading operation code
	op_code=$(check_upgrading_version $current_major $current_minor $current_patch $target_major $target_minor $target_patch $next_minor $latest_current_patch)
	
	# Execute upgrading operation
	case $op_code in
		0)
			echo "Current version ($CURRENT_VERSION) is equal to target ($TARGET_VERSION)."
			break
			;;
		1)
			echo "Current version ($CURRENT_VERSION) is below target ($TARGET_VERSION) for 'patch'."
			echo "Updating to target version: $TARGET_VERSION"
			update_kube_components "$TARGET_VERSION"
			upgrade_kubeadm "$TARGET_VERSION"
			;;
		10)
			echo "Current version ($CURRENT_VERSION) is below target ($TARGET_VERSION) for one 'minor'."
			next_version="$current_major.$next_minor"
			update_apt_repo "$next_version"
			echo "Updating directly to target version: $TARGET_VERSION"
			update_kube_components "$TARGET_VERSION"
			upgrade_kubeadm "$TARGET_VERSION"
			;;
		100)
			echo "Current version ($CURRENT_VERSION) is below target ($TARGET_VERSION) for more than a 'minor'."
			next_version="$current_major.$next_minor"
			update_apt_repo "$next_version"
			latest_current_version=$(get_latest_version)
			echo "Updating next minor with latest patch version: $latest_current_version"
			update_kube_components "$latest_current_version"
			upgrade_kubeadm "$latest_current_version"
			;;
		1000)
			echo "Current version ($CURRENT_VERSION) is below target ($TARGET_VERSION) for more than a 'minor' and not at current latest 'patch'."
			echo "Updating to current minor with latest patch version: $latest_current_version"
			update_kube_components "$latest_current_version"
			upgrade_kubeadm "$latest_current_version"
			;;
		-10)
			echo "Downgrade is not supported. The current version ($CURRENT_VERSION) is higher than the target version ($TARGET_VERSION)."
			exit 1
			;;
		*)
			echo "Unexpected case. This upgrade has not been handled yet."
			echo "Current version: $CURRENT_VERSION, Target: $TARGET_VERSION"
			exit 1
			;;
	esac
    
	CURRENT_VERSION=$(get_current_version)
    echo "Updated to version: $CURRENT_VERSION"

done

# Apply Flannel if necessary
echo "Applying Flannel updates..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "Upgrade completed. Kubernetes has been upgraded to version $CURRENT_VERSION."
