#!/bin/bash
#
# k8s_react.sh
#
# LLM-guided Kubernetes install using the ReAct pattern:
#   Thought -> Action -> Observation -> (fed back into next Thought)
#
# Key trait of ReAct here: the model is explicitly asked to reason out loud
# ("thought") before each command, and that reasoning is persisted in a
# running SCRATCHPAD alongside the action taken and what happened. Each new
# call sees the full Thought/Action/Observation trace, not just raw system
# state -- the reasoning itself is part of the context, which is what
# distinguishes this from a bare OODA loop.
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
SCRATCHPAD=""          # accumulates Thought/Action/Observation turns
MAX_SCRATCHPAD_LINES=40

# ---------------------------------------------------------------------------
# Snapshot of raw system state (same role as OODA's observe(), but here it's
# just one ingredient handed to the model alongside the reasoning trace)
# ---------------------------------------------------------------------------
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
# One ReAct step: ask the model to think, then act, in a single JSON object.
# ---------------------------------------------------------------------------
react_step() {
    local status="$1"

    local system_prompt
    system_prompt="You are a Kubernetes installation expert on Ubuntu, operating in a ReAct loop (Thought, then Action). The goal is to install single-node Kubernetes using kubeadm, Docker as container runtime, and Calico for pod networking (with pod-network-cidr=192.168.0.0/16). Then test pod networking, logging, and self-healing.

Before acting, briefly reason about what the current status and trace imply and what to try next. Then choose exactly one shell command to run.

Respond with ONLY a valid JSON object, no other text:
{\"thought\": \"one or two sentences of reasoning about the current state and why this command is the right next step\", \"command\": \"the next single shell command to run\"}"

    local user_prompt
    user_prompt=$(cat <<EOF
Current status:
$status

Trace so far (Thought / Action / Observation):
$(echo -e "$SCRATCHPAD" | tail -n "$MAX_SCRATCHPAD_LINES")

Think, then decide the next command.
EOF
)

    local request
    request=$(jq -n \
        --arg model "$MODEL" \
        --arg sys "$system_prompt" \
        --arg usr "$user_prompt" \
        '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $usr}]}')

    local response
    response=$(curl -s -X POST https://api.groq.com/openai/v1/chat/completions \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$request")

    local raw_content
    raw_content=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null)

    THOUGHT=$(echo "$raw_content" | jq -r '.thought' 2>/dev/null)
    COMMAND=$(echo "$raw_content" | jq -r '.command' 2>/dev/null)

    if [ -z "$COMMAND" ] || [ "$COMMAND" = "null" ]; then
        echo "Failed to parse thought/command from LLM response." >&2
        echo "Raw response: $response" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main ReAct loop
# ---------------------------------------------------------------------------
echo "Starting LLM-guided Kubernetes installation (ReAct loop)..."

while true; do
    if check_goal; then
        echo "Goal achieved! Kubernetes installed and tests passed."
        break
    fi

    STATUS=$(get_status)

    THOUGHT=""
    COMMAND=""
    react_step "$STATUS"

    echo "Thought: $THOUGHT"
    echo "Action: $COMMAND"

    OUTPUT=$(bash -c "$COMMAND" 2>&1)
    EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ]; then
        OBSERVATION="Command failed (exit $EXIT_CODE): $OUTPUT"
    else
        OBSERVATION="Command succeeded. Output: $OUTPUT"
    fi
    echo "Observation: $OBSERVATION"

    # Persist the full Thought/Action/Observation turn -- this is what feeds
    # the model's own reasoning back into the next iteration.
    SCRATCHPAD="$SCRATCHPAD\nThought: $THOUGHT\nAction: $COMMAND\nObservation: $OBSERVATION"

    sleep 2
done
