#!/bin/bash

# Exit on any error
set -e

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with sudo -E $0" 1>&2
   exit 1
fi

# Default values
HOST=$(hostname)
DOCKER_VERSION="latest" 
CNI_PLUGINS_VERSION="v1.2.0" 
FLANNEL_VERSION="latest"  
METALLB_VERSION="v0.14.3" 
NGINX_HELM_VERSION="9.7.7" 
POD_NETWORK_CIDR="10.244.0.0/16" 
GATEWAY_IP="192.168.1.1" 
STATIC_IPS=("192.168.1.174/32 192.168.1.175/32 192.168.1.176/32")
KUB_VERSION="1.28.10"
NET_IP="192.168.1.172/24"
INTERFACE="enp0s8"

# Function to display usage
function usage {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -k, --kub-version       Kubernetes version (default: $KUB_VERSION)"
    echo "  -c, --cni-plugins       CNI plugins version (default: $CNI_PLUGINS_VERSION)"
    echo "  -f, --flannel-version   Flannel version (default: $FLANNEL_VERSION)"
    echo "  -m, --metallb-version   MetalLB version (default: $METALLB_VERSION)"
    echo "  -g, --gateway-ip        Gateway IP (default: $GATEWAY_IP)"
    echo "  -n, --network-ip        Static IP for current machine (default: $NET_IP)"
    echo "  -i, --interface         Name of interface (default: $INTERFACE)"
    echo "  -p, --pod-network-cidr  Pod network CIDR (default: $POD_NETWORK_CIDR)"
    echo "  -s, --static-ips        List of static IP addresses (space-separated)"
    echo "  -h, --help              Display this help message"
    exit 1
}

# Parse command-line arguments
while [[ "$1" != "" ]]; do
    case $1 in
        -k | --kub-version )
            shift
            KUB_VERSION=$1
            ;;
        -c | --cni-plugins )
            shift
            CNI_PLUGINS_VERSION=$1
            ;;
        -f | --flannel-version )
            shift
            FLANNEL_VERSION=$1
            ;;
        -m | --metallb-version )
            shift
            METALLB_VERSION=$1
            ;;
        -g | --gateway-ip )
            shift
            GATEWAY_IP=$1
            ;;
        -n | --network-ip )
            shift
            NET_IP=$1
            ;;
        -i | --interface )
            shift
            INTERFACE=$1
            ;;
        -p | --pod-network-cidr )
            shift
            POD_NETWORK_CIDR=$1
            ;;
        -s | --static-ips )
            shift
            STATIC_IPS=($@) # Capture all remaining arguments
            break
            ;;
        -h | --help )
            usage
            ;;
        * )
            echo "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

# System cleanup function
function system_cleanup {
    echo "Cleaning up and updating the system..."
    apt clean all
    apt update
    apt upgrade -y
    apt dist-upgrade -y
    apt autoremove -y
    apt autoclean -y
}

# Disable swap function
function disable_swap {
    echo "Disabling swap..."
    swapoff -a
    rm -rf /swap.img
    sed -i '/swap/s/^/#/' /etc/fstab
}

# Enable IP forwarding function
function enable_ip_forwarding {
    echo "Enabling IP forwarding..."
    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1
    sysctl -p
    modprobe overlay
    modprobe br_netfilter

    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sysctl --system
}

# Remove old Docker installations function
function remove_docker {
    echo "Removing old Docker installations..."
    apt remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc
}

# Install containerd function
function install_containerd {
    echo "Installing Docker and containerd..."
    apt install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update
    apt install -y containerd.io
    apt-mark hold containerd.io
    systemctl stop containerd
    mv /etc/containerd/config.toml /etc/containerd/config.toml.orig
    containerd config default | tee /etc/containerd/config.toml
    sed -i '/SystemdCgroup/s/false/true/' /etc/containerd/config.toml
    systemctl enable --now containerd
    systemctl start containerd
}

# Update Kubernetes apt keyring
function update_kubernetes_keyring {
    echo "Updating Kubernetes apt keyring..."
    rm -rf /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v"${KUB_VERSION%.*}"/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUB_VERSION%.*}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    apt update || { echo "Failed to update apt Kubernetes apt keyring"; exit 1; }
}

# Install Kubernetes function
function install_kubernetes {
    echo "Installing Kubernetes..."
    apt install -y kubeadm="$KUB_VERSION"-1.1 kubelet="$KUB_VERSION"-1.1 kubectl="$KUB_VERSION"-1.1 || { echo "Failed to install Kubernetes components for version $KUB_VERSION"; exit 1; }
    apt-mark hold kubelet kubeadm kubectl
    kubeadm config images pull --kubernetes-version=v$KUB_VERSION
    kubeadm init --kubernetes-version=v$KUB_VERSION --pod-network-cidr=$POD_NETWORK_CIDR

    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube
}

# Configure nodes function
function configure_nodes {
    HOST=$(hostname)
    kubectl label node $HOST node-role.kubernetes.io/worker=worker
    kubectl taint nodes --all node-role.kubernetes.io/control-plane-
}

# Install Flannel function
function install_flannel {
    echo "Installing Flannel network add-on..."
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
}

# DEPRECATED
function install_cni_plugins {
    echo "Installing CNI plugins..."
    mkdir -p /opt/cni/bin
    curl -O -L https://github.com/containernetworking/plugins/releases/download/$CNI_PLUGINS_VERSION/cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz
    tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz
    rm cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz
}

# Configure kube-proxy function
function configure_kube_proxy {
    kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: true/" | kubectl apply -f - -n kube-system
}

# Install MetalLB function
function install_metallb {
    echo "Installing MetalLB..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml
    ./k8s_check-metallb.sh
    ST_IP=""
    for IP in $(echo ${!STATIC_IPS[@]}); do
        ST_IP+="      - ${STATIC_IPS[$IP]}"$'\n';
    done
    cat << EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
    name: first-pool
    namespace: metallb-system
spec:
    addresses:
$ST_IP
EOF
}

# Apply static IPs function
function apply_static_ips {
    echo "Applying static IPs..."
    ST_IP=""
    for IP in $(echo ${!STATIC_IPS[@]}); do
        ST_IP+="        - ${STATIC_IPS[$IP]}"$'\n';
    done
    ST_IP=${ST_IP%$'\n'}
    cat <<EOF > /etc/netplan/50-cloud-init.yaml
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - $NET_IP
$ST_IP
      routes:
        - to: default
          via: $GATEWAY_IP
      nameservers:
        addresses:
          - $GATEWAY_IP
EOF
    netplan apply
}

# Create storage directories function
function create_storage_directories {
    echo "Creating storage directories..."
    mkdir -p /storage/ssd
    mkdir -p /storage/standard
    cat << EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ssd
parameters:
   type: pd-ssd
provisioner: kubernetes.io/no-provisioner
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: standard
parameters:
  type: pd-standard
provisioner: kubernetes.io/no-provisioner
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: test-storage-standard
spec:
  capacity:
    storage: 101Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: standard
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: test-service-storage-standard
    namespace: default
  local:
    path: /storage/standard/test-storage-standard
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $HOST
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: test-storage-ssd
spec:
  capacity:
    storage: 100Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ssd
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: test-service-storage-ssd
    namespace: default
  local:
    path: /storage/ssd/test-storage-ssd
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $HOST
EOF
}

# Install Helm function
function install_helm {
    echo "Installing Helm..."
    curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
    apt install -y apt-transport-https
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | tee /etc/apt/sources.list.d/helm-stable-debian.list
    apt update
    apt install -y helm
}

# Install NGINX Ingress Controller function
function install_nginx_ingress {
    echo "Installing NGINX Ingress Controller..."
    su - $SUDO_USER -c "helm repo add bitnami https://charts.bitnami.com/bitnami"
    su - $SUDO_USER -c "helm install nginx-ingress-controller bitnami/nginx-ingress-controller --version $NGINX_HELM_VERSION --set controller.service.clusterIP=$(echo "$STATIC_IPS" | awk -F/ '{print $1}')"
}

# Main script execution
system_cleanup
disable_swap
enable_ip_forwarding
remove_docker
install_containerd
update_kubernetes_keyring
install_kubernetes
configure_nodes
install_flannel
#install_cni_plugins
configure_kube_proxy
install_metallb
apply_static_ips
create_storage_directories
install_helm
install_nginx_ingress

echo "Kubernetes setup completed!"
