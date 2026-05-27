# Apache Airflow — k3d (Local Development)

CeleryExecutor deployment using the official Apache Airflow Helm chart (v1.21.0, Airflow 3.2.0).
DAGs are loaded via GitSync sidecar (SSH, no PVC). Logs are persisted to a shared hostPath PVC.
All secrets are stored in OpenBao and synchronized into the cluster by ESO.

## Files

| File                   | Purpose                                                                   |
|------------------------|---------------------------------------------------------------------------|
| `values.yaml`          | Helm values: CeleryExecutor, GitSync, log PVC, resource limits            |
| `externalsecrets.yaml` | ESO ExternalSecrets: six secrets synced from OpenBao                      |
| `logs-storage.yaml`    | PersistentVolume + PersistentVolumeClaim for Airflow logs (hostPath, RWX) |

## Architecture

### Components (Airflow 3.x)

Airflow 3.x restructured the component layout from 2.x:

| Component       | Airflow 2.x  | Airflow 3.x    | Description                           |
|-----------------|--------------|----------------|---------------------------------------|
| API / UI server | `webserver`  | `apiServer`    | Runs `airflow api-server`, port 8080  |
| DAG parsing     | in scheduler | `dagProcessor` | Runs `airflow dag-processor` (new)    |
| Scheduler       | `scheduler`  | `scheduler`    | Schedules DAG runs (no longer parses) |
| Workers         | `worker`     | `worker`       | Executes Celery tasks                 |
| Triggerer       | `triggerer`  | `triggerer`    | Handles deferred operators            |

### Secrets flow

```
OpenBao
  secret/airflow/fernet-key     → airflow-fernet-key    (ESO)  key: fernet-key
  secret/airflow/api            → airflow-api-secret    (ESO)  key: api-secret-key
  secret/airflow/api            → airflow-jwt-secret    (ESO)  key: jwt-secret
  secret/airflow/metadata-db    → airflow-metadata-db   (ESO, templated URI)
  secret/redis                  → airflow-celery        (ESO, templated Sentinel URL)
  secret/airflow/git            → airflow-ssh-secret    (ESO)  key: gitSshKey

PostgreSQL: pg-cluster-rw.postgres.svc.cluster.local:5432 (CNPG direct primary)
Redis:      sentinel-{0,1,2}.sentinel.redis.svc.cluster.local:26379 (OpsTree Sentinel)
DAGs:       GitSync sidecar → /opt/airflow/dags → dag-processor LocalDagBundle
Logs:       hostPath PVC (ReadWriteMany, 5 Gi) — mnt/airflow/ → /var/lib/rancher/k3s/storage/airflow
```

## Prerequisites

Deploy in this order: **OpenBao → ESO → PostgreSQL → Redis → Airflow**

All of the following must already be running:

- OpenBao (initialized and unsealed) — `openbao/k3d/`
- External Secrets Operator with `ClusterSecretStore openbao` — `external-secrets-operator/k3d/`
- PostgreSQL CNPG cluster `pg-cluster` in namespace `postgres` — `postgres/k3d/`
- Redis Sentinel cluster in namespace `redis` — `redis/k3d/`

Add the official Apache Airflow Helm repo:

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update
helm search repo apache-airflow/airflow --versions | head -5
```

## 1 — Prepare PostgreSQL

Connect to the PostgreSQL primary and create a dedicated Airflow database and user. Use the CNPG superuser credentials:

```bash
# Open a psql session via the primary pod
kubectl exec -it pg-cluster-1 -n postgres -- psql -U postgres
```

Inside psql:

```sql
CREATE USER airflow WITH PASSWORD '<your-airflow-db-password>';
CREATE DATABASE airflow OWNER airflow;
\q
```

## 2 — Store Secrets in OpenBao

Port-forward OpenBao and authenticate:

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &

export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=$(kubectl get secret openbao-unseal-keys -n openbao \
  -o jsonpath='{.data.root-token}' | base64 -d)
```

### Fernet key

Encrypts passwords and connection strings in the Airflow metadata database:

```bash
FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")

bao kv put secret/airflow/fernet-key \
  fernet-key="$FERNET_KEY"
```

### API server and JWT secrets (Airflow 3.x)

The Airflow 3 API server needs two separate secrets:
- **api-secret-key** — Flask/ASGI session signing (`[api] secret_key`)
- **jwt-secret** — JWT token signing for API authentication (`[api_auth] jwt_secret`)

```bash
API_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")

bao kv put secret/airflow/api \
  api-secret-key="$API_SECRET" \
  jwt-secret="$JWT_SECRET"
```

### Airflow metadata database credentials

Use the password you chose in step 1:

```bash
bao kv put secret/airflow/metadata-db \
  user="airflow" \
  password="<your-airflow-db-password>"
```

### Git SSH key (for GitSync)

Store the private key that has read access to your DAGs repository:

```bash
bao kv put secret/airflow/git \
  private-key="$(cat ~/.ssh/your-dags-deploy-key)"
```

The corresponding public key must be added as a deploy key in your Git repository settings (read-only access is sufficient).

Kill the port-forward when done:

```bash
kill %1
```

## 3 — Configure values.yaml

Edit `airflow/k3d/values.yaml` and set your DAG repository URL:

```yaml
dags:
  gitSync:
    repo: "git@github.com:<your-org>/<your-dags-repo>.git"
    branch: "main"
```

If your DAGs live in a subdirectory (e.g. `dags/`), set `subPath: "dags"`.

Update `knownHosts` if your Git provider is not GitHub:

```bash
ssh-keyscan gitlab.com    # or your host
```

Replace the `knownHosts` block in `values.yaml` with the output.

## 4 — Deploy

```bash
# Create the namespace
kubectl create namespace airflow

# Create the log PersistentVolume and PVC (hostPath, shared across all k3d nodes)
# The directory /tmp/k3d-storage/airflow-logs/ is created automatically on first use.
kubectl apply -f airflow/k3d/logs-storage.yaml
kubectl get pvc airflow-logs -n airflow
# STATUS should be Bound

# Apply ExternalSecrets (ESO will sync secrets from OpenBao)
kubectl apply -f airflow/k3d/externalsecrets.yaml

# Wait for all six secrets to be synced
kubectl get externalsecrets -n airflow
# All should show STATUS=SecretSynced

# Install Airflow
helm install airflow apache-airflow/airflow \
  --namespace airflow \
  --version 1.21.0 \
  -f airflow/k3d/values.yaml \
  --timeout 10m
```

Watch the rollout:

```bash
kubectl get pods -n airflow -w
```

The chart runs a `db-migrations` job first, then a `create-user` job. Both must complete before the scheduler, api-server, dag-processor, workers, and triggerer become Ready.

## 5 — Verify

```bash
# All Airflow pods should be Running or Completed
kubectl get pods -n airflow

# Check dag-processor is parsing DAGs from the gitSync volume
kubectl logs deployment/airflow-dag-processor -n airflow | tail -20

# Check the git-sync sidecar in the dag-processor pod
kubectl logs deployment/airflow-dag-processor -n airflow -c git-sync | tail -10

# Check scheduler is scheduling runs
kubectl logs deployment/airflow-scheduler -n airflow | tail -20

# Confirm Celery workers are connected to the broker
kubectl exec -it deployment/airflow-worker -n airflow -- \
  airflow celery inspect active
```

## 6 — Access the UI

The Airflow 3 UI is served by the API server (not the webserver):

```bash
kubectl -n airflow port-forward svc/airflow-api-server 8080:8080
```

Open http://localhost:8080.

Default credentials are set by the Helm chart's `create-user` job. Check the job logs if you did not set a password explicitly:

```bash
kubectl logs job/airflow-create-user -n airflow
```

## Log Storage

Logs are stored in a `hostPath` PersistentVolume defined in `logs-storage.yaml`.

`setup/k3d/config.yaml` mounts the repo's `mnt/` directory into every k3d node container at `/var/lib/rancher/k3s/storage`. The Airflow log PV uses the path `/var/lib/rancher/k3s/storage/airflow` inside the container, which resolves to `mnt/airflow/` on the host. Because all agent nodes share the same underlying host directory, the PVC uses `ReadWriteMany` — any Airflow pod on any node writes to the same location without needing an NFS server.

**Prerequisite:** the k3d cluster must be created (or recreated) with the updated `config.yaml` that includes the `mnt/airflow` volume mount. If your cluster is already running without this mount, recreate it:

```bash
k3d cluster delete simple-cluster
k3d cluster create --config setup/k3d/config.yaml
```

To inspect logs on the host:

```bash
ls mnt/airflow/
```

## Upgrade

```bash
helm upgrade airflow apache-airflow/airflow \
  --namespace airflow \
  --version 1.21.0 \
  -f airflow/k3d/values.yaml
```

Helm runs the `db-migrations` job automatically on upgrade.

## Sizing

| Component     | CPU request/limit | Memory request/limit |
|---------------|-------------------|----------------------|
| API Server    | `250m` / `500m`   | `512Mi` / `1Gi`      |
| DAG Processor | `250m` / `500m`   | `256Mi` / `512Mi`    |
| Scheduler     | `500m` / `1`      | `512Mi` / `1Gi`      |
| Worker        | `500m` / `1`      | `512Mi` / `1Gi`      |
| Triggerer     | `100m` / `500m`   | `256Mi` / `512Mi`    |
| Log PVC       | —                 | 5 Gi (hostPath, RWX) |

## Tear-down

```bash
helm uninstall airflow -n airflow
kubectl delete -f airflow/k3d/externalsecrets.yaml
kubectl delete -f airflow/k3d/logs-storage.yaml
kubectl delete namespace airflow
```

Secrets created by ESO are deleted with the namespace. The log PV uses `Retain` reclaim policy — the data at `/tmp/k3d-storage/airflow-logs` is kept after teardown. Delete it manually if no longer needed:

```bash
rm -rf /tmp/k3d-storage/airflow-logs
```

OpenBao secrets are **not** deleted automatically. To remove them:

```bash
bao kv delete secret/airflow/fernet-key
bao kv delete secret/airflow/api
bao kv delete secret/airflow/metadata-db
bao kv delete secret/airflow/git
```

The PostgreSQL database and user must be dropped manually if no longer needed:

```sql
DROP DATABASE airflow;
DROP USER airflow;
```
