#!/bin/bash
set -e

# Configuration variables
K8S_VERSION="1.32.0"
K8S_REPO_BRANCH="v1.32"
CONTROL_PLANE_ENDPOINT=$(hostname -I | awk '{print $1}') # Use first IP or replace with your endpoint
POD_NETWORK_CIDR="10.244.0.0/16"
FLANNEL_URL="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"

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

# Diagnostic: Test connectivity to pkgs.k8s.io
echo "Testing connectivity to Kubernetes repository..."
if ! curl -fsSL -I https://pkgs.k8s.io/core:/stable:/${K8S_REPO_BRANCH}/deb/Release.key | grep "HTTP/1.1 200"; then
  echo "Warning: Unable to reach Kubernetes repository. Checking HTTP status..."
  curl -v https://pkgs.k8s.io/core:/stable:/${K8S_REPO_BRANCH}/deb/Release.key 2>&1 | grep "< HTTP"
  echo "Possible network issue or repository outage. Please check security groups, proxy settings, or try a different network."
fi

# Add Kubernetes repository with retry logic
RETRY_COUNT=5
ATTEMPT=1
K8S_KEY_URL="https://pkgs.k8s.io/core:/stable:/${K8S_REPO_BRANCH}/deb/Release.key"
while [ $ATTEMPT -le $RETRY_COUNT ]; do
  echo "Attempt $ATTEMPT: Downloading Kubernetes repository key from $K8S_KEY_URL ..."
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  if curl -fsSL "$K8S_KEY_URL" | gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
    echo "Successfully downloaded Kubernetes repository key."
    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    break
  else
    echo "Failed to download Kubernetes repository key (attempt $ATTEMPT/$RETRY_COUNT)."
    if [ $ATTEMPT -eq $RETRY_COUNT ]; then
      echo "Exhausted retry attempts. Troubleshooting suggestions:"
      echo "1. Verify network connectivity to $K8S_KEY_URL"
      echo "2. Check for proxy settings: export https_proxy='http://your-proxy:port'"
      echo "3. Check if the K8S_VERSION and K8S_REPO_BRANCH are correct and available at pkgs.k8s.io."
      echo "   Current K8S_VERSION=$K8S_VERSION, K8S_REPO_BRANCH=$K8S_REPO_BRANCH"
      echo "4. Check Kubernetes community for repository status: https://discuss.kubernetes.io"
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

echo "Attempting to install: $KUBELET_PACKAGE $KUBEADM_PACKAGE $KUBECTL_PACKAGE"
if ! apt-get install -y "$KUBELET_PACKAGE" "$KUBEADM_PACKAGE" "$KUBECTL_PACKAGE" vim git curl wget; then
  echo "Failed to install Kubernetes packages. This usually means the exact version (${K8S_VERSION}-1.1) is not available."
  echo "Please check available versions using: apt-cache madison kubelet"
  echo "And update the KUBELET_PACKAGE, KUBEADM_PACKAGE, KUBECTL_PACKAGE variables accordingly."
  exit 1
fi
apt-mark hold kubelet kubeadm kubectl

echo "Step 2: Swap Off and Kernel Modules Setup"
if grep -q " swap " /etc/fstab; then
  echo "Disabling swap in /etc/fstab..."
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

# Check if containerd is already installed
if ! command -v containerd &> /dev/null; then
  echo "Containerd not found, installing..."
  mkdir -p /etc/apt/keyrings
  rm -f /etc/apt/keyrings/docker-archive-keyring.gpg
  if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --yes --dearmor -o /etc/apt/keyrings/docker-archive-keyring.gpg; then
    echo "Failed to download Docker repository key. Exiting."
    exit 1
  fi

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -y
  if ! apt-get install -y containerd.io="1.7.22-1"; then
    echo "Failed to install containerd.io. Please check if version 1.7.22-1 is available."
    echo "You can check available versions with: apt-cache madison containerd.io"
    exit 1
  fi
else
  echo "Containerd is already installed, skipping installation."
fi

# Configure containerd
# Always regenerate the default config to ensure it's up-to-date with the installed containerd version
echo "Generating (or regenerating) default containerd config.toml..."
containerd config default | tee /etc/containerd/config.toml > /dev/null

# Ensure SystemdCgroup is true
if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  echo "Updated SystemdCgroup to true in /etc/containerd/config.toml"
else
  echo "SystemdCgroup is already true in /etc/containerd/config.toml"
fi

# IMPORTANT: Ensure containerd is restarted AFTER config changes and its socket is available.
echo "Restarting containerd service..."
systemctl daemon-reload # Reload systemd daemons in case units changed
systemctl restart containerd
systemctl enable containerd

# Verify containerd status and socket availability before proceeding
echo "Verifying containerd service status..."
if ! systemctl is-active --quiet containerd; then
  echo "Error: containerd service is not active. Check 'systemctl status containerd' for details."
  exit 1
fi
echo "Containerd service is active."

echo "Waiting for containerd socket to be available..."
SOCKET_PATH="/run/containerd/containerd.sock"
MAX_WAIT_TIME=60
WAIT_COUNT=0
while [ ! -S "$SOCKET_PATH" ]; do
  if [ $WAIT_COUNT -ge $MAX_WAIT_TIME ]; then
    echo "Error: Containerd socket ($SOCKET_PATH) did not appear after $MAX_WAIT_TIME seconds."
    echo "Check containerd logs: 'journalctl -u containerd -f'"
    exit 1
  fi
  echo "Waiting for $SOCKET_PATH (attempt $((WAIT_COUNT + 1))/$MAX_WAIT_TIME)..."
  sleep 1
  WAIT_COUNT=$((WAIT_COUNT + 1))
done
echo "Containerd socket is available at $SOCKET_PATH."

# Enable kubelet - this can be done after containerd is ready
systemctl enable kubelet

echo "Step 4: Pull Kubernetes images and init cluster"

# Pull Kubernetes images
RETRY_COUNT=5 # Increased retry count for image pull
ATTEMPT=1
while [ $ATTEMPT -le $RETRY_COUNT ]; do
  echo "Attempt $ATTEMPT: Pulling Kubernetes images with kubeadm..."
  if kubeadm config images pull \
    --cri-socket unix:///run/containerd/containerd.sock \
    --kubernetes-version v$K8S_VERSION; then
    echo "Successfully pulled Kubernetes images."
    break
  else
    echo "Failed to pull Kubernetes images (attempt $ATTEMPT/$RETRY_COUNT). Retrying..."
    if [ $ATTEMPT -eq $RETRY_COUNT ]; then
      echo "Exhausted retry attempts for image pull. Check network connectivity, containerd status, or K8S_VERSION."
      echo "You can try running 'crictl info' to check containerd's CRI status."
      exit 1
    fi
    sleep 10
  fi
  ((ATTEMPT++))
done

# Initialize cluster
if [ -f /etc/kubernetes/admin.conf ]; then
  echo "Kubernetes cluster appears to be already initialized (/etc/kubernetes/admin.conf exists). Skipping kubeadm init."
else
  echo "Initializing Kubernetes cluster..."
  if ! kubeadm init \
    --pod-network-cidr="$POD_NETWORK_CIDR" \
    --upload-certs \
    --kubernetes-version v$K8S_VERSION \
    --control-plane-endpoint="$CONTROL_PLANE_ENDPOINT" \
    --cri-socket unix:///run/containerd/containerd.sock; then
    echo "Kubernetes cluster initialization failed. Please check logs above for errors."
    echo "Consider running 'kubeadm reset' and trying again if this is a fresh attempt."
    exit 1
  fi
fi

# Setup kubeconfig for user
if [ ! -d "$HOME/.kube" ]; then
  mkdir -p "$HOME/.kube"
fi

if [ -f "/etc/kubernetes/admin.conf" ]; then
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
  echo "export KUBECONFIG=$HOME/.kube/config" >> "$HOME/.bashrc"
  export KUBECONFIG="$HOME/.kube/config"
  echo "Kubeconfig has been set up for the current user and added to ~/.bashrc."
else
  echo "Warning: /etc/kubernetes/admin.conf not found. Kubeconfig setup might be incomplete."
fi

echo "Step 5: Apply Flannel Network"

# Apply Flannel CNI
RETRY_COUNT=5
ATTEMPT=1
while [ $ATTEMPT -le $RETRY_COUNT ]; do
  echo "Attempt $ATTEMPT: Applying Flannel CNI from $FLANNEL_URL..."
  if kubectl apply -f "$FLANNEL_URL"; then
    echo "Successfully applied Flannel CNI."
    break
  else
    echo "Failed to apply Flannel CNI (attempt $ATTEMPT/$RETRY_COUNT). API server might not be ready yet."
    if [ $ATTEMPT -eq $RETRY_COUNT ]; then
      echo "Exhausted retry attempts for Flannel CNI. Check API server status (kubectl get --raw=/healthz)."
      exit 1
    fi
    sleep 10
  fi
  ((ATTEMPT++))
done

# Remove control-plane taint
echo "Removing control-plane taint from node $(hostname)..."
NODE_NAME=$(hostname)
TIMEOUT=300 # 5 minutes timeout
START_TIME=$(date +%s)
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
  if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
    echo "Timeout waiting for node $NODE_NAME to be ready to remove taint. Proceeding anyway, but check node status manually."
    break
  fi

  if kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
    echo "Node $NODE_NAME is Ready. Removing taint."
    kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule-
    echo "Taint removed successfully."
    break
  else
    echo "Node $NODE_NAME not yet Ready. Waiting 10 seconds before re-checking..."
    sleep 10
  fi
done

echo "Step 6: Verify Cluster"
echo "Waiting for nodes to become ready (up to 120 seconds)..."
sleep 10 # Initial sleep

TIMEOUT=120
START_TIME=$(date +%s)
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
  if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
    echo "Timeout waiting for nodes to be ready. Proceeding with verification, but some nodes might still be NotReady."
    break
  fi

  if kubectl get nodes -o wide | grep -q " Ready"; then
    echo "Nodes are showing as Ready."
    break
  else
    echo "Nodes not yet Ready. Waiting 10 seconds before re-checking..."
    sleep 10
  fi
done

kubectl get nodes -o wide
echo "Checking pod status in kube-system namespace..."
kubectl get pods -n kube-system -o wide

echo "Kubernetes cluster setup is complete!"
echo "Note: Secure the $HOME/.kube/config file, as it contains sensitive cluster credentials."
echo "To interact with your cluster, ensure KUBECONFIG is set in your environment or source ~/.bashrc."
