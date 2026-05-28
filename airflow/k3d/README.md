# Apache Airflow — k3d (Local Development)

CeleryExecutor deployment using the official Apache Airflow Helm chart (v1.21.0, Airflow 3.2.0).
DAGs are loaded via GitSync sidecar (SSH) **or** a local hostPath volume (no git required).
Logs are persisted to a shared hostPath PVC.
All secrets are stored in OpenBao and synchronized into the cluster by ESO.

## Files

| Path | Purpose |
|------|---------|
| `values.yaml` | Helm base values: CeleryExecutor, secrets refs, resource limits, log PVC |
| `values-gitsync.yaml` | DAG overlay: git-sync sidecar (SSH) |
| `values-local.yaml` | DAG overlay: hostPath PVC (`mnt/airflow/dags/`) |
| `externalsecrets/fernet-key.yaml` | ESO: fernet key |
| `externalsecrets/api-secret.yaml` | ESO: API server session key |
| `externalsecrets/jwt-secret.yaml` | ESO: JWT signing key |
| `externalsecrets/metadata-db.yaml` | ESO: PostgreSQL connection strings (templated) |
| `externalsecrets/celery.yaml` | ESO: Redis Sentinel broker URL (templated) |
| `externalsecrets/git.yaml` | ESO: git SSH deploy key (gitsync mode only) |
| `logs-storage.yaml` | PV + PVC for Airflow logs (`mnt/airflow/logs/`, RWX) |
| `dags-storage.yaml` | PV + PVC for DAGs in local mode (`mnt/airflow/dags/`, RWX) |

## Architecture

### Components (Airflow 3.x)

| Component | Airflow 2.x | Airflow 3.x | Description |
|-----------|-------------|-------------|-------------|
| API / UI server | `webserver` | `apiServer` | Runs `airflow api-server`, port 8080 |
| DAG parsing | in scheduler | `dagProcessor` | Runs `airflow dag-processor` (new) |
| Scheduler | `scheduler` | `scheduler` | Schedules DAG runs (no longer parses) |
| Workers | `worker` | `worker` | Executes Celery tasks |
| Triggerer | `triggerer` | `triggerer` | Handles deferred operators |

### DAG loading modes

**`local`** — Place `.py` files in `mnt/airflow/dags/` on the host. The dag-processor picks
them up on the next scan cycle. No git credentials required.

**`gitsync`** — The git-sync sidecar clones your DAG repository into `/opt/airflow/dags/`
inside the dag-processor and worker pods. Requires an SSH deploy key.

### Secrets flow

```
OpenBao
  secret/airflow/fernet-key     → airflow-fernet-key    (ESO)  key: fernet-key
  secret/airflow/api            → airflow-api-secret    (ESO)  key: api-secret-key
  secret/airflow/api            → airflow-jwt-secret    (ESO)  key: jwt-secret
  secret/airflow/metadata-db    → airflow-metadata-db   (ESO, templated URI)
  secret/redis                  → airflow-celery        (ESO, templated Sentinel URL)
  secret/airflow/git            → airflow-ssh-secret    (ESO)  key: gitSshKey  ← gitsync only

PostgreSQL: pg-cluster-rw.postgres.svc.cluster.local:5432 (CNPG direct primary)
Redis:      sentinel-sentinel-{0,1,2}.sentinel-sentinel-headless.redis.svc.cluster.local:26379
DAGs:       gitsync → /opt/airflow/dags → LocalDagBundle
            local   → hostPath PVC (mnt/airflow/dags/) → /opt/airflow/dags
Logs:       hostPath PVC (mnt/airflow/logs/, RWX, 5 Gi)
```

## Prerequisites

Deploy in this order: **OpenBao → ESO → PostgreSQL → Redis → Airflow**

Or use the install script:

```bash
./scripts/k3d/install.sh install all
```

## Installation (install script — recommended)

```bash
# Full stack
./scripts/k3d/install.sh install all

# Airflow only (prereqs must already be running)
./scripts/k3d/install.sh install airflow
```

The script handles all of the following automatically:

- PostgreSQL database and user creation
- Secret generation (fernet key, API secret, JWT secret) and storage in OpenBao
- SSH key upload to OpenBao (gitsync mode)
- Helm install with the correct values overlay

DAG mode and gitsync parameters can be set via environment variables or entered interactively:

```bash
# Non-interactive gitsync example
AIRFLOW_DAGS_MODE=gitsync \
AIRFLOW_DAGS_REPO=git@github.com:org/dags.git \
AIRFLOW_GIT_SSH_KEY_FILE=~/.ssh/dags-deploy-key \
  ./scripts/k3d/install.sh install airflow

# Non-interactive local example
AIRFLOW_DAGS_MODE=local ./scripts/k3d/install.sh install airflow
```

## Manual installation

### 1 — Prepare PostgreSQL

Connect to the PostgreSQL primary and create a dedicated Airflow database and user:

```bash
# Detect the primary pod dynamically
PRIMARY=$(kubectl get pod -n postgres -l cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it "$PRIMARY" -n postgres -- psql -U postgres
```

Inside psql:

```sql
CREATE USER airflow WITH PASSWORD '<your-airflow-db-password>';
CREATE DATABASE airflow OWNER airflow;
\q
```

### 2 — Store secrets in OpenBao

Port-forward OpenBao and authenticate:

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &

export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=$(kubectl get secret openbao-unseal-keys -n openbao \
  -o jsonpath='{.data.root-token}' | base64 -d)
```

```bash
# Fernet key (stdlib only — no third-party packages required)
FERNET_KEY=$(python3 -c "import os, base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())")
bao kv put secret/airflow/fernet-key fernet-key="$FERNET_KEY"

# API server + JWT secrets (Airflow 3.x)
API_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
bao kv put secret/airflow/api api-secret-key="$API_SECRET" jwt-secret="$JWT_SECRET"

# Metadata DB credentials (use password from step 1)
bao kv put secret/airflow/metadata-db user="airflow" password="<your-airflow-db-password>"

# Git SSH key (gitsync mode only)
bao kv put secret/airflow/git private-key=@~/.ssh/your-dags-deploy-key

kill %1   # stop port-forward
```

### 3 — Apply manifests and install

```bash
kubectl create namespace airflow

# Storage
mkdir -p mnt/airflow/logs mnt/airflow/dags
chmod 777 mnt/airflow/logs   # Airflow containers run as UID 50000; logs dir must be world-writable
kubectl apply -f airflow/k3d/logs-storage.yaml
# local mode only:
kubectl apply -f airflow/k3d/dags-storage.yaml

# ExternalSecrets
kubectl apply -f airflow/k3d/externalsecrets/fernet-key.yaml
kubectl apply -f airflow/k3d/externalsecrets/api-secret.yaml
kubectl apply -f airflow/k3d/externalsecrets/jwt-secret.yaml
kubectl apply -f airflow/k3d/externalsecrets/metadata-db.yaml
kubectl apply -f airflow/k3d/externalsecrets/celery.yaml
# gitsync mode only:
kubectl apply -f airflow/k3d/externalsecrets/git.yaml

kubectl get externalsecrets -n airflow   # all should show SecretSynced

# Helm install — pick the correct overlay
helm install airflow apache-airflow/airflow \
  --namespace airflow \
  --version 1.21.0 \
  -f airflow/k3d/values.yaml \
  -f airflow/k3d/values-local.yaml \   # or values-gitsync.yaml
  --timeout 10m

# gitsync: also pass repo/branch/knownHosts via --set / -f
```

## Verify

```bash
kubectl get pods -n airflow

# dag-processor should be parsing DAGs
kubectl logs deployment/airflow-dag-processor -n airflow | tail -20

# gitsync: check the git-sync sidecar
kubectl logs deployment/airflow-dag-processor -n airflow -c git-sync | tail -10

# Workers connected to broker
kubectl exec -it deployment/airflow-worker -n airflow -- \
  airflow celery inspect active
```

## Access the UI

```bash
kubectl -n airflow port-forward svc/airflow-api-server 8080:8080
```

Open http://localhost:8080. Default credentials are set by the `create-user` job:

```bash
kubectl logs job/airflow-create-user -n airflow
```

## Log and DAG storage

| Host path | In-cluster path | Used by |
|-----------|-----------------|---------|
| `mnt/airflow/logs/` | `/var/lib/rancher/k3s/storage/airflow/logs/` | logs PV |
| `mnt/airflow/dags/` | `/var/lib/rancher/k3s/storage/airflow/dags/` | DAGs PV (local mode) |

Both paths are bind-mounted into every k3d node via `setup/k3d/config.yaml`, making the
hostPath PVs accessible from any pod on any node as ReadWriteMany.

## Sizing

| Component | CPU request/limit | Memory request/limit |
|-----------|-------------------|----------------------|
| API Server | `250m` / `500m` | `512Mi` / `1Gi` |
| DAG Processor | `250m` / `500m` | `256Mi` / `512Mi` |
| Scheduler | `500m` / `1` | `512Mi` / `1Gi` |
| Worker | `500m` / `1` | `512Mi` / `1Gi` |
| Triggerer | `100m` / `500m` | `256Mi` / `512Mi` |
| Logs PVC | — | 5 Gi (hostPath, RWX) |
| DAGs PVC | — | 1 Gi (hostPath, RWX, local mode) |

## Upgrade

```bash
helm upgrade airflow apache-airflow/airflow \
  --namespace airflow \
  --version 1.21.0 \
  -f airflow/k3d/values.yaml \
  -f airflow/k3d/values-<mode>.yaml
```

## Tear-down

```bash
./scripts/k3d/install.sh teardown airflow
```

Or manually:

```bash
helm uninstall airflow -n airflow
kubectl delete -f airflow/k3d/externalsecrets/
kubectl delete -f airflow/k3d/logs-storage.yaml
kubectl delete -f airflow/k3d/dags-storage.yaml
kubectl delete namespace airflow

# OpenBao secrets (irreversible)
bao kv delete secret/airflow/fernet-key
bao kv delete secret/airflow/api
bao kv delete secret/airflow/metadata-db
bao kv delete secret/airflow/git

# PostgreSQL (irreversible)
# kubectl exec into primary pod, then:
# DROP DATABASE airflow; DROP USER airflow;
```

Log and DAG data in `mnt/airflow/` is preserved after teardown (Retain policy).
Delete manually if no longer needed: `rm -rf mnt/airflow/`
