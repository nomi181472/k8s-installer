#!/bin/bash

# =============================================================
# Kubernetes Complete Uninstall / Reset Script
# Ubuntu 24.04 LTS
# Includes: GPU Operator, NVIDIA container toolkit, Helm cleanup
# =============================================================

set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
header() { echo -e "\n${BLUE}========== $1 ==========${NC}\n"; }

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

# -----------------------------------------------
# STEP 1: Reset kubeadm
# -----------------------------------------------
header "STEP 1: Reset kubeadm"

if command -v kubeadm &>/dev/null; then
  log "Running kubeadm reset..."
  kubeadm reset -f || true
else
  log "kubeadm not found, skipping."
fi

# -----------------------------------------------
# STEP 2: Stop all Kubernetes services
# -----------------------------------------------
header "STEP 2: Stopping Services"

for SVC in kubelet containerd; do
  systemctl stop $SVC 2>/dev/null    && log "Stopped $SVC."    || true
  systemctl disable $SVC 2>/dev/null && log "Disabled $SVC."   || true
done

# -----------------------------------------------
# STEP 3: Remove GPU Operator via Helm
# -----------------------------------------------
header "STEP 3: Removing NVIDIA GPU Operator"

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

  # Uninstall GPU Operator Helm release
  if helm status gpu-operator -n gpu-operator &>/dev/null 2>&1; then
    log "Uninstalling GPU Operator Helm release..."
    helm uninstall gpu-operator -n gpu-operator --wait --timeout=3m 2>/dev/null || true
    log "GPU Operator Helm release removed."
  else
    log "GPU Operator Helm release not found, skipping."
  fi

  # Delete the gpu-operator namespace (removes all CRDs, pods, etc.)
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

# -----------------------------------------------
# STEP 4: Remove Helm
# -----------------------------------------------
header "STEP 4: Removing Helm"

if [[ -f /usr/local/bin/helm ]]; then
  rm -f /usr/local/bin/helm
  log "Helm binary removed."
else
  log "Helm not found at /usr/local/bin/helm, skipping."
fi

# Clean up Helm cache and config
rm -rf /root/.cache/helm
rm -rf /root/.config/helm
rm -rf /root/.local/share/helm

if [[ -n "$SUDO_USER" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  rm -rf "$USER_HOME/.cache/helm"
  rm -rf "$USER_HOME/.config/helm"
  rm -rf "$USER_HOME/.local/share/helm"
fi

log "Helm fully removed."

# -----------------------------------------------
# STEP 5: Remove NVIDIA Container Toolkit
# -----------------------------------------------
header "STEP 5: Removing NVIDIA Container Toolkit"

apt remove -y --purge \
  nvidia-container-toolkit \
  nvidia-container-toolkit-base \
  libnvidia-container-tools \
  libnvidia-container1 \
  2>/dev/null || true

# Remove NVIDIA container toolkit apt repo and key
rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

apt autoremove -y --purge 2>/dev/null || true
log "NVIDIA container toolkit removed."

# -----------------------------------------------
# STEP 6: Remove all Kubernetes packages
# -----------------------------------------------
header "STEP 6: Removing Kubernetes Packages"

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
# STEP 7: Remove all config and data directories
# -----------------------------------------------
header "STEP 7: Removing Directories & Files"

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

# -----------------------------------------------
# STEP 8: Remove repo and keys
# -----------------------------------------------
header "STEP 8: Removing Kubernetes Apt Repo"

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
apt update -y

log "Kubernetes apt repo removed."

# -----------------------------------------------
# STEP 9: Remove sysctl and module config
# -----------------------------------------------
header "STEP 9: Removing sysctl & Module Config"

rm -f /etc/sysctl.d/k8s.conf
rm -f /etc/modules-load.d/k8s.conf
sysctl --system > /dev/null 2>&1

log "sysctl and module config removed."

# -----------------------------------------------
# STEP 10: Flush iptables rules
# -----------------------------------------------
header "STEP 10: Flushing iptables Rules"

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
# STEP 11: Remove virtual network interfaces
# -----------------------------------------------
header "STEP 11: Removing Virtual Network Interfaces"

for IFACE in flannel.1 cni0 docker0 tunl0; do
  if ip link show $IFACE &>/dev/null; then
    ip link set $IFACE down
    ip link delete $IFACE
    log "Removed interface: $IFACE"
  fi
done

# -----------------------------------------------
# STEP 12: Re-enable swap (optional)
# -----------------------------------------------
header "STEP 12: Re-enabling Swap"

systemctl unmask swap.target 2>/dev/null || true
sed -i 's/^#\(.*swap.*\)/\1/' /etc/fstab
swapon -a 2>/dev/null || true
log "Swap re-enabled."

# -----------------------------------------------
# STEP 13: Remove kubectl autocomplete from bashrc
# -----------------------------------------------
header "STEP 13: Cleaning .bashrc"

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
header "Cleanup Complete!"

echo -e "${GREEN}"
echo "  Everything has been removed:"
echo "    - kubeadm / kubelet / kubectl"
echo "    - containerd / runc"
echo "    - kubernetes-cni / containernetworking-plugins"
echo "    - All config dirs (/etc/kubernetes, /var/lib/etcd, etc.)"
echo "    - Kubernetes apt repo and GPG key"
echo "    - iptables rules"
echo "    - Virtual network interfaces"
echo "    - Swap re-enabled"
echo "    - NVIDIA GPU Operator (Helm release + namespace + CRDs)"
echo "    - NVIDIA container toolkit + apt repo"
echo "    - Helm binary + cache"
echo "    - GPU test pod (gpu-test)"
echo ""
echo "  System is clean. You can start fresh."
echo -e "${NC}"