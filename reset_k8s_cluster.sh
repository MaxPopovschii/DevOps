#!/bin/bash

# Verifica se 'kubectl' è installato
if ! command -v kubectl &> /dev/null; then
  echo "kubectl non è installato. Installalo prima di eseguire questo script."
  exit 1
fi

# Verifica se c'è un cluster Kubernetes attivo
if kubectl cluster-info &> /dev/null; then
  echo "Cluster Kubernetes rilevato. Procedo con il reset..."
  
  # Esegui il reset del cluster
  sudo kubeadm reset -f
  
  # Pulizia dei file di configurazione Kubernetes
  echo "Rimuovo i file di configurazione residui..."
  sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /var/lib/dockershim /var/run/kubernetes
  sudo rm -rf ~/.kube
  
  echo "Reset del cluster completato con successo."
else
  echo "Nessun cluster Kubernetes rilevato sul nodo corrente."
fi
