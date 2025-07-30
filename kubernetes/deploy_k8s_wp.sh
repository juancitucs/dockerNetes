#!/usr/bin/env bash

# deploy_k8s_wp.sh - Instala y configura Kubernetes con WordPress+MySQL
# Uso: sudo ./deploy_k8s_wp.sh <master|worker> ["<join_command>"]
# Ejemplo master: sudo ./deploy_k8s_wp.sh master
# Ejemplo worker: sudo ./deploy_k8s_wp.sh worker "kubeadm join ..."

set -euo pipefail
ROLE=${1:-}
JOIN_CMD=${2:-}

# Variables de red (ajustar según infraestructura)
MASTER_IP="10.10.10.10"
WORKER1_IP="10.10.10.11"
WORKER2_IP="10.10.10.12"
YAML_DIR="$(dirname "$0")/files/yaml"

function configure_netplan() {
  local ipaddr=$1
  cp -f "$(dirname "$0")/files/netplan/50-cloud-init.yaml" /etc/netplan/50-cloud-init.yaml
  sed -i "s/IPADDR/${ipaddr}/g" /etc/netplan/50-cloud-init.yaml
  netplan apply
}

function prepare_system() {
  apt update
  apt install -y curl ca-certificates gnupg lsb-release
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab
  modprobe overlay
  modprobe br_netfilter
  tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  cp -f "$(dirname "$0")/files/etc-sysctl.d-k8s.conf/k8s.conf" /etc/sysctl.d/k8s.conf
  sysctl --system
}

function install_containerd() {
  apt install -y containerd
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  systemctl enable containerd
}

function install_k8s_tools() {
  rm -f /usr/share/keyrings/kubernetes-archive-keyring.gpg
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --yes --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
  apt update
  apt install -y kubelet kubeadm kubectl
  systemctl enable kubelet
}

function init_master() {
  kubeadm init --pod-network-cidr=10.10.0.0/16 --ignore-preflight-errors=NumCPU,Mem | tee /root/kubeinit.log
  mkdir -p $HOME/.kube
  cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
  JOIN_CMD=$(grep -A2 "kubeadm join" /root/kubeinit.log | tr '\n' ' ')
  echo "Usa este comando en los nodos worker:"
  echo "$JOIN_CMD"
  echo "$JOIN_CMD" > joinCMD.txt
  NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane- || true
  mkdir -p /home/administrador/.kube
  cp -f /etc/kubernetes/admin.conf /home/administrador/.kube/config
  chown administrador:administrador /home/administrador/.kube/config
}

function install_calico() {
  curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
  sed -i 's|192.168.0.0/16|10.10.0.0/16|' calico.yaml
  kubectl apply -f calico.yaml
}

function install_localpath() {
  mkdir -p /opt/local-path-provisioner
  chmod 777 /opt/local-path-provisioner
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
}

function deploy_wordpress() {
  kubectl apply -f "$YAML_DIR/mysqlPass.yaml"
  kubectl apply -f "$YAML_DIR/storage.yaml"
  kubectl apply -f "$YAML_DIR/mysqlFull.yaml"
  kubectl apply -f "$YAML_DIR/wordpress.yaml"
  echo "Despliegue de WordPress y MySQL completado."
}

if [[ "$ROLE" == "master" ]]; then
  configure_netplan "$MASTER_IP"
  prepare_system
  install_containerd
  install_k8s_tools
  init_master
  install_calico
  install_localpath
  deploy_wordpress
elif [[ "$ROLE" == "worker" ]]; then
  CUR_IP=$(hostname -I | awk '{print $1}')
  if [[ "$CUR_IP" != "$WORKER1_IP" && "$CUR_IP" != "$WORKER2_IP" ]]; then
    echo "No se reconoce la IP $CUR_IP, ajuste MASTER_IP/WORKER_IP en el script." >&2
    exit 1
  fi
  configure_netplan "$CUR_IP"
  prepare_system
  install_containerd
  install_k8s_tools

  echo "🔄 Deteniendo servicios antes de purgar..."
  systemctl stop kubelet containerd

  echo "🧹 Limpiando configuraciones previas..."
  kubeadm reset -f || true
  rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/kubelet /var/lib/etcd /opt/cni/bin/*
  rm -rf /var/lib/containerd

  echo "🚀 Reinstalando containerd limpio..."
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd

  echo "✅ Reiniciando kubelet..."
  systemctl enable --now kubelet

  JOIN_CMD="$(cat joinCMD.txt)"
  if [[ -z "$JOIN_CMD" ]]; then
    echo "Debe proporcionar el comando de join en /root/joinCMD.txt" >&2
    exit 1
  fi

  echo "🚀 Uniéndose al clúster:"
  echo "sudo $JOIN_CMD"
  sudo $JOIN_CMD
fi


# Verificar WordPress
WP_IP=$(hostname -I | awk '{print $1}')
echo "⏳ Esperando a que WordPress esté disponible en http://$WP_IP:30090 ..."
for i in {1..120}; do
  sleep 5
  if curl -s --max-time 2 http://$WP_IP:30090 | grep -q 'WordPress'; then
    echo "✅ WordPress está en línea en: http://$WP_IP:30090"
    exit 0
  else
    echo "... esperando ($i/30)"
  fi
  if [[ $i -eq 30 ]]; then
    echo "❌ No se pudo verificar WordPress en http://$WP_IP:30090 tras 150 segundos."
    exit 1
  fi
done
