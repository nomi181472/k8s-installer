#!/bin/bash

# =============================================================
# Kubernetes Multi-Node Uninstall / Reset Script
# Ubuntu 24.04 LTS
# Run on MASTER to clean the full cluster, or on a WORKER
# to drain + remove it from the cluster then reset itself.
#
# Usage:
#   Master teardown (full cluster wipe):
#     sudo bash dispose-kube.sh --role master
#
#   Worker teardown (remove self from cluster, then reset):
#     sudo bash dispose-kube.sh --role worker --master-ip <MASTER_IP>
#
#   Worker teardown from MASTER side (drain + delete node):
#     sudo bash dispose-kube.sh --role master --drain-node <NODE_NAME>
#
# Options:
#   --role <master|worker>    Required. Node role.
#   --master-ip <IP>          Master IP (required for --role worker).
#   --drain-node <name>       Drain + delete a specific worker from master.
#   --force                   Skip confirmation prompts.
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
ROLE=""
MASTER_IP=""
DRAIN_NODE=""
FORCE=false

# -----------------------------------------------
# Parse arguments
# -----------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)       ROLE="$2";       shift 2 ;;
    --master-ip)  MASTER_IP="$2";  shift 2 ;;
    --drain-node) DRAIN_NODE="$2"; shift 2 ;;
    --force)      FORCE=true;      shift ;;
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

# -----------------------------------------------
# Validate args
# -----------------------------------------------
if [[ -z "$ROLE" ]]; then
  error "Must specify --role master or --role worker"
fi

if [[ "$ROLE" == "worker" && -z "$MASTER_IP" ]]; then
  error "Worker teardown requires --master-ip <IP>"
fi

# -----------------------------------------------
# Confirmation prompt
# -----------------------------------------------
if [[ "$FORCE" != "true" ]]; then
  echo -e "${RED}"
  if [[ -n "$DRAIN_NODE" ]]; then
    echo "  ⚠  This will DRAIN and DELETE node '$DRAIN_NODE' from the cluster."
  elif [[ "$ROLE" == "master" ]]; then
    echo "  ⚠  This will DESTROY the entire Kubernetes cluster on this master."
    echo "     All worker nodes will become orphaned and must be reset separately."
  else
    echo "  ⚠  This will remove this WORKER node from the cluster (${MASTER_IP})"
    echo "     and wipe all Kubernetes components from this machine."
  fi
  echo -e "${NC}"
  read -r -p "  Type 'yes' to continue: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { log "Aborted."; exit 0; }
fi

# =============================================================
# MASTER-SIDE: Drain + delete a specific worker node only
# =============================================================
if [[ -n "$DRAIN_NODE" ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
  KUBECTL_PATH=$(which kubectl 2>/dev/null || echo "/usr/bin/kubectl")

  header "Draining Worker Node: $DRAIN_NODE"

  log "Cordon node (no new scheduling)..."
  $KUBECTL_PATH cordon "$DRAIN_NODE" 2>/dev/null || warn "Could not cordon node."

  log "Draining node (evicting all pods)..."
  $KUBECTL_PATH drain "$DRAIN_NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --grace-period=30 \
    --timeout=120s 2>/dev/null || warn "Drain encountered issues (may be OK for offline node)."

  log "Deleting node from cluster..."
  $KUBECTL_PATH delete node "$DRAIN_NODE" --force 2>/dev/null || warn "Node may already be gone."

  echo ""
  log "Node '$DRAIN_NODE' removed from cluster."
  log "Now go run 'sudo bash dispose-kube.sh --role worker --master-ip <IP>' on that machine to wipe it."
  echo ""
  $KUBECTL_PATH get nodes -o wide
  exit 0
fi

# =============================================================
# WORKER teardown (run on the worker machine itself)
# =============================================================
if [[ "$ROLE" == "worker" ]]; then

  THIS_NODE=$(hostname)

  header "Worker Node Teardown: $THIS_NODE"
  log "Master IP: $MASTER_IP"

  # -----------------------------------------------
  # STEP 1: Notify master to drain + delete this node
  # (requires kubectl + kubeconfig from master, or SSH)
  # -----------------------------------------------
  header "STEP 1: Notifying Master to Remove This Node"

  if command -v kubectl &>/dev/null && [[ -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
    warn "This worker has a local kubeconfig — attempting self-drain (unusual, continuing anyway)."
    kubectl drain "$THIS_NODE" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 2>/dev/null || true
    kubectl delete node "$THIS_NODE" --force 2>/dev/null || true
  else
    warn "No local kubeconfig on worker. Manual step required from master:"
    warn "  sudo bash dispose-kube.sh --role master --drain-node $THIS_NODE"
    warn "Continuing with local cleanup regardless..."
  fi

  # -----------------------------------------------
  # STEP 2: Reset kubeadm
  # -----------------------------------------------
  header "STEP 2: kubeadm Reset"

  if command -v kubeadm &>/dev/null; then
    log "Running kubeadm reset..."
    kubeadm reset -f || true
  else
    log "kubeadm not found, skipping."
  fi

  # -----------------------------------------------
  # STEP 3: Stop services
  # -----------------------------------------------
  header "STEP 3: Stopping Services"

  for SVC in kubelet containerd; do
    systemctl stop $SVC 2>/dev/null    && log "Stopped $SVC."   || true
    systemctl disable $SVC 2>/dev/null && log "Disabled $SVC."  || true
  done

  # -----------------------------------------------
  # STEP 4: Remove NVIDIA container toolkit (if present)
  # -----------------------------------------------
  header "STEP 4: Removing NVIDIA Container Toolkit"

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
  # STEP 5: Remove Kubernetes packages
  # -----------------------------------------------
  header "STEP 5: Removing Kubernetes Packages"

  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true

  apt remove -y --purge \
    kubelet kubeadm kubectl \
    kubernetes-cni containernetworking-plugins \
    containerd runc \
    2>/dev/null || true

  apt autoremove -y --purge 2>/dev/null || true
  apt clean

  # -----------------------------------------------
  # STEP 6: Remove directories
  # -----------------------------------------------
  header "STEP 6: Removing Config & Data Directories"

  DIRS=(
    /etc/kubernetes /var/lib/kubelet /var/lib/etcd
    /var/lib/containerd /var/run/kubernetes /etc/containerd
    /opt/cni /etc/cni /var/lib/cni
    /run/flannel /etc/flannel
    /var/log/pods /var/log/containers
    /root/.kube "/home/*/.kube"
  )

  for DIR in "${DIRS[@]}"; do
    if ls $DIR 2>/dev/null | head -1 &>/dev/null; then
      rm -rf $DIR
      log "Removed: $DIR"
    fi
  done

  # -----------------------------------------------
  # STEP 7: Remove apt repo and keys
  # -----------------------------------------------
  header "STEP 7: Removing Kubernetes Apt Repo"

  rm -f /etc/apt/sources.list.d/kubernetes.list
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  apt update -y
  log "Kubernetes apt repo removed."

  # -----------------------------------------------
  # STEP 8: Sysctl and module config
  # -----------------------------------------------
  header "STEP 8: Removing sysctl & Module Config"

  rm -f /etc/sysctl.d/k8s.conf
  rm -f /etc/modules-load.d/k8s.conf
  sysctl --system > /dev/null 2>&1
  log "sysctl and module config removed."

  # -----------------------------------------------
  # STEP 9: Flush iptables
  # -----------------------------------------------
  header "STEP 9: Flushing iptables"

  iptables -F; iptables -X
  iptables -t nat -F; iptables -t nat -X
  iptables -t mangle -F; iptables -t mangle -X
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT

  ip6tables -F; ip6tables -X
  ip6tables -t nat -F 2>/dev/null; ip6tables -t nat -X 2>/dev/null
  ip6tables -t mangle -F 2>/dev/null; ip6tables -t mangle -X 2>/dev/null
  ip6tables -P INPUT ACCEPT
  ip6tables -P FORWARD ACCEPT
  ip6tables -P OUTPUT ACCEPT

  log "iptables flushed."

  # -----------------------------------------------
  # STEP 10: Remove virtual network interfaces
  # -----------------------------------------------
  header "STEP 10: Removing Virtual Network Interfaces"

  for IFACE in flannel.1 cni0 docker0 tunl0; do
    if ip link show $IFACE &>/dev/null; then
      ip link set $IFACE down
      ip link delete $IFACE
      log "Removed interface: $IFACE"
    fi
  done

  # -----------------------------------------------
  # STEP 11: Re-enable swap
  # -----------------------------------------------
  header "STEP 11: Re-enabling Swap"

  systemctl unmask swap.target 2>/dev/null || true
  sed -i 's/^#\(.*swap.*\)/\1/' /etc/fstab
  swapon -a 2>/dev/null || true
  log "Swap re-enabled."

  # -----------------------------------------------
  # STEP 12: Clean .bashrc
  # -----------------------------------------------
  header "STEP 12: Cleaning .bashrc"

  for RCFILE in /root/.bashrc /home/*/.bashrc; do
    if [[ -f "$RCFILE" ]]; then
      sed -i '/kubectl completion/d' "$RCFILE"
      sed -i '/alias k=kubectl/d' "$RCFILE"
      sed -i '/complete.*kubectl/d' "$RCFILE"
      log "Cleaned: $RCFILE"
    fi
  done

  header "Worker Node Cleanup Complete!"
  echo -e "${GREEN}"
  echo "  This worker node has been fully reset."
  echo "  It has been removed from the cluster (or you still need to run"
  echo "  the drain step from the master if not done yet)."
  echo -e "${NC}"
  exit 0
fi

# =============================================================
# MASTER teardown (full cluster wipe)
# =============================================================
if [[ "$ROLE" == "master" ]]; then

  header "Master Node Full Cluster Teardown"

  # -----------------------------------------------
  # STEP 1: Drain all worker nodes first
  # -----------------------------------------------
  header "STEP 1: Draining All Worker Nodes"

  export KUBECONFIG=/etc/kubernetes/admin.conf
  KUBECTL_PATH=$(which kubectl 2>/dev/null || echo "/usr/bin/kubectl")

  if command -v kubectl &>/dev/null && [[ -f /etc/kubernetes/admin.conf ]]; then
    WORKERS=$($KUBECTL_PATH get nodes --no-headers 2>/dev/null | \
      grep -v "control-plane\|master" | awk '{print $1}') || true

    if [[ -n "$WORKERS" ]]; then
      for NODE in $WORKERS; do
        log "Draining worker: $NODE"
        $KUBECTL_PATH cordon "$NODE" 2>/dev/null || true
        $KUBECTL_PATH drain "$NODE" \
          --ignore-daemonsets \
          --delete-emptydir-data \
          --force \
          --grace-period=30 \
          --timeout=120s 2>/dev/null || warn "Drain had issues on $NODE (may be offline)."
        $KUBECTL_PATH delete node "$NODE" --force 2>/dev/null || true
        log "Node $NODE removed."
      done
    else
      log "No worker nodes found in cluster."
    fi
  else
    warn "kubectl/admin.conf not found — skipping worker drain."
  fi

  # -----------------------------------------------
  # STEP 2: Remove GPU Operator via Helm
  # -----------------------------------------------
  header "STEP 2: Removing NVIDIA GPU Operator"

  if command -v helm &>/dev/null; then
    # Delete GPU test pod if exists
    if kubectl get pod gpu-test -n default &>/dev/null 2>&1; then
      log "Deleting GPU test pod..."
      kubectl delete pod gpu-test -n default --force --grace-period=0 2>/dev/null || true
    fi
    rm -f /root/gpu-test-pod.yaml 2>/dev/null || true

    # Uninstall GPU Operator Helm release
    if helm status gpu-operator -n gpu-operator &>/dev/null 2>&1; then
      log "Uninstalling GPU Operator Helm release..."
      helm uninstall gpu-operator -n gpu-operator --wait --timeout=3m 2>/dev/null || true
    else
      log "GPU Operator Helm release not found, skipping."
    fi

    # Delete gpu-operator namespace
    if kubectl get namespace gpu-operator &>/dev/null 2>&1; then
      log "Deleting gpu-operator namespace..."
      kubectl delete namespace gpu-operator --force --grace-period=0 2>/dev/null || true
    fi

    # Remove GPU Operator CRDs
    log "Removing GPU Operator CRDs..."
    kubectl get crd 2>/dev/null | grep -i 'nvidia\|nfd\|gpu' | awk '{print $1}' | \
      xargs kubectl delete crd --force --grace-period=0 2>/dev/null || true

    # Remove NVIDIA Helm repo
    if helm repo list 2>/dev/null | grep -q nvidia; then
      helm repo remove nvidia 2>/dev/null || true
    fi
  else
    log "Helm not found — skipping Helm-based GPU Operator removal."
  fi

  # -----------------------------------------------
  # STEP 3: Remove Helm
  # -----------------------------------------------
  header "STEP 3: Removing Helm"

  rm -f /usr/local/bin/helm 2>/dev/null || true
  rm -rf /root/.cache/helm /root/.config/helm /root/.local/share/helm

  if [[ -n "$SUDO_USER" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    rm -rf "$USER_HOME/.cache/helm" "$USER_HOME/.config/helm" "$USER_HOME/.local/share/helm"
  fi
  log "Helm fully removed."

  # -----------------------------------------------
  # STEP 4: Reset kubeadm
  # -----------------------------------------------
  header "STEP 4: kubeadm Reset"

  if command -v kubeadm &>/dev/null; then
    log "Running kubeadm reset..."
    kubeadm reset -f || true
  else
    log "kubeadm not found, skipping."
  fi

  # -----------------------------------------------
  # STEP 5: Stop services
  # -----------------------------------------------
  header "STEP 5: Stopping Services"

  for SVC in kubelet containerd; do
    systemctl stop $SVC 2>/dev/null    && log "Stopped $SVC."   || true
    systemctl disable $SVC 2>/dev/null && log "Disabled $SVC."  || true
  done

  # -----------------------------------------------
  # STEP 6: Remove NVIDIA container toolkit
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
  # STEP 7: Remove Kubernetes packages
  # -----------------------------------------------
  header "STEP 7: Removing Kubernetes Packages"

  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true

  apt remove -y --purge \
    kubelet kubeadm kubectl \
    kubernetes-cni containernetworking-plugins \
    containerd runc \
    2>/dev/null || true

  apt autoremove -y --purge 2>/dev/null || true
  apt clean
  log "Packages removed."

  # -----------------------------------------------
  # STEP 8: Remove directories
  # -----------------------------------------------
  header "STEP 8: Removing Config & Data Directories"

  DIRS=(
    /etc/kubernetes /var/lib/kubelet /var/lib/etcd
    /var/lib/containerd /var/run/kubernetes /etc/containerd
    /opt/cni /etc/cni /var/lib/cni
    /run/flannel /etc/flannel
    /var/log/pods /var/log/containers
    /root/.kube "/home/*/.kube"
    /root/kubeadm-init.log /root/gpu-operator-install.log
    /root/worker-join.sh
  )

  for DIR in "${DIRS[@]}"; do
    if ls $DIR 2>/dev/null | head -1 &>/dev/null; then
      rm -rf $DIR
      log "Removed: $DIR"
    fi
  done

  # -----------------------------------------------
  # STEP 9: Remove kube-dummy0 systemd service (master specific)
  # -----------------------------------------------
  header "STEP 9: Removing kube-dummy0 Interface & Service"

  systemctl stop kube-dummy-iface.service 2>/dev/null || true
  systemctl disable kube-dummy-iface.service 2>/dev/null || true
  rm -f /etc/systemd/system/kube-dummy-iface.service
  systemctl daemon-reload

  if ip link show kube-dummy0 &>/dev/null 2>&1; then
    ip link set kube-dummy0 down
    ip link delete kube-dummy0
    log "kube-dummy0 interface removed."
  fi

  log "kube-dummy service removed."

  # -----------------------------------------------
  # STEP 10: Remove apt repo and keys
  # -----------------------------------------------
  header "STEP 10: Removing Kubernetes Apt Repo"

  rm -f /etc/apt/sources.list.d/kubernetes.list
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  apt update -y
  log "Kubernetes apt repo removed."

  # -----------------------------------------------
  # STEP 11: Sysctl and module config
  # -----------------------------------------------
  header "STEP 11: Removing sysctl & Module Config"

  rm -f /etc/sysctl.d/k8s.conf
  rm -f /etc/modules-load.d/k8s.conf
  sysctl --system > /dev/null 2>&1
  log "sysctl and module config removed."

  # -----------------------------------------------
  # STEP 12: Flush iptables
  # -----------------------------------------------
  header "STEP 12: Flushing iptables"

  iptables -F; iptables -X
  iptables -t nat -F; iptables -t nat -X
  iptables -t mangle -F; iptables -t mangle -X
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT

  ip6tables -F; ip6tables -X
  ip6tables -t nat -F 2>/dev/null; ip6tables -t nat -X 2>/dev/null
  ip6tables -t mangle -F 2>/dev/null; ip6tables -t mangle -X 2>/dev/null
  ip6tables -P INPUT ACCEPT
  ip6tables -P FORWARD ACCEPT
  ip6tables -P OUTPUT ACCEPT

  log "iptables flushed."

  # -----------------------------------------------
  # STEP 13: Remove virtual network interfaces
  # -----------------------------------------------
  header "STEP 13: Removing Virtual Network Interfaces"

  for IFACE in flannel.1 cni0 docker0 tunl0; do
    if ip link show $IFACE &>/dev/null; then
      ip link set $IFACE down
      ip link delete $IFACE
      log "Removed interface: $IFACE"
    fi
  done

  # -----------------------------------------------
  # STEP 14: Re-enable swap
  # -----------------------------------------------
  header "STEP 14: Re-enabling Swap"

  systemctl unmask swap.target 2>/dev/null || true
  sed -i 's/^#\(.*swap.*\)/\1/' /etc/fstab
  swapon -a 2>/dev/null || true
  log "Swap re-enabled."

  # -----------------------------------------------
  # STEP 15: Clean .bashrc
  # -----------------------------------------------
  header "STEP 15: Cleaning .bashrc"

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
  header "Full Cluster Cleanup Complete!"
  echo -e "${GREEN}"
  echo "  Everything has been removed:"
  echo "    - All worker nodes drained and deleted"
  echo "    - NVIDIA GPU Operator (Helm + namespace + CRDs)"
  echo "    - NVIDIA container toolkit"
  echo "    - Helm binary + cache"
  echo "    - kubeadm / kubelet / kubectl / containerd / runc"
  echo "    - All config dirs (/etc/kubernetes, /var/lib/etcd, etc.)"
  echo "    - Kubernetes apt repo and GPG key"
  echo "    - kube-dummy0 interface and systemd service"
  echo "    - iptables rules, virtual interfaces"
  echo "    - Swap re-enabled"
  echo ""
  echo "  Worker nodes still need to be individually reset:"
  echo "    sudo bash dispose-kube.sh --role worker --master-ip <was-master-ip>"
  echo -e "${NC}"

fi