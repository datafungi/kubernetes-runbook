#!/usr/bin/env bash
# scripts/components/airflow.sh — Apache Airflow 3.2.0 (CeleryExecutor)
#
# DAG modes
#   local    — DAGs served from mnt/airflow/dags/ via a hostPath PVC
#   gitsync  — DAGs cloned via git-sync sidecar (SSH deploy key)
#
# Environment variables (all optional — script prompts for required ones if unset):
#   AIRFLOW_DAGS_MODE                  local | gitsync
#   AIRFLOW_DAGS_REPO                  (gitsync) full SSH URL
#   AIRFLOW_GIT_SSH_KEY_FILE           (gitsync) path to SSH private key file
#   AIRFLOW_DAGS_BRANCH                (gitsync, default: main)
#   AIRFLOW_DAGS_SUBPATH               (gitsync, default: "")
#   AIRFLOW_GITSYNC_KNOWN_HOSTS_FILE   (gitsync) path to known_hosts file — overrides default
#   AIRFLOW_GITSYNC_KNOWN_HOST         (gitsync) inline known_hosts string — overrides default

# GitHub's RSA host key (bundled default for gitsync mode)
_GITHUB_KNOWN_HOST='github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='

# Runtime state (set during install, used across helper functions)
_AIRFLOW_DAGS_MODE=""
_AIRFLOW_DAGS_REPO=""
_AIRFLOW_DAGS_BRANCH="main"
_AIRFLOW_DAGS_SUBPATH=""
_AIRFLOW_KNOWN_HOST=""
_AIRFLOW_GIT_KEY_IN_OPENBAO=false

# ── Entry point ───────────────────────────────────────────────────────────────
install_airflow() {
  log_step "Installing Apache Airflow 3.2.0"
  require_commands helm kubectl python3 openssl bao

  trap 'stop_openbao_portforward' RETURN

  _airflow_check_prereqs
  _airflow_determine_dag_mode
  _airflow_gather_gitsync_params   # no-op for local mode

  # Port-forward is needed for all remaining secret steps
  start_openbao_portforward

  create_namespace airflow

  _airflow_setup_postgres
  _airflow_setup_secrets
  _airflow_setup_storage
  _airflow_apply_externalsecrets
  _airflow_helm_install
  _airflow_wait_for_rollout

  log_info ""
  log_info "Airflow is ready."
  log_info "  UI:  kubectl -n airflow port-forward svc/airflow-api-server 8080:8080"
  log_info "       then open http://localhost:8080"
  if [[ "$_AIRFLOW_DAGS_MODE" == "local" ]]; then
    log_info "  DAGs: drop .py files into ${REPO_ROOT}/mnt/airflow/dags/"
  fi
}

# ── 1. Prerequisite checks ────────────────────────────────────────────────────
_airflow_check_prereqs() {
  log_step "Checking prerequisites"

  # ESO ClusterSecretStore
  local css_reason
  css_reason=$(kubectl get clustersecretstore openbao \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
  [[ "$css_reason" == "Valid" ]] \
    || die "ClusterSecretStore 'openbao' is not Valid (got: '${css_reason:-not found}'). Run: install.sh install eso"

  # PostgreSQL
  local pg_ready
  pg_ready=$(kubectl get cluster pg-cluster -n postgres \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)
  [[ "${pg_ready:-0}" -ge 1 ]] \
    || die "PostgreSQL cluster 'pg-cluster' is not ready. Run: install.sh install postgres"

  # Redis
  local redis_ready
  redis_ready=$(kubectl get statefulset redis-replication -n redis \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [[ "${redis_ready:-0}" -ge 1 ]] \
    || die "Redis StatefulSet 'redis-replication' is not ready. Run: install.sh install redis"

  log_info "All prerequisites satisfied"
}

# ── 2. DAG mode selection ─────────────────────────────────────────────────────
_airflow_determine_dag_mode() {
  _AIRFLOW_DAGS_MODE="${AIRFLOW_DAGS_MODE:-}"

  if [[ -z "$_AIRFLOW_DAGS_MODE" ]]; then
    echo
    echo "How should Airflow load DAGs?"
    echo "  1) local    — serve DAGs from mnt/airflow/dags/ on the host (no git required)"
    echo "  2) gitsync  — clone DAGs from a git repository via git-sync sidecar (SSH)"
    echo
    local choice
    read -rp "Choice [1/2]: " choice
    case "$choice" in
      1) _AIRFLOW_DAGS_MODE=local ;;
      2) _AIRFLOW_DAGS_MODE=gitsync ;;
      *) die "Invalid choice '${choice}'. Enter 1 or 2." ;;
    esac
  fi

  case "$_AIRFLOW_DAGS_MODE" in
    local|gitsync) log_info "DAG mode: $_AIRFLOW_DAGS_MODE" ;;
    *) die "AIRFLOW_DAGS_MODE must be 'local' or 'gitsync', got: '$_AIRFLOW_DAGS_MODE'" ;;
  esac
}

# ── 3. Gather gitsync parameters ──────────────────────────────────────────────
_airflow_gather_gitsync_params() {
  [[ "$_AIRFLOW_DAGS_MODE" == "gitsync" ]] || return 0

  # Repo URL (required)
  _AIRFLOW_DAGS_REPO="${AIRFLOW_DAGS_REPO:-}"
  if [[ -z "$_AIRFLOW_DAGS_REPO" ]]; then
    read -rp "DAG repository SSH URL (e.g. git@github.com:org/dags.git): " _AIRFLOW_DAGS_REPO
  fi
  [[ -n "$_AIRFLOW_DAGS_REPO" ]] || die "DAG repository URL is required for gitsync mode"

  # Optional params
  _AIRFLOW_DAGS_BRANCH="${AIRFLOW_DAGS_BRANCH:-main}"
  _AIRFLOW_DAGS_SUBPATH="${AIRFLOW_DAGS_SUBPATH:-}"

  # Known hosts: file overrides inline overrides bundled default
  if [[ -n "${AIRFLOW_GITSYNC_KNOWN_HOSTS_FILE:-}" ]]; then
    [[ -f "$AIRFLOW_GITSYNC_KNOWN_HOSTS_FILE" ]] \
      || die "AIRFLOW_GITSYNC_KNOWN_HOSTS_FILE not found: $AIRFLOW_GITSYNC_KNOWN_HOSTS_FILE"
    _AIRFLOW_KNOWN_HOST=$(cat "$AIRFLOW_GITSYNC_KNOWN_HOSTS_FILE")
    log_info "Using known hosts from file: $AIRFLOW_GITSYNC_KNOWN_HOSTS_FILE"
  elif [[ -n "${AIRFLOW_GITSYNC_KNOWN_HOST:-}" ]]; then
    _AIRFLOW_KNOWN_HOST="$AIRFLOW_GITSYNC_KNOWN_HOST"
    log_info "Using known host from AIRFLOW_GITSYNC_KNOWN_HOST"
  else
    _AIRFLOW_KNOWN_HOST="$_GITHUB_KNOWN_HOST"
    log_info "Using bundled GitHub known host fingerprint"
  fi

  # SSH key file (required — but may already be in OpenBao)
  # We can't check OpenBao yet (portforward not started), so resolve file path
  # now; the existence check against OpenBao happens in _airflow_setup_secrets.
  local key_file="${AIRFLOW_GIT_SSH_KEY_FILE:-}"
  if [[ -z "$key_file" ]]; then
    read -rp "Path to git deploy key (e.g. ~/.ssh/dags-deploy-key): " key_file
  fi
  # Expand ~ manually (read does not expand it)
  key_file="${key_file/#\~/$HOME}"
  export AIRFLOW_GIT_SSH_KEY_FILE="$key_file"
}

# ── 4. PostgreSQL — create airflow DB + user ──────────────────────────────────
_airflow_setup_postgres() {
  log_step "Setting up PostgreSQL for Airflow"

  if openbao_secret_exists "airflow/metadata-db"; then
    log_info "PostgreSQL credentials already in OpenBao — skipping"
    return
  fi

  log_info "Generating Airflow database password..."
  local pg_password
  pg_password=$(openssl rand -base64 24 | tr -d '=/+' | head -c 32)

  # Dynamically locate the CNPG primary pod
  log_info "Detecting PostgreSQL primary pod..."
  local primary_pod
  primary_pod=$(kubectl get pod -n postgres \
    -l "cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$primary_pod" ]] \
    || die "No pod with label cnpg.io/instanceRole=primary found in namespace 'postgres'"
  log_info "Primary pod: $primary_pod"

  log_info "Creating Airflow user in PostgreSQL..."
  # Use DO block so the statement is idempotent: create if absent, else update password.
  kubectl exec -n postgres "$primary_pod" -- \
    psql -U postgres -c \
    "DO \$\$ BEGIN
       CREATE USER airflow WITH PASSWORD '${pg_password}';
     EXCEPTION WHEN duplicate_object THEN
       ALTER USER airflow WITH PASSWORD '${pg_password}';
     END \$\$;" \
    >/dev/null

  log_info "Creating Airflow database (if absent)..."
  # Check existence before creating — CREATE DATABASE cannot run inside a transaction.
  local db_exists
  db_exists=$(kubectl exec -n postgres "$primary_pod" -- \
    psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='airflow'" 2>/dev/null || true)
  if [[ "${db_exists:-}" != "1" ]]; then
    kubectl exec -n postgres "$primary_pod" -- \
      psql -U postgres -c "CREATE DATABASE airflow OWNER airflow;" >/dev/null
    log_info "Database 'airflow' created"
  else
    log_info "Database 'airflow' already exists — skipping"
  fi

  log_info "Storing metadata-db credentials in OpenBao..."
  bao kv put secret/airflow/metadata-db \
    user="airflow" \
    password="$pg_password"

  log_info "PostgreSQL setup complete"
}

# ── 5. Airflow secrets ────────────────────────────────────────────────────────
_airflow_setup_secrets() {
  log_step "Generating Airflow secrets"

  # Fernet key
  if openbao_secret_exists "airflow/fernet-key"; then
    log_info "Fernet key already in OpenBao — skipping"
  else
    log_info "Generating Fernet key..."
    local fernet_key
    # Fernet key = 32 random bytes, URL-safe base64-encoded.
    # Use stdlib only (no third-party 'cryptography' package required).
    fernet_key=$(python3 -c \
      "import os, base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())")
    bao kv put secret/airflow/fernet-key fernet-key="$fernet_key"
    log_info "Fernet key stored"
  fi

  # API + JWT secrets
  if openbao_secret_exists "airflow/api"; then
    log_info "API/JWT secrets already in OpenBao — skipping"
  else
    log_info "Generating API server and JWT secrets..."
    local api_secret jwt_secret
    api_secret=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    jwt_secret=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    bao kv put secret/airflow/api \
      api-secret-key="$api_secret" \
      jwt-secret="$jwt_secret"
    log_info "API/JWT secrets stored"
  fi

  # Git SSH key (gitsync mode only)
  if [[ "$_AIRFLOW_DAGS_MODE" != "gitsync" ]]; then return; fi

  if openbao_secret_exists "airflow/git"; then
    log_info "Git SSH key already in OpenBao — skipping"
    _AIRFLOW_GIT_KEY_IN_OPENBAO=true
    return
  fi

  local key_file="$AIRFLOW_GIT_SSH_KEY_FILE"
  [[ -f "$key_file" ]] \
    || die "SSH key file not found: '$key_file'. Set AIRFLOW_GIT_SSH_KEY_FILE or re-run."

  log_info "Storing git SSH key in OpenBao (reading from $key_file)..."
  # Use @file syntax so bao reads the key content directly, preserving newlines.
  bao kv put secret/airflow/git private-key=@"$key_file"
  log_info "Git SSH key stored"
}

# ── 6. Storage manifests ──────────────────────────────────────────────────────
_airflow_setup_storage() {
  log_step "Setting up Airflow storage"

  log_info "Creating host directories..."
  mkdir -p \
    "${REPO_ROOT}/mnt/airflow/logs" \
    "${REPO_ROOT}/mnt/airflow/dags"

  log_info "Applying log PV + PVC..."
  kubectl apply -f "${REPO_ROOT}/airflow/k3d/logs-storage.yaml"

  if [[ "$_AIRFLOW_DAGS_MODE" == "local" ]]; then
    log_info "Applying DAG PV + PVC (local mode)..."
    kubectl apply -f "${REPO_ROOT}/airflow/k3d/dags-storage.yaml"
  fi
}

# ── 7. ExternalSecrets ────────────────────────────────────────────────────────
_airflow_apply_externalsecrets() {
  log_step "Applying ExternalSecrets"

  local es_dir="${REPO_ROOT}/airflow/k3d/externalsecrets"

  kubectl apply -f "${es_dir}/fernet-key.yaml"
  kubectl apply -f "${es_dir}/api-secret.yaml"
  kubectl apply -f "${es_dir}/jwt-secret.yaml"
  kubectl apply -f "${es_dir}/metadata-db.yaml"
  kubectl apply -f "${es_dir}/celery.yaml"
  kubectl apply -f "${es_dir}/result-backend.yaml"

  local expected=6
  if [[ "$_AIRFLOW_DAGS_MODE" == "gitsync" ]]; then
    kubectl apply -f "${es_dir}/git.yaml"
    expected=7
  fi

  log_info "Waiting for all ${expected} ExternalSecrets to sync (up to 5 min)..."
  local deadline=$(( SECONDS + 300 ))
  while [[ $SECONDS -lt $deadline ]]; do
    local synced
    # grep -c always prints a count; use || true so a zero-match exit-1 doesn't
    # trigger || echo which would produce "0\n0" and break the -ge comparison.
    synced=$(kubectl get externalsecrets -n airflow \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null \
      | tr ' ' '\n' | grep -c "^SecretSynced$" || true)
    if [[ "${synced:-0}" -ge "$expected" ]]; then
      log_info "All ${expected} ExternalSecrets synced"
      return
    fi
    log_info "  synced: ${synced:-0}/${expected} — waiting..."
    sleep 10
  done
  die "ExternalSecrets did not all sync within 5 minutes. Check: kubectl get externalsecrets -n airflow"
}

# ── 8. Helm install ───────────────────────────────────────────────────────────
_airflow_helm_install() {
  log_step "Installing Airflow via Helm (chart 1.21.0)"

  helm_repo_add apache-airflow https://airflow.apache.org

  local -a cmd=(
    helm upgrade --install airflow apache-airflow/airflow
    --namespace airflow
    --version 1.21.0
    -f "${REPO_ROOT}/airflow/k3d/values.yaml"
    -f "${REPO_ROOT}/airflow/k3d/values-${_AIRFLOW_DAGS_MODE}.yaml"
    --timeout 10m
  )

  if [[ "$_AIRFLOW_DAGS_MODE" == "gitsync" ]]; then
    cmd+=(
      --set "dags.gitSync.repo=${_AIRFLOW_DAGS_REPO}"
      --set "dags.gitSync.branch=${_AIRFLOW_DAGS_BRANCH}"
      --set "dags.gitSync.subPath=${_AIRFLOW_DAGS_SUBPATH}"
    )

    # knownHosts is multi-line — write to a temp YAML overlay and -f it
    local kh_file
    kh_file=$(mktemp /tmp/airflow-known-hosts-XXXXXX.yaml)
    # shellcheck disable=SC2064
    trap "rm -f '${kh_file}'; stop_openbao_portforward" RETURN

    # Indent each line by 6 spaces to fit inside the dags.gitSync.knownHosts scalar
    local indented
    indented=$(printf '%s' "$_AIRFLOW_KNOWN_HOST" | sed 's/^/      /')
    cat > "$kh_file" <<EOF
dags:
  gitSync:
    knownHosts: |
${indented}
EOF
    cmd+=(-f "$kh_file")
  fi

  "${cmd[@]}"
}

# ── 9. Wait for rollout ───────────────────────────────────────────────────────
_airflow_wait_for_rollout() {
  log_step "Waiting for Airflow rollout"

  # The migration job runs as a Helm pre-install hook and may complete (and be
  # cleaned up via hook-delete-policy) before this function is even called.
  # Give it a short window; if not found, assume it already succeeded (the
  # deployments below won't start until migration is done).
  log_info "Looking for database migration job (30 s window)..."
  local migration_job=""
  local deadline=$(( SECONDS + 30 ))
  while [[ $SECONDS -lt $deadline ]]; do
    migration_job=$(kubectl get jobs -n airflow \
      --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
      | grep -E 'migration|run-airflow' | head -1 || true)
    [[ -n "$migration_job" ]] && break
    sleep 3
  done

  if [[ -n "$migration_job" ]]; then
    wait_for_job "$migration_job" airflow 5m
  else
    log_info "Migration job already completed (cleaned up) — skipping wait"
  fi

  # create-user job may also finish quickly; treat as best-effort
  local create_user_deadline=$(( SECONDS + 60 ))
  while [[ $SECONDS -lt $create_user_deadline ]]; do
    kubectl get job airflow-create-user -n airflow >/dev/null 2>&1 && break
    sleep 3
  done
  if kubectl get job airflow-create-user -n airflow >/dev/null 2>&1; then
    wait_for_job airflow-create-user airflow 5m
  else
    log_info "create-user job already completed (cleaned up) — skipping wait"
  fi

  wait_for_rollout deployment  airflow-api-server    airflow
  wait_for_rollout deployment  airflow-scheduler     airflow
  wait_for_rollout deployment  airflow-dag-processor airflow
  wait_for_rollout statefulset airflow-triggerer     airflow   # StatefulSet in Airflow 3.x
  wait_for_rollout statefulset airflow-worker        airflow
}

# ── Teardown ──────────────────────────────────────────────────────────────────
teardown_airflow() {
  log_step "Tearing down Airflow"

  helm uninstall airflow -n airflow 2>/dev/null \
    && log_info "Helm release 'airflow' removed" \
    || log_warn "Helm release 'airflow' not found — skipping"

  local es_dir="${REPO_ROOT}/airflow/k3d/externalsecrets"
  kubectl delete -f "${es_dir}/" 2>/dev/null || true

  kubectl delete -f "${REPO_ROOT}/airflow/k3d/logs-storage.yaml" 2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/airflow/k3d/dags-storage.yaml" 2>/dev/null || true

  log_info "Waiting for Airflow pods to terminate..."
  kubectl wait pods --all -n airflow --for=delete --timeout=120s 2>/dev/null || true

  kubectl delete namespace airflow 2>/dev/null \
    && log_info "Namespace 'airflow' removed" \
    || log_warn "Namespace 'airflow' not found — skipping"

  # Offer to remove OpenBao secrets (non-reversible)
  echo
  read -rp "Remove Airflow secrets from OpenBao? [y/N]: " _confirm
  if [[ "${_confirm,,}" == "y" ]]; then
    trap 'stop_openbao_portforward' RETURN
    start_openbao_portforward
    for path in airflow/fernet-key airflow/api airflow/metadata-db airflow/git; do
      bao kv delete "secret/${path}" 2>/dev/null \
        && log_info "Deleted secret/${path}" \
        || log_warn "secret/${path} not found — skipping"
    done
  fi

  log_warn "Log and DAG data in mnt/airflow/ is preserved."
  log_warn "Remove manually if no longer needed: rm -rf ${REPO_ROOT}/mnt/airflow/"
}
