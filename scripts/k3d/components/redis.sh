#!/usr/bin/env bash
# scripts/components/redis.sh — OpsTree Redis operator + Sentinel HA cluster
#
# Deploy order (enforced here):
#   operator → password in OpenBao → ESO sync → volumes → replication → sentinel

install_redis() {
  log_step "Installing Redis (OpsTree Sentinel cluster)"
  require_commands helm kubectl bao openssl

  # ── Prerequisite checks ────────────────────────────────────────────────────
  local css_reason
  css_reason=$(kubectl get clustersecretstore openbao \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
  [[ "$css_reason" == "Valid" ]] \
    || die "ClusterSecretStore 'openbao' is not Valid (got: '${css_reason:-not found}'). Run: install.sh install eso"

  # ── OpsTree redis-operator ─────────────────────────────────────────────────
  log_info "Installing OpsTree redis-operator..."
  helm_repo_add ot-helm https://ot-container-kit.github.io/helm-charts/
  helm upgrade --install redis-operator ot-helm/redis-operator \
    --namespace ot-operators --create-namespace \
    --wait --timeout 3m
  wait_for_rollout deployment redis-operator ot-operators

  # ── Redis password ─────────────────────────────────────────────────────────
  create_namespace redis

  start_openbao_portforward

  if openbao_secret_exists "redis"; then
    log_info "Redis password already in OpenBao — skipping generation"
  else
    log_info "Generating Redis password..."
    local redis_password
    redis_password=$(openssl rand -base64 24 | tr -d '=/+' | head -c 32)
    bao kv put secret/redis password="$redis_password"
    log_info "Redis password stored in OpenBao at secret/redis"
  fi

  stop_openbao_portforward

  # ── ESO sync ───────────────────────────────────────────────────────────────
  log_info "Applying ExternalSecret for Redis password..."
  kubectl apply -f "${REPO_ROOT}/redis/k3d/externalsecret.yaml"

  log_info "Waiting for 'redis-secret' to be synced by ESO..."
  local deadline=$(( SECONDS + 60 ))
  while [[ $SECONDS -lt $deadline ]]; do
    local reason
    reason=$(kubectl get externalsecret redis-secret -n redis \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    if [[ "$reason" == "SecretSynced" ]]; then
      log_info "Secret 'redis-secret' synced"
      break
    fi
    sleep 5
  done
  [[ "$reason" == "SecretSynced" ]] \
    || die "ESO did not sync 'redis-secret' within 60 s. Check: kubectl describe externalsecret redis-secret -n redis"

  # ── Static PVs ────────────────────────────────────────────────────────────
  # Pre-create data directories with world-writable permissions before applying
  # PVs. DirectoryOrCreate creates dirs as root (0755); the Redis pod user
  # would then have no write access.
  log_info "Creating Redis data directories with correct permissions..."
  mkdir -p \
    "${REPO_ROOT}/mnt/redis/redis-replication-0" \
    "${REPO_ROOT}/mnt/redis/redis-replication-1" \
    "${REPO_ROOT}/mnt/redis/redis-replication-2"
  chmod 777 \
    "${REPO_ROOT}/mnt/redis/redis-replication-0" \
    "${REPO_ROOT}/mnt/redis/redis-replication-1" \
    "${REPO_ROOT}/mnt/redis/redis-replication-2"

  log_info "Applying Redis PersistentVolumes..."
  kubectl apply -f "${REPO_ROOT}/redis/k3d/volumes.yaml"

  # ── RedisReplication ───────────────────────────────────────────────────────
  log_info "Applying RedisReplication 'redis-replication'..."
  kubectl apply -f "${REPO_ROOT}/redis/k3d/replication.yaml"

  log_info "Waiting for StatefulSet 'redis-replication' to be Ready..."
  wait_for_rollout statefulset redis-replication redis 300s

  # ── RedisSentinel ──────────────────────────────────────────────────────────
  log_info "Applying RedisSentinel 'sentinel'..."
  kubectl apply -f "${REPO_ROOT}/redis/k3d/sentinel.yaml"

  # The OpsTree operator names the StatefulSet <cr-name>-sentinel, so a
  # RedisSentinel CR named 'sentinel' creates StatefulSet 'sentinel-sentinel'.
  log_info "Waiting for StatefulSet 'sentinel-sentinel' to be Ready..."
  wait_for_rollout statefulset sentinel-sentinel redis 120s

  log_info "Redis Sentinel cluster ready."
}

teardown_redis() {
  log_step "Tearing down Redis"

  kubectl delete -f "${REPO_ROOT}/redis/k3d/sentinel.yaml"     2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/redis/k3d/replication.yaml"  2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/redis/k3d/externalsecret.yaml" 2>/dev/null || true

  # Delete PVCs before PVs — PVCs are from StatefulSet volumeClaimTemplates
  # (not tracked by Helm) and keep PVs Bound, causing kubectl delete pv to hang.
  kubectl delete pvc \
    redis-replication-redis-replication-0 \
    redis-replication-redis-replication-1 \
    redis-replication-redis-replication-2 \
    -n redis --ignore-not-found 2>/dev/null || true
  for pv in redis-replication-0 redis-replication-1 redis-replication-2; do
    kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
  kubectl delete -f "${REPO_ROOT}/redis/k3d/volumes.yaml"      2>/dev/null || true

  log_info "Waiting for Redis pods to terminate..."
  kubectl wait pods --all -n redis --for=delete --timeout=120s 2>/dev/null || true

  kubectl delete namespace redis 2>/dev/null \
    && log_info "Namespace 'redis' removed" \
    || log_warn "Namespace 'redis' not found — skipping"

  helm uninstall redis-operator -n ot-operators 2>/dev/null \
    && log_info "OpsTree redis-operator removed" \
    || log_warn "redis-operator not found — skipping"

  kubectl delete namespace ot-operators 2>/dev/null || true
}
