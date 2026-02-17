#!/bin/bash

# =============================================================
# Kubernetes Single-Node Setup Script for Ubuntu 24.04 LTS
# Master node acts as worker node
# Fixed: PATH, held packages, CNI conflict
# GPU Support: NVIDIA GPU Operator + test pod
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
HELM_VERSION="v3.16.4"
GPU_OPERATOR_VERSION="v25.3.0"   # Latest stable as of early 2026

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

# Detect if an NVIDIA GPU is present
GPU_PRESENT=false
if lspci 2>/dev/null | grep -qi nvidia; then
  GPU_PRESENT=true
  log "NVIDIA GPU detected. GPU Operator will be installed."
else
  warn "No NVIDIA GPU detected. GPU Operator steps will be skipped."
  warn "Re-run or set GPU_PRESENT=true to override."
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
# STEP 9: Install Helm (required for GPU Operator)
# -----------------------------------------------
header "STEP 9: Installing Helm $HELM_VERSION"

if command -v helm &>/dev/null; then
  log "Helm already installed: $(helm version --short)"
else
  log "Downloading and installing Helm $HELM_VERSION..."
  curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz -o /tmp/helm.tar.gz
  tar -zxf /tmp/helm.tar.gz -C /tmp
  mv /tmp/linux-amd64/helm /usr/local/bin/helm
  chmod +x /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  log "Helm installed: $(helm version --short)"
fi

# -----------------------------------------------
# STEP 10: NVIDIA GPU Operator
# -----------------------------------------------
header "STEP 10: NVIDIA GPU Operator"

if [[ "$GPU_PRESENT" == "true" ]]; then

  # 10a: Install NVIDIA container toolkit prerequisites
  log "Installing NVIDIA container toolkit prerequisites..."
  apt install -y apt-transport-https ca-certificates curl gnupg

  # Add NVIDIA container toolkit repo
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt update
  apt install -y nvidia-container-toolkit
  log "NVIDIA container toolkit installed."

  # 10b: Configure containerd to use NVIDIA runtime
  log "Configuring containerd NVIDIA runtime..."
  nvidia-ctk runtime configure --runtime=containerd
  # Ensure SystemdCgroup stays true after nvidia-ctk rewrites config
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  log "containerd restarted with NVIDIA runtime."

  # 10c: Add NVIDIA Helm repo and install GPU Operator
  log "Adding NVIDIA Helm repo..."
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
  helm repo update

  log "Creating gpu-operator namespace..."
  $KUBECTL_PATH create namespace gpu-operator 2>/dev/null || true

  log "Installing NVIDIA GPU Operator $GPU_OPERATOR_VERSION..."
  helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --version "$GPU_OPERATOR_VERSION" \
    --set driver.enabled=true \
    --set toolkit.enabled=false \
    --set operator.defaultRuntime=containerd \
    --wait --timeout=10m \
    | tee /root/gpu-operator-install.log

  log "GPU Operator installed. Waiting for pods to be ready (up to 5 min)..."
  $KUBECTL_PATH wait --for=condition=ready pod \
    --all -n gpu-operator \
    --timeout=300s 2>/dev/null || \
    warn "Some GPU Operator pods may still be initializing. Check: kubectl get pods -n gpu-operator"

  # 10d: Verify GPU node resource is advertised
  log "Checking node GPU resource allocation..."
  sleep 15
  GPU_COUNT=$($KUBECTL_PATH get node \
    -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
  if [[ -n "$GPU_COUNT" && "$GPU_COUNT" != "0" ]]; then
    log "GPUs available on node: $GPU_COUNT"
  else
    warn "GPU resource not yet advertised. Device plugin may still be starting."
    warn "Check: kubectl get pods -n gpu-operator"
  fi

  # 10e: Run GPU test pod
  header "STEP 10e: Running GPU Test Pod"

  log "Deploying GPU test pod (nvidia/cuda:12.4.0-base-ubuntu22.04)..."
  cat <<'GPUPOD' | $KUBECTL_PATH apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: default
  labels:
    app: gpu-test
spec:
  restartPolicy: Never
  containers:
    - name: gpu-test
      image: nvidia/cuda:12.4.0-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
        requests:
          nvidia.com/gpu: 1
GPUPOD

  log "Waiting for GPU test pod to complete (up to 3 min)..."
  $KUBECTL_PATH wait pod/gpu-test \
    --for=condition=Ready \
    --timeout=180s 2>/dev/null || true

  # Give it a moment to actually run and finish
  sleep 15

  POD_STATUS=$($KUBECTL_PATH get pod gpu-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  log "GPU test pod status: $POD_STATUS"

  echo ""
  echo -e "${BLUE}--- GPU Test Pod Logs ---${NC}"
  $KUBECTL_PATH logs gpu-test 2>/dev/null || warn "Logs not yet available. Run: kubectl logs gpu-test"
  echo -e "${BLUE}-------------------------${NC}"
  echo ""

  if [[ "$POD_STATUS" == "Succeeded" ]]; then
    log "GPU test pod PASSED. nvidia-smi ran successfully inside Kubernetes."
  else
    warn "GPU test pod is in state: $POD_STATUS"
    warn "It may still be pulling the image. Run: kubectl describe pod gpu-test"
  fi

else
  warn "No NVIDIA GPU detected — skipping GPU Operator and GPU test pod."
  warn "If you have a GPU that was not auto-detected, re-run with GPU_PRESENT=true:"
  warn "  GPU_PRESENT=true bash $0"
fi

# -----------------------------------------------
# STEP 11: Verify Full Cluster
# -----------------------------------------------
header "STEP 11: Verifying Installation"

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

if [[ "$GPU_PRESENT" == "true" ]]; then
  echo ""
  log "GPU Operator pods:"
  $KUBECTL_PATH get pods -n gpu-operator -o wide
fi

# -----------------------------------------------
# Done
# -----------------------------------------------
header "Done!"
echo -e "${GREEN}"
echo "  Kubernetes $K8S_VERSION is ready!"
echo ""
echo "  Core Commands:"
echo "    kubectl get nodes"
echo "    kubectl get pods -A"
echo "    kubectl run nginx --image=nginx"
echo ""

if [[ "$GPU_PRESENT" == "true" ]]; then
echo "  GPU Commands:"
echo "    kubectl get pods -n gpu-operator          # GPU Operator status"
echo "    kubectl logs gpu-test                     # View nvidia-smi output"
echo "    kubectl describe node | grep nvidia       # Check GPU capacity"
echo "    kubectl get pod gpu-test -o wide          # GPU test pod status"
echo ""
echo "  Run a GPU workload:"
echo "    kubectl run gpu-job --image=nvidia/cuda:12.4.0-base-ubuntu22.04 \\"
echo "      --restart=Never --limits='nvidia.com/gpu=1' -- nvidia-smi"
echo ""
fi

echo "  Worker node join command:"
echo "    grep -A2 'kubeadm join' /root/kubeadm-init.log"
echo -e "${NC}"