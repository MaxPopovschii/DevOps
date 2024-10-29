#!/bin/bash

# Exit on any error
set -e

# Default values
HOST=$(hostname)
DOCKER_VERSION="latest" 
KUBELET_VERSION="1.28.10-1.1" 
CNI_PLUGINS_VERSION="v1.2.0" 
FLANNEL_VERSION="latest"  
METALLB_VERSION="v0.14.3" 
NGINX_HELM_VERSION="9.7.7" 
POD_NETWORK_CIDR="10.244.0.0/16" 
GATEWAY_IP="192.168.1.1" 
STATIC_IPS=("192.168.1.174/32 192.168.1.175/32 192.168.1.176/32")
KUB_VERSION="v1.28"
NET_IP="192.168.1.172/24"
INTERFACE="enp0s8"

# Function to display usage
function usage {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -k, --kub-version       Kubernetes version (default: $KUB_VERSION)"
    echo "  -kl, --kubelet-version  Kubernetes instruments version (default: $KUBELET_VERSION)"
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
        -kl | --kubelet-version )
            shift
            KUBELET_VERSION=$1
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
    sudo apt clean all
    sudo apt update
    sudo apt upgrade -y
    sudo apt dist-upgrade -y
    sudo apt autoremove -y
    sudo apt autoclean -y
}

# Disable swap function
function disable_swap {
    echo "Disabling swap..."
    sudo swapoff -a
    sudo rm -rf /swap.img
    sudo sed -i '/swap/s/^/#/' /etc/fstab
}

# Enable IP forwarding function
function enable_ip_forwarding {
    echo "Enabling IP forwarding..."
    sudo sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo sysctl -p
    sudo modprobe overlay
    sudo modprobe br_netfilter

    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sudo sysctl --system
}

# Remove old Docker installations function
function remove_docker {
    echo "Removing old Docker installations..."
    sudo apt remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc
}

# Install Docker and containerd function
function install_containerd {
    echo "Installing Docker and containerd..."
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update
    sudo apt install -y containerd.io
    sudo systemctl stop containerd
    sudo mv /etc/containerd/config.toml /etc/containerd/config.toml.orig
    sudo containerd config default | sudo tee /etc/containerd/config.toml
    sudo sed -i '/SystemdCgroup/s/false/true/' /etc/containerd/config.toml
    sudo systemctl enable --now containerd
    sudo systemctl start containerd
}

# Install Kubernetes function
function install_kubernetes {
    echo "Installing Kubernetes..."
    # Remove existing keyring file if it exists
    if [ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
        echo "Removing existing Kubernetes APT keyring..."
        sudo rm /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    fi
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUB_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 
    sudo apt update

    sudo apt install -y kubeadm=$KUBELET_VERSION kubelet=$KUBELET_VERSION kubectl=$KUBELET_VERSION
    sudo apt-mark hold containerd.io kubelet kubeadm kubectl
    sudo kubeadm config images pull
    sudo kubeadm init --pod-network-cidr=$POD_NETWORK_CIDR

    mkdir -p $HOME/.kube
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config 
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

# Install CNI plugins function
function install_cni_plugins {
    echo "Installing CNI plugins..."
    sudo mkdir -p /opt/cni/bin
    curl -O -L https://github.com/containernetworking/plugins/releases/download/$CNI_PLUGINS_VERSION/cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz
    sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz
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
    sleep 10
    ./check_metallb.sh
    echo "$STATIC_IPS"
    sleep 10
    cat <<EOF > metallb-values.yml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
    name: first-pool
    namespace: metallb-system
spec:
    addresses:
EOF
    for IP in $STATIC_IPS; do
        echo "      - ${IP}" >> metallb-values.yml
    done
    sleep 20
    kubectl apply -f metallb-values.yml
}

# Apply static IPs function
function apply_static_ips {
    echo "Applying static IPs..."
    sudo bash -c "cat<<EOF > /etc/netplan/00-installer-config.yaml
    network:
        ethernets:
            $INTERFACE:
                dhcp4: no
                addresses:
                    - $NET_IP
                routes: 
                    - to: default
                      via: $GATEWAY_IP
                nameservers:
                    addresses:
                        - $GATEWAY_IP
EOF"
    sudo netplan apply
}

# Create storage directories function
function create_storage_directories {
    echo "Creating storage directories..."
    sudo mkdir -p /storage/ssd
    sudo mkdir -p /storage/standard
    cat <<EOF > storageclass.yml
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
    cat <<EOF > persistemtvolume.yml
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
    kubectl apply -f storageclass.yml
    kubectl apply -f persistentvolume.yml
}

# Install Helm function
function install_helm {
    echo "Installing Helm..."
    curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
    sudo apt install -y apt-transport-https
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt update
    sudo apt install -y helm
}

# Install NGINX Ingress Controller function
function install_nginx_ingress {
    echo "Installing NGINX Ingress Controller..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm install nginx-ingress-controller bitnami/nginx-ingress-controller --version $NGINX_HELM_VERSION
}

# Main script execution
system_cleanup
disable_swap
enable_ip_forwarding
remove_docker
install_containerd
install_kubernetes
configure_nodes
install_flannel
install_cni_plugins
configure_kube_proxy
install_metallb
apply_static_ips
create_storage_directories
install_helm
install_nginx_ingress

echo "Kubernetes setup completed!"
