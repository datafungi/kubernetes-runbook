#!/usr/bin/env bash
# scripts/k3d/install.sh — k3d stack installer
#
# Usage:
#   ./scripts/k3d/install.sh install  <component|all>
#   ./scripts/k3d/install.sh teardown <component|all>
#
# Components (dependency order):
#   cluster   k3d cluster + local-retain StorageClass
#   openbao   OpenBao secret store (init, unseal, configure)
#   eso       External Secrets Operator + ClusterSecretStore
#   postgres  CloudNativePG operator + pg-cluster
#   redis     OpsTree redis-operator + Sentinel HA cluster
#   airflow   Apache Airflow 3.2.0 (CeleryExecutor)
#
# Environment variables consumed by individual components are documented in
# each scripts/k3d/components/<name>.sh file and in the top-level README.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export SCRIPT_DIR REPO_ROOT

# Load shared utilities
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Ordered list — install runs left-to-right, teardown runs right-to-left
readonly COMPONENTS=(cluster openbao eso postgres redis airflow)

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

${BOLD}Usage:${NC}
  $(basename "$0") install  <component|all>
  $(basename "$0") teardown <component|all>

${BOLD}Components:${NC}
  cluster   k3d cluster + local-retain StorageClass
  openbao   OpenBao (Helm + init + unseal + configure)
  eso       External Secrets Operator + ClusterSecretStore
  postgres  CloudNativePG operator + pg-cluster
  redis     OpsTree redis-operator + Sentinel HA cluster
  airflow   Apache Airflow 3.2.0 (CeleryExecutor)
  all       All of the above in dependency order

${BOLD}Examples:${NC}
  $(basename "$0") install all          # full stack
  $(basename "$0") install airflow      # Airflow only (prereqs must be running)
  $(basename "$0") teardown airflow     # remove Airflow
  $(basename "$0") teardown all         # full stack teardown (reverse order)

${BOLD}Airflow DAG mode environment variables:${NC}
  AIRFLOW_DAGS_MODE                  local | gitsync  (prompted if unset)
  AIRFLOW_DAGS_REPO                  (gitsync) SSH URL of the DAG repository
  AIRFLOW_GIT_SSH_KEY_FILE           (gitsync) path to SSH private key file
  AIRFLOW_DAGS_BRANCH                (gitsync, default: main)
  AIRFLOW_DAGS_SUBPATH               (gitsync, default: "")
  AIRFLOW_GITSYNC_KNOWN_HOSTS_FILE   (gitsync) known_hosts file — overrides built-in
  AIRFLOW_GITSYNC_KNOWN_HOST         (gitsync) inline known_hosts string — overrides built-in

EOF
}

# ── Component runner ──────────────────────────────────────────────────────────
run_component() {
  local command="$1" component="$2"
  local script="${SCRIPT_DIR}/components/${component}.sh"

  [[ -f "$script" ]] || die "Unknown component: '${component}'"

  # shellcheck disable=SC1090
  source "$script"

  "${command}_${component}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local command="${1:-}"
  local component="${2:-}"

  if [[ -z "$command" || -z "$component" ]]; then
    usage
    exit 1
  fi

  case "$command" in
    install|teardown) ;;
    help|--help|-h) usage; exit 0 ;;
    *) usage; die "Unknown command: '${command}'. Use 'install' or 'teardown'." ;;
  esac

  # Ensure OpenBao port-forward is always cleaned up on exit
  trap stop_openbao_portforward EXIT

  if [[ "$component" == "all" ]]; then
    if [[ "$command" == "install" ]]; then
      for c in "${COMPONENTS[@]}"; do
        run_component install "$c"
      done
    else
      # Teardown in reverse dependency order
      local reversed=()
      for (( i=${#COMPONENTS[@]}-1; i>=0; i-- )); do
        reversed+=("${COMPONENTS[$i]}")
      done
      for c in "${reversed[@]}"; do
        run_component teardown "$c"
      done
    fi
  else
    run_component "$command" "$component"
  fi
}

main "$@"
