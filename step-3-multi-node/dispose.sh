#!/bin/bash

# =============================================================
# Kubernetes Multi-Node Complete Uninstall / Reset Script
# Ubuntu 24.04 LTS
# Usage:
#   MASTER:  sudo bash dispose-kube-multi.sh master
#   WORKER:  sudo bash dispose-kube-multi.sh worker
#
# Includes: GPU Operator, NVIDIA container toolkit, Helm cleanup
# Run on each node independently.
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
header() { echo -e "\n${BLUE}========== $1 ==========${NC}\n"; }

# -----------------------------------------------
# Argument Parsing
# -----------------------------------------------
ROLE="${1:-}"

if [[ "$ROLE" != "master" && "$ROLE" != "worker" ]]; then
  echo ""
  echo -e "${CYAN}Kubernetes Multi-Node Dispose Script${NC}"
  echo ""
  echo "  Usage:"
  echo "    Master node:  sudo bash $0 master"
  echo "    Worker node:  sudo bash $0 worker"
  echo ""
  echo "  Run on WORKERS first, then run on the MASTER."
  echo "  (Or run independently on any node to fully clean it.)"
  echo ""
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0 $ROLE"
  exit 1
fi

log "Cleaning up node as: $ROLE"

# -----------------------------------------------
# STEP 1: Drain node from cluster (master only)
# -----------------------------------------------
header "STEP 1: Pre-cleanup (Cluster-level)"

if [[ "$ROLE" == "master" ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf

  if [[ -f /etc/kubernetes/admin.conf ]] && command -v kubectl &>/dev/null; then
    log "Attempting to cordon and drain all nodes before teardown..."

    # Get all non-master nodes and drain them
    WORKER_NODES=$(kubectl get nodes --no-headers 2>/dev/null | \
      grep -v "control-plane\|master" | awk '{print $1}' || true)

    if [[ -n "$WORKER_NODES" ]]; then
      for NODE in $WORKER_NODES; do
        log "Draining worker node: $NODE"
        kubectl drain "$NODE" \
          --ignore-daemonsets \
          --delete-emptydir-data \
          --force \
          --timeout=60s 2>/dev/null || warn "Could not fully drain $NODE (may already be unreachable)."
        kubectl delete node "$NODE" 2>/dev/null || true
        log "Removed node $NODE from cluster."
      done
    else
      log "No worker nodes found to drain."
    fi
  else
    log "kubectl or admin.conf not available — skipping cluster drain."
  fi

elif [[ "$ROLE" == "worker" ]]; then
  log "Worker node: no cluster-level drain needed here."
  log "Tip: drain this node from the master BEFORE running this script for a clean removal:"
  log "  kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --force"
  log "  kubectl delete node <node-name>"
  echo ""
fi

# -----------------------------------------------
# STEP 2: Reset kubeadm
# -----------------------------------------------
header "STEP 2: Reset kubeadm"

if command -v kubeadm &>/dev/null; then
  log "Running kubeadm reset..."
  kubeadm reset -f || true
else
  log "kubeadm not found, skipping."
fi

# -----------------------------------------------
# STEP 3: Stop all Kubernetes services
# -----------------------------------------------
header "STEP 3: Stopping Services"

for SVC in kubelet containerd; do
  systemctl stop    $SVC 2>/dev/null && log "Stopped $SVC."   || true
  systemctl disable $SVC 2>/dev/null && log "Disabled $SVC."  || true
done

# -----------------------------------------------
# STEP 4: Remove GPU Operator via Helm (master only)
# -----------------------------------------------
header "STEP 4: Removing NVIDIA GPU Operator"

if [[ "$ROLE" == "master" ]]; then
  if command -v helm &>/dev/null; then
    export KUBECONFIG=/etc/kubernetes/admin.conf

    # Delete GPU test pod if it exists
    if kubectl get pod gpu-test -n default &>/dev/null 2>&1; then
      log "Deleting GPU test pod..."
      kubectl delete pod gpu-test -n default --force --grace-period=0 2>/dev/null || true
      log "GPU test pod deleted."
    else
      log "No gpu-test pod found, skipping."
    fi

    rm -f /root/gpu-test-pod.yaml && log "Removed gpu-test-pod.yaml" || true

    # Uninstall GPU Operator Helm release
    if helm status gpu-operator -n gpu-operator &>/dev/null 2>&1; then
      log "Uninstalling GPU Operator Helm release..."
      helm uninstall gpu-operator -n gpu-operator --wait --timeout=3m 2>/dev/null || true
      log "GPU Operator Helm release removed."
    else
      log "GPU Operator Helm release not found, skipping."
    fi

    # Delete the gpu-operator namespace
    if kubectl get namespace gpu-operator &>/dev/null 2>&1; then
      log "Deleting gpu-operator namespace..."
      kubectl delete namespace gpu-operator --force --grace-period=0 2>/dev/null || true
      log "gpu-operator namespace deleted."
    else
      log "gpu-operator namespace not found, skipping."
    fi

    # Remove GPU Operator CRDs
    log "Removing GPU Operator CRDs..."
    kubectl get crd 2>/dev/null | grep -i 'nvidia\|nfd\|gpu' | awk '{print $1}' | \
      xargs kubectl delete crd --force --grace-period=0 2>/dev/null || true
    log "GPU Operator CRDs removed."

    # Remove NVIDIA Helm repo
    if helm repo list 2>/dev/null | grep -q nvidia; then
      helm repo remove nvidia 2>/dev/null || true
      log "NVIDIA Helm repo removed."
    fi
  else
    log "Helm not found — skipping Helm-based GPU Operator removal."
  fi
else
  log "Worker node: GPU Operator is managed by master. Skipping Helm removal."
  log "(Run dispose master to remove the GPU Operator from the cluster.)"
fi

# -----------------------------------------------
# STEP 5: Remove Helm (master only)
# -----------------------------------------------
header "STEP 5: Removing Helm"

if [[ "$ROLE" == "master" ]]; then
  if [[ -f /usr/local/bin/helm ]]; then
    rm -f /usr/local/bin/helm
    log "Helm binary removed."
  else
    log "Helm not found at /usr/local/bin/helm, skipping."
  fi

  rm -rf /root/.cache/helm /root/.config/helm /root/.local/share/helm

  if [[ -n "$SUDO_USER" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    rm -rf "$USER_HOME/.cache/helm" "$USER_HOME/.config/helm" "$USER_HOME/.local/share/helm"
  fi

  log "Helm fully removed."
else
  log "Worker node: Helm not installed on workers — skipping."
fi

# -----------------------------------------------
# STEP 6: Remove NVIDIA Container Toolkit
# -----------------------------------------------
header "STEP 6: Removing NVIDIA Container Toolkit"

apt remove -y --purge \
  nvidia-container-toolkit \
  nvidia-container-toolkit-base \
  libnvidia-container-tools \
  libnvidia-container1 \
  2>/dev/null || true

rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

apt autoremove -y --purge 2>/dev/null || true
log "NVIDIA container toolkit removed."

# -----------------------------------------------
# STEP 7: Remove all Kubernetes packages
# -----------------------------------------------
header "STEP 7: Removing Kubernetes Packages"

apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true

apt remove -y --purge \
  kubelet \
  kubeadm \
  kubectl \
  kubernetes-cni \
  containernetworking-plugins \
  containerd \
  runc \
  2>/dev/null || true

apt autoremove -y --purge 2>/dev/null || true
apt clean

log "Packages removed."

# -----------------------------------------------
# STEP 8: Remove all config and data directories
# -----------------------------------------------
header "STEP 8: Removing Directories & Files"

DIRS=(
  /etc/kubernetes
  /var/lib/kubelet
  /var/lib/etcd
  /var/lib/containerd
  /var/run/kubernetes
  /etc/containerd
  /opt/cni
  /etc/cni
  /var/lib/cni
  /run/flannel
  /etc/flannel
  /var/log/pods
  /var/log/containers
  /root/.kube
  /home/*/.kube
)

for DIR in "${DIRS[@]}"; do
  if ls $DIR 2>/dev/null; then
    rm -rf $DIR
    log "Removed: $DIR"
  fi
done

# Remove join info file on master, join log on worker
if [[ "$ROLE" == "master" ]]; then
  rm -f /root/kubeadm-init.log
  rm -f /root/kubeadm-worker-join-info.txt
  rm -f /root/k8s-worker-join-info.txt
  rm -f /root/gpu-operator-install.log
  log "Removed master setup logs."
else
  rm -f /root/kubeadm-join.log
  log "Removed worker join log."
fi

# -----------------------------------------------
# STEP 9: Remove Kubernetes apt repo and keys
# -----------------------------------------------
header "STEP 9: Removing Kubernetes Apt Repo"

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
apt update -y

log "Kubernetes apt repo removed."

# -----------------------------------------------
# STEP 10: Remove sysctl and module config
# -----------------------------------------------
header "STEP 10: Removing sysctl & Module Config"

rm -f /etc/sysctl.d/k8s.conf
rm -f /etc/modules-load.d/k8s.conf
sysctl --system > /dev/null 2>&1

log "sysctl and module config removed."

# -----------------------------------------------
# STEP 11: Flush iptables rules
# -----------------------------------------------
header "STEP 11: Flushing iptables Rules"

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

ip6tables -F
ip6tables -X
ip6tables -t nat -F    2>/dev/null || true
ip6tables -t nat -X    2>/dev/null || true
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -t mangle -X 2>/dev/null || true
ip6tables -P INPUT ACCEPT
ip6tables -P FORWARD ACCEPT
ip6tables -P OUTPUT ACCEPT

log "iptables flushed."

# -----------------------------------------------
# STEP 12: Remove virtual network interfaces
# -----------------------------------------------
header "STEP 12: Removing Virtual Network Interfaces"

for IFACE in flannel.1 cni0 docker0 tunl0; do
  if ip link show $IFACE &>/dev/null; then
    ip link set $IFACE down
    ip link delete $IFACE
    log "Removed interface: $IFACE"
  fi
done

# -----------------------------------------------
# STEP 13: Re-enable swap
# -----------------------------------------------
header "STEP 13: Re-enabling Swap"

systemctl unmask swap.target 2>/dev/null || true
sed -i 's/^#\(.*swap.*\)/\1/' /etc/fstab
swapon -a 2>/dev/null || true
log "Swap re-enabled."

# -----------------------------------------------
# STEP 14: Remove kubectl autocomplete from bashrc
# -----------------------------------------------
header "STEP 14: Cleaning .bashrc"

for RCFILE in /root/.bashrc /home/*/.bashrc; do
  if [[ -f "$RCFILE" ]]; then
    sed -i '/kubectl completion/d' "$RCFILE"
    sed -i '/alias k=kubectl/d' "$RCFILE"
    sed -i '/complete.*kubectl/d' "$RCFILE"
    log "Cleaned: $RCFILE"
  fi
done

# -----------------------------------------------
# Done
# -----------------------------------------------
header "Cleanup Complete — $ROLE node"

echo -e "${GREEN}"
echo "  Everything removed from this $ROLE node:"
echo "    - kubeadm / kubelet / kubectl"
echo "    - containerd / runc"
echo "    - kubernetes-cni / containernetworking-plugins"
echo "    - All config dirs (/etc/kubernetes, /var/lib/etcd, etc.)"
echo "    - Kubernetes apt repo and GPG key"
echo "    - iptables rules flushed"
echo "    - Virtual network interfaces removed"
echo "    - Swap re-enabled"
echo "    - NVIDIA container toolkit + apt repo"
if [[ "$ROLE" == "master" ]]; then
echo "    - NVIDIA GPU Operator (Helm release + namespace + CRDs)"
echo "    - Helm binary + cache"
echo "    - GPU test pod"
fi
echo ""

if [[ "$ROLE" == "master" ]]; then
  echo "  Master is fully clean. You can re-run: sudo bash install-kube-multi.sh master"
else
  echo "  Worker is fully clean."
  echo "  Remember to also delete it from the master (if not done yet):"
  echo "    kubectl delete node <this-hostname>"
  echo ""
  echo "  To re-join: sudo bash install-kube-multi.sh worker <MASTER_IP> <TOKEN> <HASH>"
fi

echo -e "${NC}"