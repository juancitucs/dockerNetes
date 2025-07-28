#!/usr/bin/env bash

echo "⚠️  Este script eliminará por completo Kubernetes y sus configuraciones."
read -p "¿Deseas continuar? [s/N]: " confirm
if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
  echo "Cancelado."
  exit 0
fi

echo "🧹 Ejecutando kubeadm reset..."
sudo kubeadm reset -f

echo "🧼 Limpiando configuraciones..."
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni /opt/cni ~/.kube

echo "📦 Verificando si /var/run/calico está montado como cgroup..."
if mountpoint -q /var/run/calico/cgroup; then
  echo "⛔ /var/run/calico/cgroup está montado como cgroup, no se eliminará."
else
  echo "🧼 Eliminando /var/run/calico..."
  sudo rm -rf /var/run/calico
fi

echo "🔌 Eliminando interfaces virtuales (si existen)..."
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true

echo "🔁 Reiniciando containerd y kubelet..."
sudo systemctl restart containerd
sudo systemctl restart kubelet

echo "✅ Kubernetes ha sido reseteado. Puedes volver a ejecutar:"
echo "   sudo ./deploy_k8s_wp.sh master"
