#!/bin/bash
#
# k8s_ooda.sh
#
# LLM-guided Kubernetes install using an explicit OODA loop:
#   Observe -> Orient -> Decide -> Act
#
# Key trait of OODA here: only *state* (system status + raw history + last
# error) is fed back into the loop. The model's reasoning is never asked for
# or persisted -- each cycle it just re-observes the world and emits a bare
# next action. There is no "scratchpad" of thoughts, only a scratchpad of
# facts.
#
# Requires: GROQ_API_KEY env var. Ubuntu + sudo. Installs jq/curl if missing.

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
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

MODEL="${GROQ_MODEL:-llama-3.3-70b-versatile}"   # check Groq's current model list
HISTORY=""
LAST_ERROR=""
MAX_HISTORY_LINES=20

# ---------------------------------------------------------------------------
# OBSERVE: gather raw, unfiltered facts about the world
# ---------------------------------------------------------------------------
observe() {
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

# ---------------------------------------------------------------------------
# ORIENT: assemble facts + history + last error into situational context.
# No reasoning happens here -- this just shapes what the model sees.
# ---------------------------------------------------------------------------
orient() {
    local status="$1"
    {
        echo "Current status:"
        echo "$status"
        echo
        echo "History (last actions):"
        echo -e "$HISTORY" | tail -n "$MAX_HISTORY_LINES"
        echo
        echo "$LAST_ERROR"
        echo
        echo "Suggest the next command to progress towards the goal."
    }
}

# ---------------------------------------------------------------------------
# DECIDE: single LLM call, returns one bare command. No explanation asked
# for, none stored.
# ---------------------------------------------------------------------------
decide() {
    local context="$1"

    local system_prompt
    system_prompt="You are a Kubernetes installation expert on Ubuntu. The goal is to install single-node Kubernetes using kubeadm, Docker as container runtime, and Calico for pod networking (with pod-network-cidr=192.168.0.0/16). Then, test pod networking, logging, and self-healing as described.

Respond with ONLY a valid JSON object: {\"command\": \"the next single shell command to run\"}. Do not include explanations or additional text."

    local request
    request=$(jq -n \
        --arg model "$MODEL" \
        --arg sys "$system_prompt" \
        --arg usr "$context" \
        '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $usr}]}')

    local response
    response=$(curl -s -X POST https://api.groq.com/openai/v1/chat/completions \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$request")

    local command
    command=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | jq -r '.command' 2>/dev/null)

    if [ -z "$command" ] || [ "$command" = "null" ]; then
        echo "Failed to parse command from LLM response." >&2
        echo "Raw response: $response" >&2
        exit 1
    fi

    echo "$command"
}

# ---------------------------------------------------------------------------
# ACT: execute the chosen command, fold outcome back into raw state
# ---------------------------------------------------------------------------
act() {
    local command="$1"
    echo "Executing: $command"

    local output exit_code
    output=$(bash -c "$command" 2>&1)
    exit_code=$?

    HISTORY="$HISTORY\nCommand: $command\nOutput: $output"

    if [ $exit_code -ne 0 ]; then
        LAST_ERROR="Last command failed with exit code $exit_code and output: $output"
    else
        LAST_ERROR=""
    fi
}

# ---------------------------------------------------------------------------
# Goal check (unchanged mechanics: untaint, deploy nginx + testpod, verify
# networking/logging/self-healing)
# ---------------------------------------------------------------------------
check_goal() {
    if ! kubectl get nodes &>/dev/null; then return 1; fi

    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

    if ! kubectl get deployment nginx &>/dev/null; then
        kubectl create deployment nginx --image=nginx || return 1
    fi
    kubectl rollout status deployment/nginx --timeout=120s || return 1

    if ! kubectl get pod testpod &>/dev/null; then
        kubectl run testpod --image=busybox --command -- sleep infinity || return 1
    fi
    kubectl wait --for=condition=Ready pod/testpod --timeout=120s || return 1

    NGINX_IP=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].status.podIP}')
    kubectl exec testpod -- wget --spider --timeout=1 http://"$NGINX_IP" || return 1
    kubectl exec testpod -- wget -q -O /dev/null http://"$NGINX_IP" || return 1

    NGINX_POD=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
    if ! kubectl logs "$NGINX_POD" | grep -q "GET"; then return 1; fi

    kubectl delete pod "$NGINX_POD" --force --grace-period=0 || return 1
    kubectl rollout status deployment/nginx --timeout=120s || return 1

    kubectl delete pod testpod --force --grace-period=0 || true

    return 0
}

# ---------------------------------------------------------------------------
# Main OODA loop
# ---------------------------------------------------------------------------
echo "Starting LLM-guided Kubernetes installation (OODA loop)..."

while true; do
    if check_goal; then
        echo "Goal achieved! Kubernetes installed and tests passed."
        break
    fi

    STATUS=$(observe)
    CONTEXT=$(orient "$STATUS")
    COMMAND=$(decide "$CONTEXT")
    act "$COMMAND"

    sleep 2
done
