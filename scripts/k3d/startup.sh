#!/usr/bin/env bash
# scripts/k3d/startup.sh — recover the k3d stack after a host or cluster restart
#
# Usage: ./scripts/k3d/startup.sh
#
# Run this once after any host restart. It handles the steps that cannot be
# automated inside Kubernetes itself:
#
#   1. Fix k3d node DNS (Docker gateway DNS loses its upstream after host reboot)
#   2. Verify the cluster API server is reachable
#   3. Delete pods stuck in ImagePullBackOff across all namespaces
#   4. Wait for CoreDNS to be healthy
#   5. Fix Redis split-brain (all pods come up as master after restart)
#   6. Unseal OpenBao (Shamir seal re-seals on every pod restart)
#   7. Wait for the ESO ClusterSecretStore to reconnect to OpenBao
#   8. Force-sync all ExternalSecrets so secrets are current before workloads start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── 1. Fix k3d node DNS ───────────────────────────────────────────────────────
# Docker's embedded DNS (gateway IP) fails to forward to the host's upstream
# after a host reboot because the host uses systemd-resolved at 127.0.0.53
# (unreachable from inside containers). Patch each node's /etc/resolv.conf to
# use the real upstream directly. Reads the upstream from
# /run/systemd/resolve/resolv.conf; falls back to 8.8.8.8 if unavailable.
_fix_k3d_node_dns() {
  log_step "Fixing k3d node DNS"

  local upstream
  upstream=$(awk '/^nameserver/{print $2; exit}' /run/systemd/resolve/resolv.conf 2>/dev/null || true)
  if [[ -z "$upstream" ]]; then
    upstream="8.8.8.8"
    log_warn "Could not read upstream from systemd-resolved — falling back to $upstream"
  fi
  log_info "Upstream DNS: $upstream"

  local nodes
  nodes=$(docker ps --filter name=k3d- --format '{{.Names}}' \
    | grep -v 'serverlb' || true)

  if [[ -z "$nodes" ]]; then
    log_warn "No k3d node containers found — skipping DNS patch"
    return
  fi

  for node in $nodes; do
    docker exec "$node" sh -c \
      "printf 'nameserver %s\nsearch .\n' '$upstream' > /etc/resolv.conf" \
      2>/dev/null && log_info "Patched $node" || log_warn "Could not patch $node"
  done
}

# ── 2. Cluster reachable ──────────────────────────────────────────────────────
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

# ── 3. Fix ImagePullBackOff across all namespaces ─────────────────────────────
# At k3d startup, pods across any namespace can get stuck in ImagePullBackOff
# because node DNS isn't ready when they first try to pull. Deleting them forces
# a retry now that DNS is patched and the network has settled.
_fix_image_pull_backoff() {
  log_step "Checking for ImagePullBackOff pods (all namespaces)"
  local stuck
  stuck=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 ~ /ImagePullBackOff|ErrImagePull/ {print $1 "/" $2}' || true)

  if [[ -z "$stuck" ]]; then
    log_info "No ImagePullBackOff pods found"
    return
  fi

  log_warn "Restarting stuck pods: $(echo "$stuck" | tr '\n' ' ')"
  while IFS='/' read -r ns pod; do
    kubectl delete pod "$pod" -n "$ns" --ignore-not-found >/dev/null
  done <<< "$stuck"
}

# ── 4. CoreDNS ────────────────────────────────────────────────────────────────
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

# ── 5. Fix Redis split-brain ──────────────────────────────────────────────────
# After a host restart the Redis StatefulSet pods all come up as independent
# masters because the replication config is held in memory, not persisted to
# disk. We restore replication by pointing pods 1 and 2 at pod 0, then reset
# the Sentinels so they re-discover the restored topology.
_fix_redis_replication() {
  log_step "Checking Redis replication"

  # Wait for all Redis pods to be Running first
  local deadline=$(( SECONDS + 60 ))
  while kubectl get pods -n redis -l app=redis-replication --no-headers 2>/dev/null \
      | grep -qv "Running"; do
    [[ $SECONDS -lt $deadline ]] || break
    sleep 3
  done

  local redis_pass
  redis_pass=$(kubectl get secret redis-secret -n redis \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
  [[ -n "$redis_pass" ]] || { log_warn "Redis secret not found — skipping"; return; }

  local master_host="redis-replication-0.redis-replication-headless.redis.svc.cluster.local"

  # Check if pod 0 is already master with replicas attached
  local role
  role=$(kubectl exec -n redis redis-replication-0 -c redis-replication -- \
    redis-cli -a "$redis_pass" info replication 2>/dev/null \
    | awk -F: '/^role/{print $2}' | tr -d '[:space:]' || echo "unknown")

  if [[ "$role" != "master" ]]; then
    log_warn "redis-replication-0 is not master (role=$role) — manual intervention may be needed"
    return
  fi

  local slaves
  slaves=$(kubectl exec -n redis redis-replication-0 -c redis-replication -- \
    redis-cli -a "$redis_pass" info replication 2>/dev/null \
    | awk -F: '/^connected_slaves/{print $2}' | tr -d '[:space:]' || echo "0")

  if [[ "${slaves:-0}" -ge 2 ]]; then
    log_info "Redis replication healthy (master + ${slaves} replicas)"
  else
    log_warn "Split-brain detected (connected_slaves=${slaves:-0}) — restoring replication"
    for i in 1 2; do
      if kubectl get pod redis-replication-$i -n redis >/dev/null 2>&1; then
        kubectl exec -n redis redis-replication-$i -c redis-replication -- \
          redis-cli -a "$redis_pass" REPLICAOF "$master_host" 6379 >/dev/null 2>&1 \
          && log_info "redis-replication-$i → replica of pod 0" \
          || log_warn "Could not set redis-replication-$i as replica"
      fi
    done
    # Reset Sentinels so they re-discover the restored master
    for i in 0 1 2; do
      if kubectl get pod sentinel-sentinel-$i -n redis >/dev/null 2>&1; then
        kubectl exec -n redis sentinel-sentinel-$i -- \
          redis-cli -p 26379 SENTINEL RESET myMaster >/dev/null 2>&1 \
          && log_info "sentinel-sentinel-$i reset" \
          || log_warn "Could not reset sentinel-sentinel-$i"
      fi
    done
    log_info "Redis replication restored"
  fi
}

# ── 6. Unseal OpenBao ─────────────────────────────────────────────────────────
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

# ── 7. ESO ClusterSecretStore ─────────────────────────────────────────────────
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

# ── 8. Force-sync ExternalSecrets ────────────────────────────────────────────
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
  require_commands kubectl bao python3 docker

  log_step "Stack startup recovery"

  _fix_k3d_node_dns
  _check_cluster
  _fix_image_pull_backoff
  _wait_for_coredns
  _fix_redis_replication
  _unseal_openbao
  _wait_for_eso
  _sync_external_secrets

  echo ""
  log_info "Stack recovery complete."
}

main "$@"
