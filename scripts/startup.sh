#!/usr/bin/env bash
# scripts/startup.sh — recover the k3d stack after a host or cluster restart
#
# Usage: ./scripts/startup.sh
#
# Run this once after any host restart. It handles the steps that cannot be
# automated inside Kubernetes itself:
#
#   1. Verify the cluster API server is reachable
#   2. Delete kube-system pods stuck in ImagePullBackOff (transient DNS race at boot)
#   3. Wait for CoreDNS to be healthy
#   4. Unseal OpenBao (Shamir seal re-seals on every pod restart)
#   5. Wait for the ESO ClusterSecretStore to reconnect to OpenBao
#   6. Force-sync all ExternalSecrets so secrets are current before workloads start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── 1. Cluster reachable ──────────────────────────────────────────────────────
_check_cluster() {
  log_step "Checking cluster connectivity"
  local deadline=$(( SECONDS + 30 ))
  until kubectl cluster-info >/dev/null 2>&1; do
    [[ $SECONDS -lt $deadline ]] \
      || die "kubectl cannot reach the cluster after 30s — is k3d running?"
    log_info "Waiting for cluster API server..."
    sleep 3
  done
  log_info "Cluster reachable"
}

# ── 2. Fix kube-system ImagePullBackOff ───────────────────────────────────────
# At k3d startup, CoreDNS and other system pods sometimes get ImagePullBackOff
# because container network isn't ready when they first try to pull. Deleting
# the stuck pods forces a retry now that the network has settled.
_fix_kube_system_image_pull() {
  log_step "Checking kube-system pods"
  local stuck_pods
  stuck_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null \
    | awk '$3 ~ /ImagePullBackOff|ErrImagePull/ {print $1}' || true)

  if [[ -z "$stuck_pods" ]]; then
    log_info "No ImagePullBackOff pods in kube-system"
    return
  fi

  log_warn "Restarting stuck pods: $(echo "$stuck_pods" | tr '\n' ' ')"
  echo "$stuck_pods" | xargs kubectl delete pod -n kube-system --ignore-not-found >/dev/null
}

# ── 3. CoreDNS ────────────────────────────────────────────────────────────────
_wait_for_coredns() {
  log_step "Waiting for CoreDNS"
  local deadline=$(( SECONDS + 120 ))
  until kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null \
      | grep -q "1/1.*Running"; do
    [[ $SECONDS -lt $deadline ]] || die "CoreDNS did not become Ready within 120s"
    sleep 5
  done
  log_info "CoreDNS ready"
}

# ── 4. Unseal OpenBao ─────────────────────────────────────────────────────────
_unseal_openbao() {
  log_step "Unsealing OpenBao"

  local deadline=$(( SECONDS + 120 ))
  until kubectl get pod openbao-0 -n openbao --no-headers 2>/dev/null \
      | awk '{print $3}' | grep -qx "Running"; do
    [[ $SECONDS -lt $deadline ]] || die "openbao-0 did not reach Running within 120s"
    sleep 5
  done

  local sealed
  sealed=$(kubectl exec -n openbao openbao-0 -- \
    bao status -format=json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['sealed'])" \
    2>/dev/null || echo "true")

  if [[ "${sealed,,}" == "false" ]]; then
    log_info "OpenBao is already unsealed"
    return
  fi

  log_info "Unsealing..."
  local unseal_key
  unseal_key=$(kubectl get secret openbao-unseal-keys -n openbao \
    -o jsonpath='{.data.unseal-key}' | base64 -d)
  kubectl exec -n openbao openbao-0 -- bao operator unseal "$unseal_key" >/dev/null
  log_info "OpenBao unsealed"
}

# ── 5. ESO ClusterSecretStore ─────────────────────────────────────────────────
_wait_for_eso() {
  log_step "Waiting for ESO ClusterSecretStore"

  # ClusterSecretStore columns (--no-headers): NAME AGE STATUS CAPABILITIES READY
  # READY is column 5.

  # Give ESO up to 30s to reconnect naturally after OpenBao is unsealed
  local deadline=$(( SECONDS + 30 ))
  until kubectl get clustersecretstore openbao --no-headers 2>/dev/null \
      | awk '{print $5}' | grep -qx "True"; do
    if [[ $SECONDS -ge $deadline ]]; then
      log_warn "Not ready after 30s — restarting ESO to clear backoff..."
      kubectl rollout restart deployment/external-secrets -n external-secrets >/dev/null
      # Don't block on rollout status — the old pod keeps serving while the new
      # one starts. Just wait for the store itself to become Ready below.
      break
    fi
    sleep 5
  done

  # Final wait (covers both the natural path and the post-restart path)
  deadline=$(( SECONDS + 90 ))
  until kubectl get clustersecretstore openbao --no-headers 2>/dev/null \
      | awk '{print $5}' | grep -qx "True"; do
    [[ $SECONDS -lt $deadline ]] \
      || die "ClusterSecretStore did not become Ready within 90s"
    sleep 5
  done

  log_info "ESO ClusterSecretStore ready"
}

# ── 6. Force-sync ExternalSecrets ────────────────────────────────────────────
_sync_external_secrets() {
  log_step "Syncing ExternalSecrets"
  local timestamp
  timestamp="$(date +%s)"

  local namespaces
  namespaces=$(kubectl get externalsecrets -A --no-headers 2>/dev/null \
    | awk '{print $1}' | sort -u || true)

  if [[ -z "$namespaces" ]]; then
    log_info "No ExternalSecrets found"
    return
  fi

  for ns in $namespaces; do
    local count
    count=$(kubectl get externalsecrets -n "$ns" --no-headers 2>/dev/null | wc -l)
    log_info "Force-syncing ${count} ExternalSecret(s) in namespace '${ns}'..."
    kubectl annotate externalsecrets -n "$ns" --all \
      reconcile.external-secrets.io/force-sync="$timestamp" \
      --overwrite >/dev/null
  done

  # Wait for all ExternalSecrets across all namespaces to report Ready=True.
  # With -A output the READY column is $7 (NAMESPACE NAME STORETYPE STORE REFRESH STATUS READY LAST_SYNC).
  local deadline=$(( SECONDS + 60 ))
  local not_ready
  while true; do
    not_ready=$(kubectl get externalsecrets -A --no-headers 2>/dev/null \
      | awk '$7 != "True" {print $1 "/" $2}' || true)
    [[ -z "$not_ready" ]] && break
    if [[ $SECONDS -ge $deadline ]]; then
      log_warn "The following ExternalSecrets did not sync within 60s:"
      echo "$not_ready" | sed 's/^/  /'
      return
    fi
    sleep 5
  done

  log_info "All ExternalSecrets synced"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  require_commands kubectl bao python3

  log_step "Stack startup recovery"

  _check_cluster
  _fix_kube_system_image_pull
  _wait_for_coredns
  _unseal_openbao
  _wait_for_eso
  _sync_external_secrets

  echo ""
  log_info "Stack recovery complete."
}

main "$@"
