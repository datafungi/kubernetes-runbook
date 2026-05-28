#!/usr/bin/env bash
# scripts/lib/common.sh — shared utilities for all component scripts
# Source this file; do not execute directly.

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; }
die()       { log_error "$*"; exit 1; }

# ── Prerequisite checks ───────────────────────────────────────────────────────
require_commands() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Required commands not found: ${missing[*]}"
  fi
}

# ── Kubernetes helpers ────────────────────────────────────────────────────────
create_namespace() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log_info "Namespace '$ns' ready"
}

wait_for_rollout() {
  local kind="$1" name="$2" namespace="$3" timeout="${4:-300s}"
  log_info "Waiting for $kind/$name in namespace '$namespace'..."

  # Operator-managed resources (e.g. StatefulSets created by a CR) may not
  # exist yet when this function is called. Wait up to 2 minutes for the
  # object to appear before handing off to kubectl rollout status.
  local deadline=$(( SECONDS + 120 ))
  until kubectl get "$kind/$name" -n "$namespace" >/dev/null 2>&1; do
    [[ $SECONDS -lt $deadline ]] \
      || die "Timed out waiting for $kind/$name to be created in namespace '$namespace'"
    sleep 5
  done

  kubectl rollout status "$kind/$name" -n "$namespace" --timeout="$timeout"
}

# Wait for a job to appear and then complete.
wait_for_job() {
  local name="$1" namespace="$2" timeout="${3:-5m}"
  log_info "Waiting for job/$name in namespace '$namespace'..."

  # Wait up to 2 minutes for the job object to be created by the chart/operator
  local deadline=$(( SECONDS + 120 ))
  until kubectl get job "$name" -n "$namespace" >/dev/null 2>&1; do
    [[ $SECONDS -lt $deadline ]] || die "Timed out waiting for job/$name to be created in $namespace"
    sleep 5
  done

  kubectl wait --for=condition=complete "job/$name" \
    -n "$namespace" --timeout="$timeout"
}

wait_for_pod_ready() {
  local name="$1" namespace="$2" timeout="${3:-120s}"
  log_info "Waiting for pod/$name in namespace '$namespace'..."
  kubectl wait "pod/$name" -n "$namespace" \
    --for=condition=Ready --timeout="$timeout"
}

# ── Helm helpers ──────────────────────────────────────────────────────────────
helm_repo_add() {
  local name="$1" url="$2"
  if helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    helm repo update "$name" >/dev/null
  else
    helm repo add "$name" "$url" >/dev/null
    helm repo update "$name" >/dev/null
  fi
}

# ── OpenBao port-forward ──────────────────────────────────────────────────────
_OPENBAO_PF_PID=""

start_openbao_portforward() {
  # Idempotent — do nothing if already running
  if [[ -n "${_OPENBAO_PF_PID:-}" ]] && kill -0 "$_OPENBAO_PF_PID" 2>/dev/null; then
    return
  fi

  log_info "Starting OpenBao port-forward (8200)..."
  kubectl -n openbao port-forward svc/openbao 8200:8200 \
    >/dev/null 2>&1 &
  _OPENBAO_PF_PID=$!

  # Wait for the port to respond to any HTTP request (no -f: 503 sealed is OK
  # here — we just want to confirm the tunnel is up).
  local deadline=$(( SECONDS + 15 ))
  until curl -s --max-time 2 http://127.0.0.1:8200/v1/sys/health >/dev/null 2>&1; do
    [[ $SECONDS -lt $deadline ]] || die "OpenBao port-forward did not become ready in time"
    sleep 1
  done

  # Auto-unseal if sealed (common after a host restart or a fresh cluster).
  local sealed
  sealed=$(curl -s http://127.0.0.1:8200/v1/sys/health \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sealed', True))" \
    2>/dev/null || echo "true")

  if [[ "${sealed,,}" == "true" ]]; then
    log_info "OpenBao is sealed — unsealing..."
    local unseal_key
    unseal_key=$(kubectl get secret openbao-unseal-keys -n openbao \
      -o jsonpath='{.data.unseal-key}' | base64 -d)
    kubectl exec -n openbao openbao-0 -- bao operator unseal "$unseal_key" >/dev/null
    # Wait for active state (health returns 200)
    deadline=$(( SECONDS + 15 ))
    until curl -sf http://127.0.0.1:8200/v1/sys/health >/dev/null 2>&1; do
      [[ $SECONDS -lt $deadline ]] || die "OpenBao did not become active after unseal"
      sleep 1
    done
    log_info "OpenBao unsealed"
  fi

  export BAO_ADDR="http://127.0.0.1:8200"
  export BAO_TOKEN
  BAO_TOKEN=$(kubectl get secret openbao-unseal-keys -n openbao \
    -o jsonpath='{.data.root-token}' | base64 -d)

  log_info "OpenBao port-forward ready"
}

stop_openbao_portforward() {
  if [[ -n "${_OPENBAO_PF_PID:-}" ]]; then
    kill "$_OPENBAO_PF_PID" 2>/dev/null || true
    _OPENBAO_PF_PID=""
  fi
}

# Returns 0 if the secret path exists in OpenBao, 1 otherwise.
# Requires start_openbao_portforward to have been called.
openbao_secret_exists() {
  local path="$1"
  bao kv get "secret/$path" >/dev/null 2>&1
}
