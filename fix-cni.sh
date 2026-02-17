#!/usr/bin/env bash

echo "========================================="
echo "FIX: Missing CNI Plugins"
echo "========================================="
echo
echo "Problem: Pods cannot start due to missing CNI loopback plugin"
echo "This is why the NVIDIA device plugin is stuck in ContainerCreating"
echo

# Check if CNI bin directory exists
echo "Step 1: Checking CNI directory..."
ls -la /opt/cni/bin/ 2>/dev/null || echo "Directory /opt/cni/bin does not exist"
echo

# Install CNI plugins
echo "Step 2: Installing CNI plugins..."
CNI_VERSION="v1.5.1"
CNI_ARCH="amd64"
CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${CNI_ARCH}-${CNI_VERSION}.tgz"

# Create directory
sudo mkdir -p /opt/cni/bin

# Download and extract CNI plugins
echo "Downloading CNI plugins ${CNI_VERSION}..."
curl -L "${CNI_URL}" -o /tmp/cni-plugins.tgz

echo "Extracting CNI plugins to /opt/cni/bin..."
sudo tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin

# Clean up
rm /tmp/cni-plugins.tgz

echo
echo "Step 3: Verifying CNI plugins..."
ls -lh /opt/cni/bin/
echo

# Check for loopback specifically
if [ -f /opt/cni/bin/loopback ]; then
    echo "✅ loopback plugin found!"
else
    echo "❌ loopback plugin still missing!"
    exit 1
fi

echo
echo "Step 4: Restarting kubelet..."
sudo systemctl restart kubelet
sleep 5

echo
echo "Step 5: Deleting stuck device plugin pod to trigger restart..."
kubectl delete pod -n kube-system -l name=nvidia-device-plugin-ds --force --grace-period=0 2>/dev/null || true

echo
echo "Waiting for new device plugin pod to start..."
sleep 15

echo
echo "Step 6: Checking device plugin status..."
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds
echo

echo "Waiting for device plugin to be ready..."
kubectl wait --for=condition=ready pod -l name=nvidia-device-plugin-ds -n kube-system --timeout=120s 2>&1 || {
    echo "Device plugin not ready yet, showing logs..."
    kubectl logs -n kube-system -l name=nvidia-device-plugin-ds --tail=30
}

echo
echo "Step 7: Verifying GPU resources are available..."
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl describe node $NODE_NAME | grep -A10 "Capacity:" | grep nvidia || echo "No GPU resources found yet"

echo
echo "Step 8: Testing GPU pod..."

# Delete old test pod
kubectl delete pod gpu-test --force --grace-period=0 2>/dev/null || true
sleep 3

# Create new test pod
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvidia/cuda:12.5.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

echo "Waiting for GPU test pod..."
sleep 15

kubectl get pod gpu-test
echo

# Check if pod is running/completed
POD_PHASE=$(kubectl get pod gpu-test -o jsonpath='{.status.phase}')
echo "Pod Phase: $POD_PHASE"

if [ "$POD_PHASE" == "Pending" ]; then
    echo
    echo "Pod is still pending. Checking events..."
    kubectl describe pod gpu-test | grep -A20 "Events:"
elif [ "$POD_PHASE" == "Succeeded" ] || [ "$POD_PHASE" == "Running" ]; then
    echo
    echo "✅ Pod is running! Checking logs..."
    sleep 5
    kubectl logs gpu-test
else
    echo "Pod status: $POD_PHASE"
    kubectl describe pod gpu-test
fi

echo
echo "========================================="
echo "Summary"
echo "========================================="
echo
echo "CNI Plugins installed at /opt/cni/bin/:"
ls /opt/cni/bin/ | head -5
echo "... (and more)"
echo
echo "Node GPU Capacity:"
kubectl describe node $NODE_NAME | grep -A2 "Allocatable:" | grep nvidia || echo "GPU resources not advertised yet"
echo
echo "Device Plugin Status:"
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds
echo
echo "GPU Test Pod Status:"
kubectl get pod gpu-test
echo
echo "If GPU resources still not available, check device plugin logs:"
echo "  kubectl logs -n kube-system -l name=nvidia-device-plugin-ds"