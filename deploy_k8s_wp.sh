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
NET_IF="enp0s3"
SECOND_IF="enp0s8"
THIRD_IF="enp0s9"

function configure_netplan() {
  local ipaddr=$1
  cat <<EOF >/etc/netplan/50-cloud-init.yaml
network:
  version: 2
  ethernets:
    ${NET_IF}:
      dhcp4: no
      addresses:
        - ${ipaddr}/24
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
      routes:
        - to: 0.0.0.0/0
          via: 10.10.10.1
          metric: 100
EOF
  netplan apply
}

function prepare_system() {
  apt update
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab
  if grep -q 'swap' /proc/swaps; then
    echo "⚠️  No se pudo desactivar el swap completamente. Verifica fstab manualmente."
  fi
  modprobe overlay
  modprobe br_netfilter
  tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system
}

function install_containerd() {
  apt install -y docker.io
  systemctl enable docker
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
}

function install_k8s_tools() {
  apt install -y apt-transport-https ca-certificates curl
  rm -f /usr/share/keyrings/kubernetes-archive-keyring.gpg
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --yes --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
  apt update
  apt install -y kubelet kubeadm kubectl
  systemctl enable kubelet
}

function init_master() {
  # Inicializa el clúster ignorando errores de CPU y memoria
  kubeadm init --pod-network-cidr=10.10.0.0/16 --ignore-preflight-errors=NumCPU,Mem | tee /root/kubeinit.log
  mkdir -p $HOME/.kube
  cp /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
  JOIN_CMD=$(grep -A2 "kubeadm join" /root/kubeinit.log | tr '\n' ' ')
  echo "Usa este comando en los nodos worker:"
  echo "$JOIN_CMD"

  # Quitar taint del nodo master para permitir scheduling de pods
  kubectl taint nodes master node-role.kubernetes.io/control-plane- || true

  # Copiar config para usuario no root
  mkdir -p /home/administrador/.kube
  cp -i /etc/kubernetes/admin.conf /home/administrador/.kube/config
  chown administrador:administrador /home/administrador/.kube/config
}

# (resto del script sigue igual)
