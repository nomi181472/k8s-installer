#!/bin/bash

# =============================================================
# Kubernetes Single-Node Setup Script for Ubuntu 24.04 LTS
# Master node acts as worker node
# Fixed: PATH, held packages, CNI conflict
# =============================================================

set -e

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

K8S_VERSION="v1.35"
POD_CIDR="10.244.0.0/16"

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header() { echo -e "\n${BLUE}========== $1 ==========${NC}\n"; }

if [[ $EUID -ne 0 ]]; then
  error "Please run as root: sudo bash $0"
fi

if ! grep -q "24.04" /etc/os-release; then
  warn "Designed for Ubuntu 24.04 LTS. Proceed with caution."
fi

# -----------------------------------------------
# STEP 1: System Preparation
# -----------------------------------------------
header "STEP 1: System Preparation"

log "Updating system..."
apt update && apt full-upgrade -y

log "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
systemctl mask swap.target

log "Loading kernel modules..."
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

log "Applying sysctl settings..."
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# -----------------------------------------------
# STEP 2: Install containerd
# -----------------------------------------------
header "STEP 2: Installing containerd"

apt install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

systemctl is-active --quiet containerd && log "containerd is running." || error "containerd failed."

# -----------------------------------------------
# STEP 3: Install kubeadm, kubelet, kubectl
# -----------------------------------------------
header "STEP 3: Installing Kubernetes Tools"

apt install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

log "Adding Kubernetes repo ($K8S_VERSION)..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list

apt update

# *** KEY FIX: Remove conflicting CNI package ***
log "Removing conflicting containernetworking-plugins package..."
apt remove -y containernetworking-plugins 2>/dev/null || true

# Fix any broken packages from previous attempts
log "Fixing any broken packages..."
dpkg --configure -a || true
apt install -f -y || true

# Unhold if previously held
log "Unholding kubernetes packages if previously held..."
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true

log "Installing kubelet kubeadm kubectl..."
apt install -y kubelet kubeadm kubectl --allow-change-held-packages

log "Re-holding kubernetes packages..."
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

KUBEADM_PATH=$(which kubeadm 2>/dev/null || echo "/usr/bin/kubeadm")
[[ ! -f "$KUBEADM_PATH" ]] && error "kubeadm not found after install!"

log "kubeadm version: $($KUBEADM_PATH version -o short)"

# -----------------------------------------------
# STEP 4: Initialize the Cluster
# -----------------------------------------------
header "STEP 4: Initializing Kubernetes Cluster"

log "Resetting any previous kubeadm state..."
$KUBEADM_PATH reset -f 2>/dev/null || true
rm -rf /etc/kubernetes /var/lib/etcd

NODE_IP=$(hostname -I | awk '{print $1}')
log "Node IP: $NODE_IP"

log "Running kubeadm init..."
$KUBEADM_PATH init \
  --pod-network-cidr=$POD_CIDR \
  --apiserver-advertise-address=$NODE_IP \
  | tee /root/kubeadm-init.log

[[ ! -f /etc/kubernetes/admin.conf ]] && \
  error "Init failed — admin.conf not found. Check /root/kubeadm-init.log"

log "Cluster initialized successfully."

# -----------------------------------------------
# STEP 5: Configure kubectl
# -----------------------------------------------
header "STEP 5: Configuring kubectl"

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
log "kubectl configured for root."

if [[ -n "$SUDO_USER" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$USER_HOME/.kube"
  cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
  chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube/config"
  log "kubectl configured for: $SUDO_USER"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
KUBECTL_PATH=$(which kubectl 2>/dev/null || echo "/usr/bin/kubectl")

# -----------------------------------------------
# STEP 6: Install Flannel CNI
# -----------------------------------------------
header "STEP 6: Installing Flannel CNI"

$KUBECTL_PATH apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
log "Flannel applied. Waiting 30s..."
sleep 30

# -----------------------------------------------
# STEP 7: Remove Control-Plane Taint
# -----------------------------------------------
header "STEP 7: Removing Control-Plane Taint"

$KUBECTL_PATH taint nodes --all node-role.kubernetes.io/control-plane- || true
log "Master node can now schedule workloads."

# -----------------------------------------------
# STEP 8: kubectl Autocomplete
# -----------------------------------------------
header "STEP 8: kubectl Autocomplete"

for RCFILE in /root/.bashrc; do
  grep -q 'kubectl completion' "$RCFILE" 2>/dev/null || {
    echo 'source <(kubectl completion bash)' >> "$RCFILE"
    echo 'alias k=kubectl'                   >> "$RCFILE"
    echo 'complete -o default -F __start_kubectl k' >> "$RCFILE"
  }
done

if [[ -n "$SUDO_USER" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  RCFILE="$USER_HOME/.bashrc"
  grep -q 'kubectl completion' "$RCFILE" 2>/dev/null || {
    echo 'source <(kubectl completion bash)' >> "$RCFILE"
    echo 'alias k=kubectl'                   >> "$RCFILE"
    echo 'complete -o default -F __start_kubectl k' >> "$RCFILE"
  }
fi

# -----------------------------------------------
# STEP 9: Verify
# -----------------------------------------------
header "STEP 9: Verifying Installation"

log "Waiting for node Ready (up to 2 min)..."
for i in {1..12}; do
  STATUS=$($KUBECTL_PATH get nodes --no-headers 2>/dev/null | awk '{print $2}')
  if [[ "$STATUS" == "Ready" ]]; then
    log "Node is Ready!"
    break
  fi
  echo "  Attempt $i/12 — Status: ${STATUS:-Pending}. Waiting 10s..."
  sleep 10
done

echo ""
$KUBECTL_PATH get nodes -o wide
echo ""
$KUBECTL_PATH get pods -A

# -----------------------------------------------
# Done
# -----------------------------------------------
header "Done!"
echo -e "${GREEN}"
echo "  Kubernetes $K8S_VERSION is ready!"
echo ""
echo "  Commands:"
echo "    kubectl get nodes"
echo "    kubectl get pods -A"
echo "    kubectl run nginx --image=nginx"
echo ""
echo "  Worker node join command:"
echo "    grep -A2 'kubeadm join' /root/kubeadm-init.log"
echo -e "${NC}"