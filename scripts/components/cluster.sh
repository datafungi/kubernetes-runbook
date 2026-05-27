#!/usr/bin/env bash
# scripts/components/cluster.sh — k3d cluster + local-retain StorageClass

install_cluster() {
  log_step "Installing k3d cluster"
  require_commands k3d kubectl docker

  if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "simple-cluster"; then
    log_warn "Cluster 'simple-cluster' already exists — skipping creation"
  else
    # Detect Tailscale: if active, create the Docker network with a reduced MTU
    # to prevent silent packet drops on inter-node traffic.
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
      log_info "Tailscale detected — creating Docker network 'k3dcluster' with MTU 1280"
      docker network create \
        --opt com.docker.network.driver.mtu=1280 \
        k3dcluster 2>/dev/null \
        || log_warn "Network 'k3dcluster' already exists — skipping"
    fi

    # config.yaml contains a __REPO_ROOT__ placeholder for the volume mount
    # path because k3d requires an absolute path and the repo location varies
    # per machine. Substitute it into a temp file before passing to k3d.
    local tmp_config
    tmp_config=$(mktemp /tmp/k3d-config-XXXXXX.yaml)
    # shellcheck disable=SC2064
    trap "rm -f '${tmp_config}'" RETURN
    sed "s|REPO_ROOT_PLACEHOLDER|${REPO_ROOT}|g" \
      "${REPO_ROOT}/setup/k3d/config.yaml" > "$tmp_config"

    log_info "Creating cluster..."
    k3d cluster create --config "$tmp_config"
  fi

  log_info "Applying local-retain StorageClass..."
  kubectl apply -f "${REPO_ROOT}/setup/k3d/storage.yaml"

  log_info "Waiting for all nodes to be Ready..."
  kubectl wait nodes --all --for=condition=Ready --timeout=120s

  log_info "Cluster ready."
  kubectl get nodes
}

teardown_cluster() {
  log_step "Tearing down k3d cluster"

  if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "simple-cluster"; then
    k3d cluster delete simple-cluster
    log_info "Cluster deleted"
  else
    log_warn "Cluster 'simple-cluster' not found — skipping"
  fi

  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "k3dcluster"; then
    docker network rm k3dcluster 2>/dev/null || true
    log_info "Docker network 'k3dcluster' removed"
  fi
}
