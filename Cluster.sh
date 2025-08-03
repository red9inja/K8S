#!/bin/bash

CONFIG_FILE="cluster_config.yaml"
PYTHON_CMD=$(command -v python3)

# Check for required tools
for tool in curl sshpass ssh scp; do
  command -v $tool >/dev/null 2>&1 || { echo "$tool is required but not installed."; exit 1; }
done

# Install PyYAML if missing
$PYTHON_CMD -c "import yaml" 2>/dev/null || {
  echo "Installing PyYAML for Python..."
  $PYTHON_CMD -m pip install pyyaml
}

# Extract values using Python
parse_config() {
  $PYTHON_CMD <<EOF
import yaml
with open("$CONFIG_FILE") as f:
    data = yaml.safe_load(f)
version = data.get("kubernetes_version", "")
print("VERSION:" + (version or ""))
for w in data.get("workers", []):
    line = f"{w['ip']}::{w['user']}::{w['auth']}::" + (w.get('password', '') or w.get('pem', ''))
    print("WORKER:" + line)
EOF
}

# Parse config
WORKERS=()
VERSION=""
while IFS= read -r line; do
  if [[ $line == VERSION:* ]]; then
    VERSION="${line#VERSION:}"
  elif [[ $line == WORKER:* ]]; then
    WORKERS+=("${line#WORKER:}")
  fi
done < <(parse_config)

# Use latest stable version if none provided
if [[ -z "$VERSION" ]]; then
  echo "Fetching latest Kubernetes version..."
  VERSION=$(curl -s https://dl.k8s.io/release/stable.txt | tr -d 'v')
fi

echo "Using Kubernetes version: $VERSION"

# Set master hostname
hostnamectl set-hostname master

# Check if already initialized
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "[+] Initializing control plane..."
  kubeadm init --kubernetes-version "$VERSION" --pod-network-cidr=10.244.0.0/16
  mkdir -p $HOME/.kube
  cp /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
  echo "[+] Installing Flannel network plugin..."
  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
else
  echo "[*] Master is already initialized. Skipping kubeadm init."
fi

# Generate join command
JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
if [[ -z "$JOIN_CMD" ]]; then
  echo "[!] Failed to generate join command. Exiting."
  exit 1
fi

echo "[+] Join command: $JOIN_CMD"

# Count existing workers
EXISTING_NODES=$(kubectl get nodes --no-headers | grep -v master | wc -l)
COUNT=$((EXISTING_NODES + 1))

# Loop through workers
for entry in "${WORKERS[@]}"; do
  IFS="::" read -r ip user auth secret <<< "$entry"

  # Check if node already exists
  if kubectl get nodes -o wide | grep -q "$ip"; then
    echo "[*] Worker $ip already part of cluster. Skipping."
    continue
  fi

  echo "[+] Adding worker $ip..."

  HOSTNAME="worker0.$COUNT"
  SETUP_CMDS=$(cat <<EOC
sudo hostnamectl set-hostname $HOSTNAME
sudo apt-get update
sudo apt-get install -y apt-transport-https curl containerd jq
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
sudo apt-get install -y ca-certificates curl
sudo curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
sudo apt-get update
sudo apt-get install -y kubelet=$VERSION-00 kubeadm=$VERSION-00 kubectl=$VERSION-00
sudo apt-mark hold kubelet kubeadm kubectl
sudo $JOIN_CMD
EOC
)

  if [[ "$auth" == "password" ]]; then
    sshpass -p "$secret" ssh -o StrictHostKeyChecking=no "$user@$ip" "$SETUP_CMDS"
  else
    ssh -o StrictHostKeyChecking=no -i "$secret" "$user@$ip" "$SETUP_CMDS"
  fi

  echo "[+] Worker $ip added as $HOSTNAME"
  COUNT=$((COUNT + 1))
done

# Firewall guidance
echo
echo "[!] Ensure firewall rules allow:"
echo "    ➤ Port 6443/TCP from worker node IPs to master"
echo "    ➤ Port 8472/UDP open to all (Flannel VXLAN)"
echo "[✓] Kubernetes cluster setup complete."
