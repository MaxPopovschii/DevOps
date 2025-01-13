#!/bin/bash

# Controllo dei privilegi di root
if [ "$EUID" -ne 0 ]; then
  echo "Esegui lo script con privilegi di root."
  exit 1
fi

# Controllo degli argomenti dello script
if [ $# -ne 1 ]; then
  echo "Utilizzo: $0 <versione_target_kubernetes>"
  echo "Esempio: $0 1.31.0"
  exit 1
fi

TARGET_VERSION="$1"

# Validazione del formato della versione target
if ! [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Formato della versione non valido. Usa il formato x.y.z (es. 1.31.0)."
  exit 1
fi

# Ottieni la versione corrente del cluster
CURRENT_VERSION=$(kubeadm version -o short | tr -d 'v')
if [ -z "$CURRENT_VERSION" ]; then
  echo "Impossibile determinare la versione corrente di Kubernetes. Assicurati che kubeadm sia configurato correttamente."
  exit 1
fi

echo "Versione corrente del cluster: $CURRENT_VERSION"
echo "Versione target del cluster: $TARGET_VERSION"

# Verifica se la versione target è inferiore alla versione corrente
if [[ "$(printf '%s\n' "$CURRENT_VERSION" "$TARGET_VERSION" | sort -V | head -n1)" == "$TARGET_VERSION" ]] && [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]]; then
  echo "Il downgrade non è supportato. La versione corrente ($CURRENT_VERSION) è superiore alla versione target ($TARGET_VERSION)."
  exit 1
fi

# Funzione per aggiornare il repository apt
update_apt_repo() {
  local version=$1
  echo "Aggiornamento del repository apt per la versione $version..."
  sudo rm -rf /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$version/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v$version/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
}

# Funzione per aggiornare kubeadm, kubelet e kubectl
update_kube_components() {
  local version=$1
  echo "Aggiornamento di kubeadm, kubelet e kubectl alla versione $version..."
  sudo apt-mark unhold kubelet kubeadm kubectl
  sudo apt clean
  sudo apt update
  sudo apt install -y kubeadm=$version-1.1 kubelet=$version-1.1 kubectl=$version-1.1
  sudo apt-mark hold kubelet kubeadm kubectl
}

# Funzione per applicare gli aggiornamenti di kubeadm
upgrade_kubeadm() {
  local version=$1
  echo "Applicazione dell'upgrade di kubeadm alla versione $version..."
  sudo kubeadm upgrade plan
  sudo kubeadm upgrade apply "v$version" --yes
  sudo systemctl restart kubelet
}

# Inizio del ciclo di aggiornamento
while [[ "$(printf '%s\n' "$CURRENT_VERSION" "$TARGET_VERSION" | sort -V | head -n1)" == "$CURRENT_VERSION" ]] && [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]]; do
  echo "Versione corrente del cluster: $CURRENT_VERSION"
  echo "Versione target del cluster: $TARGET_VERSION"

  # Estrai la minor version corrente e quella target
  current_minor=$(echo "$CURRENT_VERSION" | cut -d'.' -f1,2)
  target_minor=$(echo "$TARGET_VERSION" | cut -d'.' -f1,2)

  # Ottieni l'ultima patch disponibile per la versione corrente
  update_apt_repo "$current_minor"
  latest_patch=$( apt-cache policy kubeadm | grep "Candidate" | awk '{print $2}' | cut -d'-' -f1)

  if [[ "$CURRENT_VERSION" == "$latest_patch" ]]; then
    if [[ "$current_minor" == "$target_minor" ]]; then
      # Aggiorna direttamente alla versione target
      update_kube_components "$TARGET_VERSION"
      upgrade_kubeadm "$TARGET_VERSION"
      CURRENT_VERSION=$(kubeadm version -o short | tr -d 'v')
    else
      # Passa alla prossima minor version
      next_minor=$(echo "$current_minor" | awk -F. '{printf "%d.%d", $1, $2+1}')
      update_apt_repo "$next_minor"
      next_version="$next_minor.0"
      update_kube_components "$next_version"
      upgrade_kubeadm "$next_version"
      CURRENT_VERSION=$(kubeadm version -o short | tr -d 'v')
    fi
  else
    # Aggiorna alla patch più recente
    update_kube_components "$latest_patch"
    upgrade_kubeadm "$latest_patch"
    CURRENT_VERSION=$(kubeadm version -o short | tr -d 'v')
  fi
done

# Pausa automatica prima di applicare Flannel
echo "Il cluster è stato aggiornato alla versione $CURRENT_VERSION."
echo "Attendi 10 secondi prima di applicare Flannel..."
sleep 10

# Applica Flannel
echo "Applicazione di Flannel..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "Aggiornamento completato. Kubernetes è stato aggiornato alla versione $CURRENT_VERSION."
