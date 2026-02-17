#!/usr/bin/env bash

echo "========================================="
echo " IDEMPOTENT Kubernetes + NVIDIA DISPOSER"
echo " Ubuntu 24.04 LTS"
echo "========================================="

### ---------- helpers ----------
log() { echo "➡ $1"; }
skip() { echo "ℹ $1 (skipped)"; }

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

pkg_exists() {
  dpkg -s "$1" >/dev/null 2>&1
}

svc_exists() {
  systemctl list-unit-files 2>/dev/null | grep -q "^$1"
}

safe_stop_service() {
  if svc_exists "$1"; then
    systemctl stop "$1" >/dev/null 2>&1 || true
    systemctl disable "$1" >/dev/null 2>&1 || true
    log "Stopped & disabled service: $1"
  else
    skip "Service $1 not found"
  fi
}

safe_purge_pkg() {
  if pkg_exists "$1"; then
    apt purge -y "$1" >/dev/null 2>&1 || true
    log "Purged package: $1"
  else
    skip "Package $1 not installed"
  fi
}

safe_rm() {
  if [ -e "$1" ]; then
    rm -rf "$1"
    log "Removed: $1"
  else
    skip "Path $1 not present"
  fi
}

### ---------- root check ----------
if [[ $EUID -ne 0 ]]; then
  echo "❌ Run as root: sudo bash uninstall-kube-cuda.sh"
  exit 1
fi

USER_NAME=${SUDO_USER:-root}
USER_HOME=$(eval echo "~$USER_NAME")

log "Cleaning for user: $USER_NAME"

echo
log "Step 1: Stopping all Kubernetes pods and draining node"

if cmd_exists kubectl && [ -f /etc/kubernetes/admin.conf ]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
  
  # Get node name with a hard timeout so we don't hang if API server is unresponsive
  NODE_NAME=$(timeout 10 kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [ -n "$NODE_NAME" ]; then
    log "Draining node: $NODE_NAME"
    timeout 60 kubectl drain "$NODE_NAME" --delete-emptydir-data --force --ignore-daemonsets --timeout=30s >/dev/null 2>&1 || skip "Node drain failed or timed out"
    timeout 15 kubectl delete node "$NODE_NAME" >/dev/null 2>&1 || skip "Node delete failed or timed out"
  else
    skip "No nodes found to drain (API server may already be down)"
  fi
else
  skip "kubectl or admin.conf not available"
fi

echo
log "Step 2: Resetting Kubernetes cluster"

if cmd_exists kubeadm; then
  kubeadm reset -f >/dev/null 2>&1 || skip "kubeadm reset failed"
  kubeadm reset -f --cri-socket=unix:///var/run/containerd/containerd.sock >/dev/null 2>&1 || skip "kubeadm reset with cri failed"
fi

echo
log "Step 3: Killing all Kubernetes-related processes"

# Kill any remaining kube processes
for proc in kube-apiserver kube-controller kube-scheduler kubelet kube-proxy etcd; do
  pkill -9 $proc 2>/dev/null && log "Killed $proc" || skip "$proc not running"
done

# Kill containerd processes
for proc in containerd-shim containerd-shim-runc-v2 containerd ctr runc; do
  pkill -9 $proc 2>/dev/null && log "Killed $proc processes" || skip "No $proc processes"
done

# Kill any kubectl proxy or port-forward processes
pkill -f "kubectl proxy" 2>/dev/null && log "Killed kubectl proxy" || skip "No kubectl proxy"
pkill -f "kubectl port-forward" 2>/dev/null && log "Killed kubectl port-forward" || skip "No kubectl port-forward"

# Kill any remaining container processes
pkill -9 "docker-containerd" 2>/dev/null || true
pkill -9 "docker" 2>/dev/null || true

echo
log "Step 4: Stopping services"
safe_stop_service kubelet.service
safe_stop_service containerd.service
safe_stop_service docker.service 2>/dev/null || true

echo
log "Step 5: Unmounting Kubernetes volumes"

# Unmount any remaining kubelet volumes
for mount in $(mount | grep -E '/var/lib/kubelet|/var/lib/containerd|/run/containerd' | awk '{print $3}' 2>/dev/null); do
  umount -f "$mount" 2>/dev/null && log "Unmounted: $mount" || skip "Failed to unmount: $mount"
done

echo
log "Step 6: Removing packages"

# Unhold packages first
if cmd_exists apt-mark; then
  apt-mark unhold kubelet kubeadm kubectl docker docker-engine docker.io containerd runc >/dev/null 2>&1 || skip "No packages to unhold"
fi

# Remove all Kubernetes and container packages
for pkg in kubeadm kubelet kubectl kubernetes-cni containerd containerd.io runc docker docker-engine docker.io docker-ce docker-ce-cli; do
  safe_purge_pkg $pkg
done

# Remove NVIDIA container packages
for pkg in nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1 nvidia-docker2; do
  safe_purge_pkg $pkg
done

apt autoremove --purge -y >/dev/null 2>&1 || true
apt autoclean -y >/dev/null 2>&1 || true
apt clean -y >/dev/null 2>&1 || true

echo
log "Step 7: Removing runtime & cluster state directories"
for dir in \
  /etc/kubernetes \
  /var/lib/kubelet \
  /var/lib/etcd \
  /var/lib/cni \
  /etc/cni \
  /opt/cni \
  /run/flannel \
  /var/run/flannel \
  /var/lib/containerd \
  /etc/containerd \
  /run/containerd \
  /var/run/containerd \
  /var/lib/docker \
  /etc/docker \
  /run/docker \
  /var/run/docker \
  /var/lib/kube-proxy \
  /var/lib/minikube \
  /var/lib/kubeadm; do
  safe_rm "$dir"
done

# Remove systemd configs
for file in \
  /etc/systemd/system/kubelet.service.d \
  /usr/lib/systemd/system/kubelet.service \
  /usr/lib/systemd/system/containerd.service \
  /usr/lib/systemd/system/docker.service \
  /etc/systemd/system/kubelet.service \
  /etc/systemd/system/containerd.service \
  /etc/systemd/system/docker.service; do
  safe_rm "$file"
done

# Reload systemd
if cmd_exists systemctl; then
  systemctl daemon-reload >/dev/null 2>&1 || skip "systemctl daemon-reload failed"
  systemctl reset-failed 2>/dev/null || skip "systemctl reset-failed failed"
fi

echo
log "Step 8: Removing user kubectl config and cache"

# Remove all kubectl configs and cache
safe_rm "$USER_HOME/.kube"
safe_rm "$USER_HOME/.kubectl"
safe_rm "$USER_HOME/.kubeconfig"
safe_rm "$USER_HOME/.minikube"
safe_rm "$USER_HOME/.docker"

# Also check root's configs if different user
if [ "$USER_NAME" != "root" ]; then
  safe_rm /root/.kube
  safe_rm /root/.kubectl
  safe_rm /root/.kubeconfig
  safe_rm /root/.minikube
  safe_rm /root/.docker
fi

# Remove any kubectl plugins
safe_rm "$USER_HOME/.krew"
safe_rm /usr/local/bin/kubectl-*

echo
log "Step 9: Clearing command hashes"

# Clear bash hash table
hash -r 2>/dev/null || true

# Clear command cache for all users
for user_home in /home/* /root; do
  if [ -f "$user_home/.bashrc" ]; then
    sed -i '/kubectl/d' "$user_home/.bashrc" 2>/dev/null || true
    sed -i '/kube/d' "$user_home/.bashrc" 2>/dev/null || true
  fi
  if [ -f "$user_home/.bash_aliases" ]; then
    sed -i '/kubectl/d' "$user_home/.bash_aliases" 2>/dev/null || true
    sed -i '/kube/d' "$user_home/.bash_aliases" 2>/dev/null || true
  fi
done

# Remove any kubectl completions
safe_rm /etc/bash_completion.d/kubectl
safe_rm /usr/share/bash-completion/completions/kubectl

echo
log "Step 10: Cleaning network configuration"

# Remove CNI network interfaces
if cmd_exists ip; then
  for iface in cni0 flannel.1 docker0 weave veth*; do
    for actual_iface in $(ip link show | grep -o "^[0-9]*: \($iface\)" | cut -d' ' -f2 | tr -d ':' 2>/dev/null); do
      ip link delete "$actual_iface" 2>/dev/null && log "Removed interface: $actual_iface" || skip "Failed to remove: $actual_iface"
    done
  done
  
  # Remove bridge interfaces
  for bridge in $(ip link show type bridge | grep -o "^[0-9]*: [^:]*" | cut -d' ' -f2 | tr -d ':' | grep -E 'cni|docker|flannel|weave' 2>/dev/null); do
    ip link delete "$bridge" type bridge 2>/dev/null && log "Removed bridge: $bridge" || true
  done
else
  skip "ip command not available"
fi

# Clean iptables rules
if cmd_exists iptables; then
  log "Flushing iptables rules"
  
  # Save current rules just in case
  iptables-save > /tmp/iptables-backup-$(date +%s).txt 2>/dev/null || true
  
  # Flush all tables
  for table in filter nat mangle raw security; do
    iptables -t $table -F 2>/dev/null || true
    iptables -t $table -X 2>/dev/null || true
    iptables -t $table -Z 2>/dev/null || true
  done
  
  # Also clean ip6tables
  for table in filter nat mangle raw security; do
    ip6tables -t $table -F 2>/dev/null || true
    ip6tables -t $table -X 2>/dev/null || true
    ip6tables -t $table -Z 2>/dev/null || true
  done
  
  # Set default policies
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -P FORWARD ACCEPT 2>/dev/null || true
  iptables -P OUTPUT ACCEPT 2>/dev/null || true
  
  log "iptables flushed and reset"
else
  skip "iptables not installed"
fi

# Remove ipvs rules
if cmd_exists ipvsadm; then
  ipvsadm -C 2>/dev/null && log "Cleared IPVS rules" || skip "No IPVS rules to clear"
fi

# Clear nftables if present
if cmd_exists nft; then
  nft flush ruleset 2>/dev/null && log "Flushed nftables ruleset" || skip "No nftables rules"
fi

echo
log "Step 11: Finding and killing processes on Kubernetes ports"

# Define Kubernetes ports
K8S_PORTS="6443 10250 10251 10252 10255 10256 2379 2380 8472 30000-32767 8080 8443"

# Find and kill processes on these ports
if cmd_exists lsof; then
  for port in 6443 10250 10251 10252 10255 10256 2379 2380 8472 8080 8443; do
    pids=$(lsof -ti :$port 2>/dev/null)
    if [ -n "$pids" ]; then
      for pid in $pids; do
        kill -9 $pid 2>/dev/null && log "Killed process $pid on port $port" || true
      done
    fi
  done
elif cmd_exists ss; then
  for port in 6443 10250 10251 10252 10255 10256 2379 2380 8472 8080 8443; do
    pids=$(ss -tulpn 2>/dev/null | grep ":$port" | grep -o 'pid=[0-9]*' | cut -d= -f2)
    for pid in $pids; do
      kill -9 $pid 2>/dev/null && log "Killed process $pid on port $port" || true
    done
  done
fi

echo
log "Step 12: Removing APT repositories"

# Remove Kubernetes repos
safe_rm /etc/apt/sources.list.d/kubernetes.list
safe_rm /etc/apt/sources.list.d/k8s.list
safe_rm /etc/apt/keyrings/kubernetes-apt-keyring.gpg
safe_rm /etc/apt/trusted.gpg.d/kubernetes.gpg

# Remove Docker repos
safe_rm /etc/apt/sources.list.d/docker.list
safe_rm /etc/apt/keyrings/docker.gpg
safe_rm /etc/apt/trusted.gpg.d/docker.gpg

# Remove NVIDIA repos
safe_rm /etc/apt/sources.list.d/nvidia-container-toolkit.list
safe_rm /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Update apt cache
apt update -y >/dev/null 2>&1 || skip "apt update failed"

echo
log "Step 13: Removing binaries and symlinks"

# Remove all related binaries
for bin in kubectl kubeadm kubelet containerd containerd-shim containerd-shim-runc-v2 ctr runc docker dockerd docker-init docker-proxy docker-runc; do
  for path in /usr/bin /usr/local/bin /opt/bin /usr/sbin /usr/local/sbin /snap/bin; do
    if [ -f "$path/$bin" ] || [ -L "$path/$bin" ]; then
      rm -f "$path/$bin"
      log "Removed binary/link: $path/$bin"
    fi
  done
done

# Remove snap packages if present
if cmd_exists snap; then
  snap remove kubectl 2>/dev/null && log "Removed kubectl snap" || skip "kubectl snap not found"
  snap remove kubelet 2>/dev/null && log "Removed kubelet snap" || skip "kubelet snap not found"
  snap remove docker 2>/dev/null && log "Removed docker snap" || skip "docker snap not found"
fi

echo
log "Step 14: Removing sysctl configuration"
safe_rm /etc/sysctl.d/k8s.conf
safe_rm /etc/sysctl.d/99-kubernetes.conf
if cmd_exists sysctl; then
  sysctl --system >/dev/null 2>&1 || skip "sysctl reload failed"
fi

echo
log "Step 15: Re-enabling swap"

# Re-enable swap in fstab
if [ -f /etc/fstab ]; then
  # Uncomment any commented swap lines
  sed -i '/^#.*swap/s/^#//' /etc/fstab 2>/dev/null || skip "No swap entries in fstab"
  # Try to turn swap back on
  swapon -a 2>/dev/null && log "Swap re-enabled" || skip "No swap to enable"
  swapon --show 2>/dev/null | grep -v "^$" && log "Active swap:" || skip "No active swap"
else
  skip "/etc/fstab not found"
fi

echo
log "Step 16: Final verification and cleanup"

# Check if any k8s ports are still in use
if cmd_exists lsof; then
  for port in 6443 10250 10251 10252 10255 10256 2379 2380 8472; do
    if lsof -i :$port >/dev/null 2>&1; then
      log "⚠ WARNING: Port $port still in use. Process details:"
      lsof -i :$port 2>/dev/null || true
    else
      log "✅ Port $port is free"
    fi
  done
else
  skip "lsof not available for port check"
fi

# Check if kubectl is still in PATH
if cmd_exists kubectl; then
  log "⚠ WARNING: kubectl still found in PATH at $(which kubectl)"
  log "Removing it forcefully..."
  rm -f $(which kubectl) 2>/dev/null || true
else
  log "✅ kubectl not found in PATH"
fi

# Remove any lingering network namespaces
if [ -d /var/run/netns ]; then
  for ns in /var/run/netns/*; do
    [ -e "$ns" ] || continue
    ns_name=$(basename "$ns")
    ip netns delete "$ns_name" 2>/dev/null && log "Removed netns: $ns_name" || skip "Failed to remove netns: $ns_name"
  done
fi

# Remove any leftover containerd sockets
safe_rm /run/containerd/containerd.sock
safe_rm /var/run/containerd/containerd.sock
safe_rm /run/docker.sock
safe_rm /var/run/docker.sock

# Restart networking services
if cmd_exists systemctl; then
  systemctl restart NetworkManager >/dev/null 2>&1 || skip "NetworkManager restart failed"
  systemctl restart systemd-networkd >/dev/null 2>&1 || skip "systemd-networkd restart failed"
  systemctl restart networking >/dev/null 2>&1 || skip "networking restart failed"
fi

# Clear DNS cache if present
if cmd_exists systemd-resolve; then
  systemd-resolve --flush-caches 2>/dev/null && log "Flushed DNS cache" || true
fi

echo
log "Step 17: Removing all traces from environment"

# Remove from PATH in profile files
for profile in /etc/profile /etc/bash.bashrc /etc/environment; do
  if [ -f "$profile" ]; then
    sed -i '/kubectl/d' "$profile" 2>/dev/null || true
    sed -i '/kube/d' "$profile" 2>/dev/null || true
    sed -i '/docker/d' "$profile" 2>/dev/null || true
  fi
done

# Clear all command hashes again
hash -r 2>/dev/null || true
# NOTE: do NOT exec bash -l here — it would replace the shell and hang the script

echo
echo "========================================="
echo " ✅ CLEANUP COMPLETE (IDEMPOTENT)"
echo "========================================="
echo "➡ Safe to re-run anytime"
echo "➡ REBOOT STRONGLY RECOMMENDED: sudo reboot"
echo ""
echo "After reboot, verify cleanup with:"
echo "  - sudo lsof -i :10250    (should be empty)"
echo "  - which kubectl          (should not be found)"
echo "  - kubectl version        (command not found error)"
echo "  - hash kubectl            (should not be in hash table)"
echo "  - sudo systemctl status kubelet (unit not found)"
echo ""
echo "To clear your current shell's command cache after reboot:"
echo "  hash -r"