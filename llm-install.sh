#!/bin/bash

# This script uses Groq LLM API to guide the installation of Kubernetes step by step.
# It is self-healing as it reports errors back to the LLM for correction.
# Set your GROQ_API_KEY environment variable before running.
# Assumes running on Ubuntu with sudo privileges.
# Installs jq and curl if not present.

set -euo pipefail

# Check and install prerequisites: curl and jq
if ! command -v curl >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y curl
fi

if ! command -v jq >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y jq
fi

if [ -z "${GROQ_API_KEY:-}" ]; then
    echo "Error: GROQ_API_KEY environment variable is not set."
    exit 1
fi

MODEL="llama3-70b-8192"
HISTORY=""
LAST_ERROR=""
MAX_HISTORY_LINES=20  # Limit history to prevent token overflow

get_status() {
    {
        echo "OS: $(uname -a)"
        echo "Swap: $(swapon --show || echo 'none')"
        echo "Docker: $(docker --version 2>/dev/null || echo 'not installed')"
        echo "kubeadm: $(kubeadm version 2>/dev/null || echo 'not installed')"
        echo "kubelet: $(kubelet --version 2>/dev/null || echo 'not installed')"
        echo "kubectl: $(kubectl version --client 2>/dev/null || echo 'not installed')"
        echo "Cluster status: $(kubectl get nodes 2>&1 || echo 'no cluster')"
        echo "Calico: $(kubectl get pods -n kube-system 2>/dev/null | grep calico || echo 'not installed')"
    }
}

check_goal() {
    # Check if cluster is ready
    if ! kubectl get nodes &>/dev/null; then return 1; fi

    # Untaint control-plane for single-node
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

    # Deploy nginx if not exists
    if ! kubectl get deployment nginx &>/dev/null; then
        kubectl create deployment nginx --image=nginx || return 1
    fi
    kubectl rollout status deployment/nginx --timeout=120s || return 1

    # Deploy testpod if not exists
    if ! kubectl get pod testpod &>/dev/null; then
        kubectl run testpod --image=busybox --command -- sleep infinity || return 1
    fi
    kubectl wait --for=condition=Ready pod/testpod --timeout=120s || return 1

    # Test networking
    NGINX_IP=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].status.podIP}')
    kubectl exec testpod -- wget --spider --timeout=1 http://"$NGINX_IP" || return 1

    # Generate log entry
    kubectl exec testpod -- wget -q -O /dev/null http://"$NGINX_IP" || return 1

    # Test logging
    NGINX_POD=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
    if ! kubectl logs "$NGINX_POD" | grep -q "GET"; then return 1; fi

    # Test self-healing
    kubectl delete pod "$NGINX_POD" --force --grace-period=0 || return 1
    kubectl rollout status deployment/nginx --timeout=120s || return 1

    # Cleanup testpod
    kubectl delete pod testpod --force --grace-period=0 || true

    return 0
}

echo "Starting LLM-guided Kubernetes installation..."

while true; do
    if check_goal; then
        echo "Goal achieved! Kubernetes installed and tests passed."
        # Optional cleanup: kubectl delete deployment nginx
        break
    fi

    STATUS=$(get_status)
    SYSTEM_PROMPT="You are a Kubernetes installation expert on Ubuntu. The goal is to install single-node Kubernetes using kubeadm, Docker as container runtime, and Calico for pod networking (with pod-network-cidr=192.168.0.0/16). Then, test pod networking, logging, and self-healing as described.

Respond with ONLY a valid JSON object: {\"command\": \"the next single shell command to run\"}. Do not include explanations or additional text."

    USER_PROMPT="Current status:
$STATUS

History (last actions):
$(echo "$HISTORY" | tail -n $MAX_HISTORY_LINES)

$LAST_ERROR

Suggest the next command to progress towards the goal."

    # Build JSON request with jq
    REQUEST=$(jq -n \
        --arg model "$MODEL" \
        --arg sys "$SYSTEM_PROMPT" \
        --arg usr "$USER_PROMPT" \
        '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $usr}]}')

    RESPONSE=$(curl -s -X POST https://api.groq.com/openai/v1/chat/completions \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$REQUEST")

    COMMAND=$(echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null | jq -r '.command' 2>/dev/null)

    if [ -z "$COMMAND" ]; then
        echo "Failed to parse command from LLM response."
        echo "Raw response: $RESPONSE"
        exit 1
    fi

    echo "Executing: $COMMAND"
    OUTPUT=$(bash -c "$COMMAND" 2>&1)
    EXIT_CODE=$?

    HISTORY="$HISTORY\nCommand: $COMMAND\nOutput: $OUTPUT"

    if [ $EXIT_CODE -ne 0 ]; then
        LAST_ERROR="Last command failed with exit code $EXIT_CODE and output: $OUTPUT"
    else
        LAST_ERROR=""
    fi

    sleep 2  # Short delay to avoid rapid looping
done