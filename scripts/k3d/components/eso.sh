#!/usr/bin/env bash
# scripts/components/eso.sh — External Secrets Operator + ClusterSecretStore

install_eso() {
  log_step "Installing External Secrets Operator"
  require_commands helm kubectl

  log_info "Installing ESO via Helm..."
  helm_repo_add external-secrets https://charts.external-secrets.io
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    -f "${REPO_ROOT}/external-secrets-operator/k3d/values.yaml" \
    --wait --timeout 5m

  wait_for_rollout deployment external-secrets external-secrets

  log_info "Applying ClusterSecretStore 'openbao'..."
  kubectl apply -f "${REPO_ROOT}/external-secrets-operator/k3d/clustersecretstore.yaml"

  log_info "Waiting for ClusterSecretStore to become Valid..."
  local deadline=$(( SECONDS + 60 ))
  while [[ $SECONDS -lt $deadline ]]; do
    local reason
    reason=$(kubectl get clustersecretstore openbao \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    if [[ "$reason" == "Valid" ]]; then
      log_info "ClusterSecretStore 'openbao' is Valid"
      return
    fi
    sleep 5
  done
  die "ClusterSecretStore 'openbao' did not become Valid within 60 s. Check: kubectl describe clustersecretstore openbao"
}

teardown_eso() {
  log_step "Tearing down External Secrets Operator"

  kubectl delete -f "${REPO_ROOT}/external-secrets-operator/k3d/clustersecretstore.yaml" \
    2>/dev/null || true

  helm uninstall external-secrets -n external-secrets 2>/dev/null \
    && log_info "Helm release 'external-secrets' removed" \
    || log_warn "Helm release 'external-secrets' not found — skipping"

  kubectl delete namespace external-secrets 2>/dev/null \
    && log_info "Namespace 'external-secrets' removed" \
    || log_warn "Namespace 'external-secrets' not found — skipping"
}
