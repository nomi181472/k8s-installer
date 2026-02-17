#!/bin/bash

# =============================================================
# Kubernetes Complete Uninstall / Reset Script
# Ubuntu 24.04 LTS
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
# STEP 3: Remove all packages
# -----------------------------------------------
header "STEP 3: Removing Packages"

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
# STEP 4: Remove all config and data directories
# -----------------------------------------------
header "STEP 4: Removing Directories & Files"

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
# STEP 5: Remove repo and keys
# -----------------------------------------------
header "STEP 5: Removing Kubernetes Apt Repo"

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
apt update -y

log "Kubernetes apt repo removed."

# -----------------------------------------------
# STEP 6: Remove sysctl and module config
# -----------------------------------------------
header "STEP 6: Removing sysctl & Module Config"

rm -f /etc/sysctl.d/k8s.conf
rm -f /etc/modules-load.d/k8s.conf
sysctl --system > /dev/null 2>&1

log "sysctl and module config removed."

# -----------------------------------------------
# STEP 7: Flush iptables rules
# -----------------------------------------------
header "STEP 7: Flushing iptables Rules"

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
# STEP 8: Remove virtual network interfaces
# -----------------------------------------------
header "STEP 8: Removing Virtual Network Interfaces"

for IFACE in flannel.1 cni0 docker0 tunl0; do
  if ip link show $IFACE &>/dev/null; then
    ip link set $IFACE down
    ip link delete $IFACE
    log "Removed interface: $IFACE"
  fi
done

# -----------------------------------------------
# STEP 9: Re-enable swap (optional)
# -----------------------------------------------
header "STEP 9: Re-enabling Swap"

systemctl unmask swap.target 2>/dev/null || true
sed -i 's/^#\(.*swap.*\)/\1/' /etc/fstab
swapon -a 2>/dev/null || true
log "Swap re-enabled."

# -----------------------------------------------
# STEP 10: Remove kubectl autocomplete from bashrc
# -----------------------------------------------
header "STEP 10: Cleaning .bashrc"

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
echo ""
echo "  System is clean. You can start fresh."
echo -e "${NC}"