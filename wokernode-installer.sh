#!/bin/bash
set -e

# Configuration variables
K8S_VERSION="1.32.0"
K8S_REPO_BRANCH="v1.32"

# 🔑 Update this section manually when token/hash changes
KUBEADM_JOIN_COMMAND="kubeadm join 172.31.15.44:6443 \
--token j84f6r.s6mnjq03b2spwdj5 \
--discovery-token-ca-cert-hash sha256:0903ae31ed00337b75b7a9d77c71b935c7c53536e66bb7a0b7f52abec0e7651c \
--cri-socket unix:///run/containerd/containerd.sock"

# Ensure script is run as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root. Use sudo or switch to the root user."
  exit 1
fi

# Check for Ubuntu
if ! grep -qi "ubuntu" /etc/os-release; then
  echo "This script is designed for Ubuntu. Other distributions are not supported."
  exit 1
fi

echo "Step 1: Install kubectl, kubeadm, and kubelet v$K8S_VERSION"

# Prepare keyrings
mkdir -p /etc/apt/keyrings
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg

# Add Kubernetes repository with retry logic
RETRY_COUNT=5
ATTEMPT=1
K8S_KEY_URL="https://pkgs.k8s.io/core:/stable:/${K8S_REPO_BRANCH}/deb/Release.key"
while [ $ATTEMPT -le $RETRY_COUNT ]; do
  echo "Attempt $ATTEMPT: Downloading Kubernetes repository key..."
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  if curl -fsSL "$K8S_KEY_URL" | gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    break
  else
    echo "Failed to download Kubernetes repository key (attempt $ATTEMPT/$RETRY_COUNT)."
    if [ $ATTEMPT -eq $RETRY_COUNT ]; then
      exit 1
    fi
    sleep 15
  fi
  ((ATTEMPT++))
done

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_REPO_BRANCH}/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list
chmod 644 /etc/apt/sources.list.d/kubernetes.list

# Update and install Kubernetes components
apt-get update -y
KUBELET_PACKAGE="kubelet=${K8S_VERSION}-1.1"
KUBEADM_PACKAGE="kubeadm=${K8S_VERSION}-1.1"
KUBECTL_PACKAGE="kubectl=${K8S_VERSION}-1.1"

echo "Installing: $KUBELET_PACKAGE $KUBEADM_PACKAGE $KUBECTL_PACKAGE"
apt-get install -y "$KUBELET_PACKAGE" "$KUBEADM_PACKAGE" "$KUBECTL_PACKAGE" vim git curl wget
apt-mark hold kubelet kubeadm kubectl

echo "Step 2: Swap Off and Kernel Modules Setup"
if grep -q " swap " /etc/fstab; then
  sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
fi
swapoff -a
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

cat <<EOF | tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

echo "Step 3: Install and Configure Containerd"

if ! command -v containerd &> /dev/null; then
  echo "Installing containerd..."
  mkdir -p /etc/apt/keyrings
  rm -f /etc/apt/keyrings/docker-archive-keyring.gpg
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --yes --dearmor -o /etc/apt/keyrings/docker-archive-keyring.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -y
  apt-get install -y containerd.io="1.7.22-1"
else
  echo "Containerd is already installed."
fi

echo "Generating containerd config..."
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl daemon-reload
systemctl restart containerd
systemctl enable containerd

if ! systemctl is-active --quiet containerd; then
  echo "Error: containerd is not active. Check logs with: journalctl -u containerd -f"
  exit 1
fi
echo "Containerd is active."

systemctl enable kubelet

echo "Step 4: Join the Kubernetes cluster"
echo "Executing: $KUBEADM_JOIN_COMMAND"
eval $KUBEADM_JOIN_COMMAND

echo "✅ Worker node setup complete and joined to the cluster!"
