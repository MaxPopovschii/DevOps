#!/bin/bash

# k8s-changeip - script for change the ip on kubernetes cluster
# version 0.1.0

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with sudo -E $0" 1>&2
   exit 1
fi

# Check OS Version
DISTRO_NAME=`lsb_release -si`
DISTRO_RELEASE=`lsb_release -sr | tr -d "."`
if [[ ${DISTRO_NAME} != "Ubuntu" ]] || [[ "${DISTRO_RELEASE}" -lt "1804" ]]; then
   echo "OS Version not compatible" 1>&2
   exit 1
fi

# Check input script parameters
if [[ "$1" == "" ]] || [[ "$2" == "" ]]; then
   echo "Invalid parameters!

Usage: sudo -E $0 interfaceName newIpAddressAddress newDefaultGateway
Mandatory : interfaceName, newIpAddressAddress, newDefaultGateway
" 1>&2
   exit 1
fi

# INPUT PARAMETERS
interfaceName=$1
newIpAddress=$2
newDefaultGateway=$3
oldIpAddress=`ip -4 -o addr show $interfaceName | awk '/inet / {print $4}' | cut -d '/' -f 1`
oldDefaultGateway=`ip route list | awk '/^default/ {print  $3}'`

# CONFIGS
OS_NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
KUBERNETES_PATH="/etc/kubernetes/"
KUBERNETES_PATH_BAK="/etc/kubernetes.bak/"
KUBERNETES_PATH_PKI="/etc/kubernetes/pki/"

# Change ip on kubernetes configmaps
configmaps=$(kubectl get cm -n kube-system -o custom-columns='NAME:.metadata.name' --no-headers)
for cm in $configmaps; do
  KUBE_EDITOR="sed -i s/$oldIpAddress/$newIpAddress/g" kubectl edit cm $cm -n kube-system
  echo "Changed ip on Configmap: $cm"
done

# Make backup of kubernetes configs folder
echo "Make backup of kubernetes config folder"
rm -rf mkdir $KUBERNETES_PATH_BAK
mkdir $KUBERNETES_PATH_BAK
cp -rf $KUBERNETES_PATH $KUBERNETES_PATH_BAK

# Change ip on kubernetes configs folder
echo "Change ip on kubernetes configs folder"
find $KUBERNETES_PATH -type f | xargs sed -i "s/$oldIpAddress/$newIpAddress/"

# Change OS ip address
echo "Change OS ip address (WARNING: Connection will be lost if you are connected remotely, however the script will continue to run until the end.)"
sed -i "s/$oldIpAddress/$newIpAddress/g" $OS_NETPLAN_FILE
sed -i "s/$oldDefaultGateway/$newDefaultGateway/g" $OS_NETPLAN_FILE
netplan apply

# Change ip on kubernetes cert pki folder
echo "Change ip on kubernetes cert pki folder"
for f in $(find $KUBERNETES_PATH_PKI -name "*.crt"); do 
   if (openssl x509 -in $f -text -noout | grep -q $oldIpAddress); then
      echo "Remove old certificate $f and generate a new one"
      fn=`basename $f .crt`
      fp=`dirname $f`
      rm $fp/$fn.*
      fs=`realpath -m --relative-to $KUBERNETES_PATH_PKI $fp`
      if [[ ${fs} == "." ]]; then
         kubeadm init phase certs $fn
      else
         kubeadm init phase certs $fs-$fn
      fi
   fi
done

# Restart services
echo "Restart services"
systemctl restart kubelet
systemctl restart containerd

# Overwrite admin config on local cluster user folder
echo "Overwrite admin config on local cluster user folder"
yes | cp $KUBERNETES_PATH/admin.conf $HOME/.kube/config
