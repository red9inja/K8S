#!/bin/bash

set -e

CONFIG_FILE="cluster_config.yaml"

# Check for dependencies
command -v yq >/dev/null 2>&1 || { echo >&2 "yq is required but not installed. Install with: sudo snap install yq"; exit 1; }

# Read from YAML
K8S_VERSION=$(yq '.kubernetes_version' "$CONFIG_FILE")
VIP=$(yq '.load_balancer_ip' "$CONFIG_FILE")

# Extract master and worker arrays
MASTER_COUNT=$(yq '.masters | length' "$CONFIG_FILE")
WORKER_COUNT=$(yq '.workers | length' "$CONFIG_FILE")

function setup_common_requirements() {
  local IP=$1
  local USER=$2
  local PEM=$3

  ssh -o StrictHostKeyChecking=no -i "$PEM" "$USER@$IP" "sudo apt update && \
    sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release && \
    sudo mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg && \
    echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main\" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null && \
    sudo apt update && \
    sudo apt install -y kubelet=${K8S_VERSION}-00 kubeadm=${K8S_VERSION}-00 kubectl=${K8S_VERSION}-00 containerd && \
    sudo apt-mark hold kubelet kubeadm kubectl"
}

function setup_first_master() {
  local IP=$1
  local USER=$2
  local PEM=$3

  echo "[INFO] Setting up first master at $IP"

  setup_common_requirements "$IP" "$USER" "$PEM"

  ssh -i "$PEM" "$USER@$IP" "sudo hostnamectl set-hostname master0.1"

  ssh -i "$PEM" "$USER@$IP" "
    sudo kubeadm init \
      --control-plane-endpoint=$VIP:6443 \
      --upload-certs \
      --kubernetes-version ${K8S_VERSION} \
      --pod-network-cidr=10.244.0.0/16 > /tmp/kubeinit.log
  "

  echo "[INFO] Copying kubeconfig for kubectl"
  ssh -i "$PEM" "$USER@$IP" "mkdir -p ~/.kube && sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config && sudo chown \
    \\$(id -u):\\$(id -g) ~/.kube/config"

  echo "[INFO] Installing Flannel CNI"
  ssh -i "$PEM" "$USER@$IP" "kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"

  echo "[INFO] Deploying kube-vip"
  ssh -i "$PEM" "$USER@$IP" "
    export VIP=$VIP
    ctr image pull ghcr.io/kube-vip/kube-vip:latest
    ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:latest vip kube-vip manifest pod --interface eth0 --vip \$VIP --controlplane --services --arp --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
  "

  echo "[INFO] Retrieving join command"
  ssh -i "$PEM" "$USER@$IP" "
    kubeadm token create --print-join-command > /tmp/join.sh
    kubeadm token create --certificate-key $(kubeadm init phase upload-certs --upload-certs | tail -1) >> /tmp/join.sh
  "

  scp -i "$PEM" "$USER@$IP:/tmp/join.sh" ./join.sh
}

function join_master() {
  local IP=$1
  local USER=$2
  local PEM=$3
  local INDEX=$4

  echo "[INFO] Joining master $INDEX at $IP"
  setup_common_requirements "$IP" "$USER" "$PEM"
  ssh -i "$PEM" "$USER@$IP" "sudo hostnamectl set-hostname master0.$INDEX"
  scp -i "$PEM" ./join.sh "$USER@$IP:/tmp/join.sh"
  ssh -i "$PEM" "$USER@$IP" "chmod +x /tmp/join.sh && sudo bash /tmp/join.sh"
}

function join_worker() {
  local IP=$1
  local USER=$2
  local PEM=$3
  local INDEX=$4

  echo "[INFO] Joining worker $INDEX at $IP"
  setup_common_requirements "$IP" "$USER" "$PEM"
  ssh -i "$PEM" "$USER@$IP" "sudo hostnamectl set-hostname worker0.$INDEX"
  scp -i "$PEM" ./join.sh "$USER@$IP:/tmp/join.sh"
  ssh -i "$PEM" "$USER@$IP" "chmod +x /tmp/join.sh && sudo bash /tmp/join.sh"
}

# === Master setup ===
FIRST_MASTER_IP=$(yq '.masters[0].ip' "$CONFIG_FILE")
FIRST_MASTER_USER=$(yq '.masters[0].user' "$CONFIG_FILE")
FIRST_MASTER_PEM=$(yq '.masters[0].pem' "$CONFIG_FILE")

setup_first_master "$FIRST_MASTER_IP" "$FIRST_MASTER_USER" "$FIRST_MASTER_PEM"

for i in $(seq 1 $((MASTER_COUNT - 1))); do
  IP=$(yq ".masters[$i].ip" "$CONFIG_FILE")
  USER=$(yq ".masters[$i].user" "$CONFIG_FILE")
  PEM=$(yq ".masters[$i].pem" "$CONFIG_FILE")
  join_master "$IP" "$USER" "$PEM" "$((i+1))"
  sleep 5
done

# === Worker setup ===
for i in $(seq 0 $((WORKER_COUNT - 1))); do
  IP=$(yq ".workers[$i].ip" "$CONFIG_FILE")
  USER=$(yq ".workers[$i].user" "$CONFIG_FILE")
  PEM=$(yq ".workers[$i].pem" "$CONFIG_FILE")
  join_worker "$IP" "$USER" "$PEM" "$((i+1))"
  sleep 5
done

echo "[SUCCESS] Kubernetes cluster is up with $MASTER_COUNT masters and $WORKER_COUNT workers."
