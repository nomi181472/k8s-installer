#!/bin/bash

# =============================================================
# Kubernetes Multi-Node Setup Script for Ubuntu 24.04 LTS
# Usage:
#   MASTER:  sudo bash install-kube-multi.sh master
#   WORKER:  sudo bash install-kube-multi.sh worker <MASTER_IP> <TOKEN> <DISCOVERY_HASH>
#
#   After running master, it prints the exact worker join command.
#   Copy-paste and run it on each worker node.
#
# GPU: Auto-detected per node. GPU Operator installed on master.
#      Worker GPU nodes will be recognized automatically.
# =============================================================

set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

K8S_VERSION="v1.35"
POD_CIDR="10.244.0.0/16"
HELM_VERSION="v3.16.4"
GPU_OPERATOR_VERSION="v25.3.0"

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header() { echo -e "\n${BLUE}========== $1 ==========${NC}\n"; }
box()    { echo -e "\n${CYAN}$1${NC}\n"; }

# -----------------------------------------------
# Argument Parsing
# -----------------------------------------------
ROLE="${1:-}"

if [[ "$ROLE" == "worker" ]]; then
  MASTER_IP="${2:-}"
  JOIN_TOKEN="${3:-}"
  DISCOVERY_HASH="${4:-}"

  [[ -z "$MASTER_IP" ]]       && error "Usage: sudo bash $0 worker <MASTER_IP> <TOKEN> <DISCOVERY_HASH>"
  [[ -z "$JOIN_TOKEN" ]]      && error "Usage: sudo bash $0 worker <MASTER_IP> <TOKEN> <DISCOVERY_HASH>"
  [[ -z "$DISCOVERY_HASH" ]]  && error "Usage: sudo bash $0 worker <MASTER_IP> <TOKEN> <DISCOVERY_HASH>"

elif [[ "$ROLE" == "master" ]]; then
  : # no extra args required

else
  echo ""
  echo -e "${CYAN}Kubernetes Multi-Node Setup Script${NC}"
  echo ""
  echo "  Usage:"
  echo "    Master node:  sudo bash $0 master"
  echo "    Worker node:  sudo bash $0 worker <MASTER_IP> <TOKEN> <DISCOVERY_HASH>"
  echo ""
  echo "  Run the master first — it will print the exact worker join command."
  echo ""
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  error "Please run as root: sudo bash $0 $*"
fi

if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
  warn "Designed for Ubuntu 24.04 LTS. Proceed with caution on other versions."
fi

# Detect NVIDIA GPU
GPU_PRESENT=false
if lspci 2>/dev/null | grep -qi nvidia; then
  GPU_PRESENT=true
  log "NVIDIA GPU detected on this node."
else
  log "No NVIDIA GPU detected on this node."
fi

# =============================================================
# SHARED STEPS (run on both master and worker)
# =============================================================

shared_system_prep() {
  header "System Preparation"

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
}

shared_install_containerd() {
  header "Installing containerd"

  apt install -y containerd
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl restart containerd
  systemctl enable containerd
  systemctl is-active --quiet containerd && log "containerd is running." || error "containerd failed to start."
}

shared_install_kube_tools() {
  header "Installing Kubernetes Tools (kubeadm, kubelet, kubectl)"

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

  log "Removing conflicting containernetworking-plugins package..."
  apt remove -y containernetworking-plugins 2>/dev/null || true

  log "Fixing any broken packages..."
  dpkg --configure -a || true
  apt install -f -y || true

  log "Unholding kubernetes packages if previously held..."
  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true

  log "Installing kubelet kubeadm kubectl..."
  apt install -y kubelet kubeadm kubectl --allow-change-held-packages

  log "Holding kubernetes packages at current version..."
  apt-mark hold kubelet kubeadm kubectl

  systemctl enable kubelet

  KUBEADM_PATH=$(which kubeadm 2>/dev/null || echo "/usr/bin/kubeadm")
  [[ ! -f "$KUBEADM_PATH" ]] && error "kubeadm not found after install!"
  log "kubeadm version: $($KUBEADM_PATH version -o short)"
}

shared_nvidia_container_toolkit() {
  if [[ "$GPU_PRESENT" == "true" ]]; then
    header "Installing NVIDIA Container Toolkit"

    apt install -y apt-transport-https ca-certificates curl gnupg

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
      gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt update
    apt install -y nvidia-container-toolkit
    log "NVIDIA container toolkit installed."

    log "Configuring containerd NVIDIA runtime..."
    nvidia-ctk runtime configure --runtime=containerd
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl restart containerd
    log "containerd restarted with NVIDIA runtime."
  else
    log "No GPU detected — skipping NVIDIA container toolkit."
  fi
}

# =============================================================
# MASTER SETUP
# =============================================================

setup_master() {
  header "MASTER NODE SETUP"

  shared_system_prep
  shared_install_containerd
  shared_install_kube_tools

  # -----------------------------------------------
  # Init Cluster
  # -----------------------------------------------
  header "Initializing Kubernetes Cluster"

  KUBEADM_PATH=$(which kubeadm)
  KUBECTL_PATH=$(which kubectl)

  log "Resetting any previous kubeadm state..."
  $KUBEADM_PATH reset -f 2>/dev/null || true
  rm -rf /etc/kubernetes /var/lib/etcd

  NODE_IP=$(hostname -I | awk '{print $1}')
  log "Master node IP: $NODE_IP"

  log "Running kubeadm init..."
  $KUBEADM_PATH init \
    --pod-network-cidr=$POD_CIDR \
    --apiserver-advertise-address=$NODE_IP \
    | tee /root/kubeadm-init.log

  [[ ! -f /etc/kubernetes/admin.conf ]] && \
    error "Init failed — admin.conf not found. Check /root/kubeadm-init.log"

  log "Cluster initialized successfully."

  # -----------------------------------------------
  # Configure kubectl
  # -----------------------------------------------
  header "Configuring kubectl"

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

  # -----------------------------------------------
  # Install Flannel CNI
  # -----------------------------------------------
  header "Installing Flannel CNI"

  $KUBECTL_PATH apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
  log "Flannel applied. Waiting 30s for CNI to initialize..."
  sleep 30

  # -----------------------------------------------
  # kubectl Autocomplete
  # -----------------------------------------------
  header "kubectl Autocomplete"

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
  # Install Helm
  # -----------------------------------------------
  header "Installing Helm $HELM_VERSION"

  if command -v helm &>/dev/null; then
    log "Helm already installed: $(helm version --short)"
  else
    log "Downloading Helm $HELM_VERSION..."
    curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz -o /tmp/helm.tar.gz
    tar -zxf /tmp/helm.tar.gz -C /tmp
    mv /tmp/linux-amd64/helm /usr/local/bin/helm
    chmod +x /usr/local/bin/helm
    rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
    log "Helm installed: $(helm version --short)"
  fi

  # -----------------------------------------------
  # NVIDIA Container Toolkit (if GPU present on master)
  # -----------------------------------------------
  shared_nvidia_container_toolkit

  # -----------------------------------------------
  # GPU Operator via Helm (installed on master, manages all GPU nodes)
  # -----------------------------------------------
  header "NVIDIA GPU Operator"

  if [[ "$GPU_PRESENT" == "true" ]]; then
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

    sleep 15
    GPU_COUNT=$($KUBECTL_PATH get node \
      -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
    if [[ -n "$GPU_COUNT" && "$GPU_COUNT" != "0" ]]; then
      log "GPUs available on master node: $GPU_COUNT"
    else
      warn "GPU resource not yet advertised on master. Worker GPU nodes will register when they join."
    fi

    # GPU test pod
    header "Running GPU Test Pod"
    log "Deploying GPU test pod..."
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
  runtimeClassName: nvidia
  containers:
    - name: gpu-test
      image: nvidia/cuda:12.4.0-runtime-ubuntu22.04
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
    sleep 15

    POD_STATUS=$($KUBECTL_PATH get pod gpu-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    log "GPU test pod status: $POD_STATUS"

    echo ""
    echo -e "${BLUE}--- GPU Test Pod Logs ---${NC}"
    $KUBECTL_PATH logs gpu-test 2>/dev/null || warn "Logs not available yet. Run: kubectl logs gpu-test"
    echo -e "${BLUE}-------------------------${NC}"
    echo ""
  else
    warn "No NVIDIA GPU on master — skipping GPU Operator install."
    warn "If ANY worker nodes have GPUs, re-run master setup with a GPU-equipped master,"
    warn "or manually install GPU Operator after joining workers:"
    warn "  helm install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace"
  fi

  # -----------------------------------------------
  # Generate join info for workers
  # -----------------------------------------------
  header "Worker Node Join Information"

  # Generate a new token and capture join info cleanly
  JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)

  # Parse out the parts
  W_TOKEN=$(echo "$JOIN_CMD" | grep -oP '(?<=--token )\S+')
  W_HASH=$(echo "$JOIN_CMD" | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')
  W_MASTER_IP="$NODE_IP"

  # Save join info to file for reference
  cat <<EOF > /root/k8s-worker-join-info.txt
Master IP  : $W_MASTER_IP
Token      : $W_TOKEN
Hash       : $W_HASH

Worker join command:
  sudo bash install-kube-multi.sh worker $W_MASTER_IP $W_TOKEN $W_HASH

Token expires in 24 hours. To create a new one:
  kubeadm token create --print-join-command
EOF

  log "Join info saved to /root/k8s-worker-join-info.txt"

  # -----------------------------------------------
  # Verify
  # -----------------------------------------------
  header "Verifying Master Installation"

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

  if [[ "$GPU_PRESENT" == "true" ]]; then
    echo ""
    log "GPU Operator pods:"
    $KUBECTL_PATH get pods -n gpu-operator -o wide 2>/dev/null || true
  fi

  # -----------------------------------------------
  # Print final banner with worker join command
  # -----------------------------------------------
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║           MASTER SETUP COMPLETE — RUN ON EACH WORKER            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${YELLOW}Copy this command and run it on each worker node:${NC}"
  echo ""
  echo -e "  ${GREEN}sudo bash install-kube-multi.sh worker $W_MASTER_IP $W_TOKEN $W_HASH${NC}"
  echo ""
  echo -e "  ${YELLOW}Join info also saved to:${NC} /root/k8s-worker-join-info.txt"
  echo ""
  echo -e "  ${YELLOW}Token expires in 24h. To regenerate:${NC}"
  echo -e "    kubeadm token create --print-join-command"
  echo ""
}

# =============================================================
# WORKER SETUP
# =============================================================

setup_worker() {
  header "WORKER NODE SETUP"
  log "Master IP      : $MASTER_IP"
  log "Join Token     : $JOIN_TOKEN"
  log "Discovery Hash : $DISCOVERY_HASH"

  shared_system_prep
  shared_install_containerd
  shared_install_kube_tools
  shared_nvidia_container_toolkit

  # -----------------------------------------------
  # Join the cluster
  # -----------------------------------------------
  header "Joining Kubernetes Cluster"

  KUBEADM_PATH=$(which kubeadm)
  KUBECTL_PATH=$(which kubectl)

  log "Resetting any previous kubeadm state..."
  $KUBEADM_PATH reset -f 2>/dev/null || true

  log "Running kubeadm join..."
  $KUBEADM_PATH join "${MASTER_IP}:6443" \
    --token "$JOIN_TOKEN" \
    --discovery-token-ca-cert-hash "$DISCOVERY_HASH" \
    | tee /root/kubeadm-join.log

  # -----------------------------------------------
  # Verify worker joined (worker can't run kubectl without kubeconfig)
  # -----------------------------------------------
  header "Verifying Worker Join"

  log "Checking join log for success indicator..."
  if grep -q "This node has joined the cluster" /root/kubeadm-join.log 2>/dev/null; then
    log "Worker successfully joined the cluster!"
  else
    warn "Join log does not confirm success. Check /root/kubeadm-join.log"
    cat /root/kubeadm-join.log
  fi

  log "kubelet service status:"
  systemctl is-active kubelet && log "kubelet is running." || warn "kubelet may not be running. Check: systemctl status kubelet"

  if [[ "$GPU_PRESENT" == "true" ]]; then
    echo ""
    log "GPU detected on this worker. The GPU Operator on the master will automatically"
    log "detect and configure this node. To verify from master:"
    echo "  kubectl get nodes"
    echo "  kubectl describe node $(hostname) | grep nvidia"
    echo "  kubectl get pods -n gpu-operator -o wide"
  fi

  # -----------------------------------------------
  # Final banner
  # -----------------------------------------------
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                    WORKER SETUP COMPLETE                         ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${YELLOW}To verify from the master node:${NC}"
  echo ""
  echo -e "  ${GREEN}kubectl get nodes -o wide${NC}"
  echo -e "  ${GREEN}kubectl get pods -A${NC}"
  echo ""

  if [[ "$GPU_PRESENT" == "true" ]]; then
    echo -e "  ${YELLOW}GPU verification from master:${NC}"
    echo -e "  ${GREEN}kubectl describe node $(hostname) | grep -i nvidia${NC}"
    echo -e "  ${GREEN}kubectl get pods -n gpu-operator -o wide${NC}"
    echo ""
  fi

  echo -e "  ${YELLOW}Join log saved to:${NC} /root/kubeadm-join.log"
  echo ""
}

# =============================================================
# ENTRYPOINT
# =============================================================

case "$ROLE" in
  master) setup_master ;;
  worker) setup_worker ;;
esac