#!/usr/bin/env bash
# scripts/components/openbao.sh — OpenBao standalone deployment
#
# Install order:
#   1. Helm install (static PV first)
#   2. Init (once only — keys stored in k8s Secret)
#   3. Unseal
#   4. Configure: KV-v2, Kubernetes auth, ESO policy + role

install_openbao() {
  log_step "Installing OpenBao"
  require_commands helm kubectl bao python3

  create_namespace openbao

  # Pre-create the data directory with world-writable permissions BEFORE
  # applying the PV. If we let DirectoryOrCreate do it, kubelet creates the
  # directory as root (0755) and the OpenBao pod (uid 100) cannot write to it.
  log_info "Creating OpenBao data directory with correct permissions..."
  mkdir -p "${REPO_ROOT}/mnt/openbao/data"
  chmod 777 "${REPO_ROOT}/mnt/openbao/data"

  log_info "Applying OpenBao PersistentVolume..."
  kubectl apply -f "${REPO_ROOT}/openbao/k3d/volumes.yaml"

  log_info "Installing OpenBao via Helm..."
  helm_repo_add openbao https://openbao.github.io/openbao-helm
  helm upgrade --install openbao openbao/openbao \
    --namespace openbao \
    -f "${REPO_ROOT}/openbao/k3d/values.yaml" \
    --wait --timeout 3m

  wait_for_pod_ready openbao-0 openbao 120s

  _openbao_init
  _openbao_unseal
  _openbao_configure

  stop_openbao_portforward
  log_info "OpenBao ready."
}

# ── Init ──────────────────────────────────────────────────────────────────────
_openbao_init() {
  # Check actual init state from OpenBao's storage backend.
  # The k8s Secret alone is not reliable: it lives in the namespace and gets
  # deleted when the cluster is torn down, but mnt/openbao/data/ persists.
  # bao status exits 2 when sealed (normal) — suppress that with || true.
  local bao_status initialized
  bao_status=$(kubectl exec -n openbao openbao-0 -- \
    bao status -format=json 2>/dev/null || true)
  initialized=$(echo "$bao_status" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('initialized', False))" \
    2>/dev/null || echo "false")

  if [[ "${initialized,,}" == "true" ]]; then
    if kubectl get secret openbao-unseal-keys -n openbao >/dev/null 2>&1; then
      log_info "OpenBao already initialized — skipping init"
      return
    fi
    # Initialized on disk but k8s Secret is missing: the cluster was deleted
    # without running teardown, so the Secret was lost with the namespace.
    die "OpenBao is already initialized on disk but 'openbao-unseal-keys' is missing.\nThe cluster was likely recreated without running teardown first.\nWipe the stale data and retry:\n  rm -rf mnt/openbao/data\n  ./scripts/k3d/install.sh install openbao"
  fi

  log_info "Initializing OpenBao (1 key share, threshold 1)..."
  local init_json
  init_json=$(kubectl exec -n openbao openbao-0 -- \
    bao operator init -key-shares=1 -key-threshold=1 -format=json)

  local unseal_key root_token
  unseal_key=$(echo "$init_json" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
  root_token=$(echo "$init_json" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['root_token'])")

  kubectl create secret generic openbao-unseal-keys \
    --namespace openbao \
    --from-literal=unseal-key="$unseal_key" \
    --from-literal=root-token="$root_token"

  log_info "OpenBao initialized. Keys stored in secret 'openbao-unseal-keys' (namespace openbao)."
}

# ── Unseal ────────────────────────────────────────────────────────────────────
_openbao_unseal() {
  local sealed
  sealed=$(kubectl exec -n openbao openbao-0 -- \
    bao status -format=json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['sealed'])" \
    2>/dev/null || echo "true")

  if [[ "${sealed,,}" == "false" ]]; then
    log_info "OpenBao is already unsealed"
    return
  fi

  log_info "Unsealing OpenBao..."
  local unseal_key
  unseal_key=$(kubectl get secret openbao-unseal-keys -n openbao \
    -o jsonpath='{.data.unseal-key}' | base64 -d)

  kubectl exec -n openbao openbao-0 -- bao operator unseal "$unseal_key"
}

# ── Configure (idempotent) ────────────────────────────────────────────────────
_openbao_configure() {
  start_openbao_portforward

  # KV-v2
  if bao secrets list -format=json 2>/dev/null \
      | python3 -c "import json,sys; print('secret/' in json.load(sys.stdin))" \
      | grep -qx True; then
    log_info "KV-v2 secrets engine already enabled"
  else
    log_info "Enabling KV-v2 secrets engine at path 'secret'..."
    bao secrets enable -path=secret kv-v2
  fi

  # Kubernetes auth
  if bao auth list -format=json 2>/dev/null \
      | python3 -c "import json,sys; print('kubernetes/' in json.load(sys.stdin))" \
      | grep -qx True; then
    log_info "Kubernetes auth already enabled"
  else
    log_info "Enabling Kubernetes auth..."
    bao auth enable kubernetes
    bao write auth/kubernetes/config \
      kubernetes_host="https://kubernetes.default.svc"
  fi

  # ESO read policy
  log_info "Writing 'external-secrets' policy..."
  bao policy write external-secrets - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
EOF

  # ESO service-account role
  log_info "Binding 'external-secrets' service account to policy..."
  bao write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets \
    ttl=1h

  log_info "OpenBao configuration complete"
}

# ── Teardown ──────────────────────────────────────────────────────────────────
teardown_openbao() {
  log_step "Tearing down OpenBao"

  helm uninstall openbao -n openbao 2>/dev/null \
    && log_info "Helm release 'openbao' removed" \
    || log_warn "Helm release 'openbao' not found — skipping"

  kubectl delete secret openbao-unseal-keys -n openbao 2>/dev/null \
    && log_info "Secret 'openbao-unseal-keys' removed" \
    || true

  # Delete the PVC first (it's created by the StatefulSet volumeClaimTemplate,
  # not tracked by Helm). The PV won't release until its PVC is gone, and
  # kubectl delete pv hangs on the kubernetes.io/pv-protection finalizer while
  # the PVC still exists.
  kubectl delete pvc data-openbao-0 -n openbao --ignore-not-found 2>/dev/null || true
  # Belt-and-suspenders: patch the PV finalizer away so the delete never hangs
  # regardless of PVC state (e.g. pod stuck Terminating).
  kubectl patch pv openbao-data -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/openbao/k3d/volumes.yaml" 2>/dev/null || true

  kubectl delete namespace openbao 2>/dev/null \
    && log_info "Namespace 'openbao' removed" \
    || log_warn "Namespace 'openbao' not found — skipping"

  # Persistent data survives teardown (Retain policy). Prompt to wipe it so
  # a subsequent install.sh install openbao starts with a clean slate.
  local data_dir="${REPO_ROOT}/mnt/openbao/data"
  if [[ -d "$data_dir" && -n "$(ls -A "$data_dir" 2>/dev/null)" ]]; then
    echo
    read -rp "Wipe OpenBao data directory (${data_dir})? Required for a clean reinstall. [y/N]: " _confirm
    if [[ "${_confirm,,}" == "y" ]]; then
      sudo rm -rf "$data_dir"
      log_info "OpenBao data directory wiped."
    else
      log_warn "Data directory preserved. Run 'rm -rf ${data_dir}' before reinstalling."
    fi
  fi
}
