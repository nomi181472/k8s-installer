#!/bin/bash

# =============================================================
# Kubernetes Multi-Node Setup — MASTER NODE
# Ubuntu 24.04 LTS
# GPU: Auto-detected
# Usage: sudo bash install-kube-master.sh [OPTIONS]
#
# Options:
#   --api-ip <IP>         IP address for the API server advertise address
#                         (defaults to primary NIC IP)
#   --pod-cidr <CIDR>     Pod network CIDR (default: 10.244.0.0/16)
#   --k8s-version <ver>   Kubernetes minor version, e.g. v1.35 (default: v1.35)
#   --no-taint-remove     Keep control-plane taint (master won't schedule pods)
#   --token-file <path>   Where to save the join token info (default: /root/worker-join.sh)
#
# After this script completes, copy /root/worker-join.sh to each worker node
# and run: sudo bash worker-join.sh
# =============================================================

set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header() { echo -e "\n${BLUE}========== $1 ==========${NC}\n"; }

# -----------------------------------------------
# Defaults
# -----------------------------------------------
K8S_VERSION="v1.35"
POD_CIDR="10.244.0.0/16"
HELM_VERSION="v3.16.4"
GPU_OPERATOR_VERSION="v25.3.0"
REMOVE_TAINT=true
TOKEN_FILE="/root/worker-join.sh"
API_IP=""

# -----------------------------------------------
# Parse arguments
# -----------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-ip)         API_IP="$2";       shift 2 ;;
    --pod-cidr)       POD_CIDR="$2";     shift 2 ;;
    --k8s-version)    K8S_VERSION="$2";  shift 2 ;;
    --no-taint-remove) REMOVE_TAINT=false; shift ;;
    --token-file)     TOKEN_FILE="$2";   shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) warn "Unknown argument: $1"; shift ;;
  esac
done

# -----------------------------------------------
# Root check
# -----------------------------------------------
if [[ $EUID -ne 0 ]]; then
  error "Please run as root: sudo bash $0"
fi

if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
  warn "Designed for Ubuntu 24.04 LTS. Proceed with caution."
fi

# -----------------------------------------------
# Resolve API IP
# -----------------------------------------------
if [[ -z "$API_IP" ]]; then
  API_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  if [[ -z "$API_IP" ]]; then
    error "Could not auto-detect primary IP. Pass --api-ip <IP> manually."
  fi
  log "Auto-detected API server IP: $API_IP"
else
  log "Using specified API server IP: $API_IP"
fi

# -----------------------------------------------
# GPU Detection
# -----------------------------------------------
GPU_PRESENT=false
if lspci 2>/dev/null | grep -qi nvidia; then
  GPU_PRESENT=true
  log "NVIDIA GPU detected. GPU Operator will be installed."
else
  warn "No NVIDIA GPU detected on master. GPU Operator will be skipped on this node."
  warn "Workers with GPUs will auto-configure via the GPU Operator DaemonSet."
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
header "STEP 3: Installing Kubernetes Tools ($K8S_VERSION)"

apt install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list

apt update

log "Removing conflicting containernetworking-plugins package..."
apt remove -y containernetworking-plugins 2>/dev/null || true

dpkg --configure -a || true
apt install -f -y || true

apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt install -y kubelet kubeadm kubectl --allow-change-held-packages
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

log "Running kubeadm init (API IP: $API_IP, Pod CIDR: $POD_CIDR)..."
$KUBEADM_PATH init \
  --pod-network-cidr="$POD_CIDR" \
  --apiserver-advertise-address="$API_IP" \
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
log "Flannel applied. Waiting 30s for CNI to settle..."
sleep 30

# -----------------------------------------------
# STEP 7: Optionally Remove Control-Plane Taint
# -----------------------------------------------
header "STEP 7: Control-Plane Taint"

if [[ "$REMOVE_TAINT" == "true" ]]; then
  $KUBECTL_PATH taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
  log "Control-plane taint removed — master will also schedule workloads."
else
  log "Keeping control-plane taint — master will NOT schedule workloads (workers only)."
fi

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
# STEP 9: Install Helm
# -----------------------------------------------
header "STEP 9: Installing Helm $HELM_VERSION"

if command -v helm &>/dev/null; then
  log "Helm already installed: $(helm version --short)"
else
  curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz -o /tmp/helm.tar.gz
  tar -zxf /tmp/helm.tar.gz -C /tmp
  mv /tmp/linux-amd64/helm /usr/local/bin/helm
  chmod +x /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  log "Helm installed: $(helm version --short)"
fi

# -----------------------------------------------
# STEP 10: NVIDIA GPU Operator (master only if GPU present)
# -----------------------------------------------
header "STEP 10: NVIDIA GPU Operator"

if [[ "$GPU_PRESENT" == "true" ]]; then

  log "Installing NVIDIA container toolkit prerequisites..."
  apt install -y apt-transport-https ca-certificates curl gnupg

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt update
  apt install -y nvidia-container-toolkit

  log "Configuring containerd NVIDIA runtime..."
  nvidia-ctk runtime configure --runtime=containerd
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd

else
  warn "No GPU on master — installing GPU Operator to manage worker GPUs via DaemonSet..."
fi

# Always install the GPU Operator on the master (it manages worker nodes via DaemonSet)
log "Adding NVIDIA Helm repo..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
helm repo update

log "Creating gpu-operator namespace..."
$KUBECTL_PATH create namespace gpu-operator 2>/dev/null || true

log "Installing NVIDIA GPU Operator $GPU_OPERATOR_VERSION..."
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --version "$GPU_OPERATOR_VERSION" \
  --set driver.enabled=true \
  --set toolkit.enabled=true \
  --set operator.defaultRuntime=containerd \
  --wait --timeout=10m \
  | tee /root/gpu-operator-install.log

log "GPU Operator installed. Pods will spin up per node as workers join."

# -----------------------------------------------
# STEP 11: Generate Worker Join Script
# -----------------------------------------------
header "STEP 11: Generating Worker Join Token"

# Generate a new token with a long TTL (24h by default, use --ttl=0 for permanent)
JOIN_CMD=$($KUBEADM_PATH token create --print-join-command 2>/dev/null)

if [[ -z "$JOIN_CMD" ]]; then
  error "Failed to generate join command. Check kubeadm logs."
fi

# Also get the CA cert hash for reference
CA_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 -hex | sed 's/^.* //')

cat <<JOINSCRIPT > "$TOKEN_FILE"
#!/bin/bash

# =============================================================
# Kubernetes Worker Node Join Script
# Generated on: $(date)
# Master API IP: $API_IP
# Kubernetes version: $K8S_VERSION
# Pod CIDR: $POD_CIDR
# =============================================================
# Usage: sudo bash $(basename $TOKEN_FILE) [--node-name <name>]
# NOTE: Token expires in 24h. Re-run install-kube-master.sh's
#       generate-token step or use: sudo kubeadm token create --print-join-command
# =============================================================

set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

K8S_VERSION="$K8S_VERSION"
MASTER_IP="$API_IP"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "\${GREEN}[INFO]\${NC} \$1"; }
warn()   { echo -e "\${YELLOW}[WARN]\${NC} \$1"; }
error()  { echo -e "\${RED}[ERROR]\${NC} \$1"; exit 1; }
header() { echo -e "\n\${BLUE}========== \$1 ===========\${NC}\n"; }

if [[ \$EUID -ne 0 ]]; then
  error "Please run as root: sudo bash \$0"
fi

if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
  warn "Designed for Ubuntu 24.04 LTS. Proceed with caution."
fi

# -----------------------------------------------
# GPU Auto-Detection
# -----------------------------------------------
GPU_PRESENT=false
if lspci 2>/dev/null | grep -qi nvidia; then
  GPU_PRESENT=true
  log "NVIDIA GPU detected on this worker."
else
  log "No NVIDIA GPU detected on this worker."
fi

# -----------------------------------------------
# STEP 1: System Preparation
# -----------------------------------------------
header "STEP 1: System Preparation"

log "Updating system..."
apt update && apt full-upgrade -y

log "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)\$/#\1/g' /etc/fstab
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
systemctl is-active --quiet containerd && log "containerd running." || error "containerd failed."

# -----------------------------------------------
# STEP 3: Install kubeadm, kubelet, kubectl
# -----------------------------------------------
header "STEP 3: Installing Kubernetes Tools (\$K8S_VERSION)"

apt install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/\$K8S_VERSION/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/\$K8S_VERSION/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list

apt update

log "Removing conflicting containernetworking-plugins package..."
apt remove -y containernetworking-plugins 2>/dev/null || true

dpkg --configure -a || true
apt install -f -y || true

apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt install -y kubelet kubeadm kubectl --allow-change-held-packages
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet
log "Kubernetes tools installed."

# -----------------------------------------------
# STEP 4: NVIDIA Container Toolkit (if GPU present)
# -----------------------------------------------
if [[ "\$GPU_PRESENT" == "true" ]]; then
  header "STEP 4: Installing NVIDIA Container Toolkit"

  apt install -y apt-transport-https ca-certificates curl gnupg

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt update
  apt install -y nvidia-container-toolkit

  log "Configuring containerd NVIDIA runtime..."
  nvidia-ctk runtime configure --runtime=containerd
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  log "NVIDIA container toolkit installed and containerd configured."
else
  header "STEP 4: GPU Setup"
  log "No GPU — skipping NVIDIA container toolkit."
fi

# -----------------------------------------------
# STEP 5: Join the Cluster
# -----------------------------------------------
header "STEP 5: Joining Cluster (Master: \$MASTER_IP)"

log "Running kubeadm join..."
$JOIN_CMD

log "Worker node joined the cluster."

# -----------------------------------------------
# STEP 6: kubectl Autocomplete (optional convenience)
# -----------------------------------------------
header "STEP 6: kubectl Autocomplete"

for RCFILE in /root/.bashrc; do
  grep -q 'kubectl completion' "\$RCFILE" 2>/dev/null || {
    echo 'source <(kubectl completion bash)' >> "\$RCFILE"
    echo 'alias k=kubectl'                   >> "\$RCFILE"
    echo 'complete -o default -F __start_kubectl k' >> "\$RCFILE"
  }
done

if [[ -n "\$SUDO_USER" ]]; then
  USER_HOME=\$(getent passwd "\$SUDO_USER" | cut -d: -f6)
  RCFILE="\$USER_HOME/.bashrc"
  grep -q 'kubectl completion' "\$RCFILE" 2>/dev/null || {
    echo 'source <(kubectl completion bash)' >> "\$RCFILE"
    echo 'alias k=kubectl'                   >> "\$RCFILE"
    echo 'complete -o default -F __start_kubectl k' >> "\$RCFILE"
  }
fi

# -----------------------------------------------
# Done
# -----------------------------------------------
header "Worker Node Setup Complete!"
echo -e "\${GREEN}"
echo "  This worker has successfully joined the cluster."
echo "  Verify from the master with:"
echo "    kubectl get nodes -o wide"
echo ""
if [[ "\$GPU_PRESENT" == "true" ]]; then
  echo "  GPU detected — the GPU Operator DaemonSet will auto-configure this node."
  echo "  Monitor with (from master):"
  echo "    kubectl get pods -n gpu-operator -o wide"
fi
echo -e "\${NC}"
JOINSCRIPT

chmod +x "$TOKEN_FILE"
log "Worker join script saved to: $TOKEN_FILE"

# -----------------------------------------------
# STEP 12: Verify Cluster
# -----------------------------------------------
header "STEP 12: Verifying Master Node"

log "Waiting for master node to be Ready (up to 2 min)..."
for i in {1..12}; do
  STATUS=$($KUBECTL_PATH get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
  if [[ "$STATUS" == "Ready" ]]; then
    log "Master node is Ready!"
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
header "Master Setup Complete!"
echo -e "${CYAN}"
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │                 NEXT STEPS FOR WORKER NODES                     │"
echo "  ├─────────────────────────────────────────────────────────────────┤"
echo "  │  1. Copy the generated join script to each worker:              │"
echo "  │       scp $TOKEN_FILE user@worker-ip:~/                         │"
echo "  │                                                                  │"
echo "  │  2. On each worker node, run:                                    │"
echo "  │       sudo bash $(basename $TOKEN_FILE)                         │"
echo "  │                                                                  │"
echo "  │  3. Verify from this master:                                     │"
echo "  │       kubectl get nodes -o wide                                  │"
echo "  ├─────────────────────────────────────────────────────────────────┤"
echo "  │  Token expires in 24h. To generate a new one:                   │"
echo "  │       kubeadm token create --print-join-command                 │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo -e "${NC}"
echo ""
echo -e "${GREEN}  GPU Operator status:${NC}"
echo "    kubectl get pods -n gpu-operator -o wide"
echo ""
echo -e "${GREEN}  Cluster status:${NC}"
echo "    kubectl get nodes -o wide"
echo "    kubectl get pods -A"