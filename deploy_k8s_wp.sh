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
  apt install -y curl ca-certificates gnupg lsb-release
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab
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
  cp /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
  JOIN_CMD=$(grep -A2 "kubeadm join" /root/kubeinit.log | tr '\n' ' ')
  echo "Usa este comando en los nodos worker:"
  echo "$JOIN_CMD"
  kubectl taint nodes master node-role.kubernetes.io/control-plane- || true
  NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane- || true
  mkdir -p /home/administrador/.kube
  cp -i /etc/kubernetes/admin.conf /home/administrador/.kube/config
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
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: mysql-pass
type: Opaque
stringData:
  password: "1234"
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pv-claim
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wordpress-pv-claim
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mysql-service
spec:
  ports:
    - port: 3306
  selector:
    app: mysql
  clusterIP: None
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql-deployment
spec:
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:5.7
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-pass
              key: password
        - name: MYSQL_DATABASE
          value: "wordpress"
        - name: MYSQL_USER
          value: "wordpress"
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-pass
              key: password
        ports:
        - containerPort: 3306
          name: mysql
        volumeMounts:
        - name: mysql-persistent-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mysql-persistent-storage
        persistentVolumeClaim:
          claimName: mysql-pv-claim
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: wordpress-service
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30090
  selector:
    app: wordpress
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: wordpress
  template:
    metadata:
      labels:
        app: wordpress
    spec:
      containers:
      - name: wordpress
        image: wordpress:latest
        env:
        - name: WORDPRESS_DB_HOST
          value: mysql-service
        - name: WORDPRESS_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-pass
              key: password
        - name: WORDPRESS_DB_USER
          value: "wordpress"
        - name: WORDPRESS_DB_NAME
          value: "wordpress"
        ports:
        - containerPort: 80
          name: wordpress
        volumeMounts:
        - name: wordpress-persistent-storage
          mountPath: /var/www/html
      volumes:
      - name: wordpress-persistent-storage
        persistentVolumeClaim:
          claimName: wordpress-pv-claim
EOF

  echo "Despliegue de WordPress y MySQL completado."
}

# Habilitar servicios
# Nota: Esta parte ahora se realiza después de instalar containerd y kubelet

# Flujo principal
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
  if [[ "$CUR_IP" == "$WORKER1_IP" || "$CUR_IP" == "$WORKER2_IP" ]]; then
    configure_netplan "$CUR_IP"
  else
    echo "No se reconoce la IP $CUR_IP, ajuste MASTER_IP/WORKER_IP en el script." >&2
    exit 1
  fi
  prepare_system
  install_containerd
  install_k8s_tools
  systemctl enable containerd kubelet
  if [[ -z "$JOIN_CMD" ]]; then
    echo "Debe proporcionar el comando de join: kubeadm join ..." >&2
    exit 1
  fi
  $JOIN_CMD --ignore-preflight-errors=NumCPU,Mem
else
  echo "Uso: $0 <master|worker> [\"<join_command>\"]" >&2
  exit 1
fi

# Verificar WordPress
WP_IP=$(hostname -I | awk '{print $1}')
echo "⏳ Esperando a que WordPress esté disponible en http://$WP_IP:30090 ..."
for i in {1..30}; do
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
