#!/usr/bin/env bash
# scripts/components/postgres.sh — CloudNativePG operator + pg-cluster

install_postgres() {
  log_step "Installing PostgreSQL (CloudNativePG)"
  require_commands helm kubectl

  # ── Prerequisite checks ────────────────────────────────────────────────────
  # OpenBao must be unsealed so the unseal-keys Secret exists (used by other
  # components later); postgres itself does not use ESO but sits in the same
  # dependency chain.
  kubectl get secret openbao-unseal-keys -n openbao >/dev/null 2>&1 \
    || die "OpenBao does not appear to be initialized. Run: install.sh install openbao"

  # ── CNPG operator ──────────────────────────────────────────────────────────
  log_info "Installing CloudNativePG operator..."
  helm_repo_add cnpg https://cloudnative-pg.github.io/charts
  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system --create-namespace \
    --wait --timeout 3m
  wait_for_rollout deployment cnpg-cloudnative-pg cnpg-system

  # ── Cluster ────────────────────────────────────────────────────────────────
  create_namespace postgres

  log_info "Applying StorageClass 'local-path-retain'..."
  kubectl apply -f "${REPO_ROOT}/postgres/k3d/storageclass.yaml"

  log_info "Applying PostgreSQL cluster 'pg-cluster'..."
  kubectl apply -f "${REPO_ROOT}/postgres/k3d/cluster.yaml"

  log_info "Waiting for at least one PostgreSQL instance to be Ready (up to 10 min)..."
  local deadline=$(( SECONDS + 600 ))
  local ready=0
  while [[ $SECONDS -lt $deadline ]]; do
    ready=$(kubectl get cluster pg-cluster -n postgres \
      -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)
    if [[ "${ready:-0}" -ge 1 ]]; then
      log_info "PostgreSQL cluster has ${ready} ready instance(s)"
      break
    fi
    log_info "  waiting... (${ready:-0} ready)"
    sleep 15
  done
  [[ "${ready:-0}" -ge 1 ]] \
    || die "PostgreSQL cluster did not become ready within 10 minutes"

  log_info "Applying PgBouncer pooler..."
  kubectl apply -f "${REPO_ROOT}/postgres/k3d/pooler.yaml"

  log_info "PostgreSQL ready."
}

teardown_postgres() {
  log_step "Tearing down PostgreSQL"

  kubectl delete -f "${REPO_ROOT}/postgres/k3d/pooler.yaml"  2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/postgres/k3d/cluster.yaml" 2>/dev/null || true

  # Wait for pods to terminate before deleting the namespace
  log_info "Waiting for PostgreSQL pods to terminate..."
  kubectl wait pods --all -n postgres \
    --for=delete --timeout=120s 2>/dev/null || true

  kubectl delete namespace postgres 2>/dev/null \
    && log_info "Namespace 'postgres' removed" \
    || log_warn "Namespace 'postgres' not found — skipping"

  helm uninstall cnpg -n cnpg-system 2>/dev/null \
    && log_info "CNPG operator removed" \
    || log_warn "CNPG operator not found — skipping"

  kubectl delete namespace cnpg-system 2>/dev/null || true
}
