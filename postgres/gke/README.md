# PostgreSQL — GKE (Google Kubernetes Engine)

3-instance HA cluster with SSD Persistent Disk storage and WAL archiving to Google Cloud Storage.

## Files

| File                    | Purpose                                             |
|-------------------------|-----------------------------------------------------|
| `storageclass.yaml`     | SSD Persistent Disk (`pd-ssd`) with `Retain` policy |
| `cluster.yaml`          | 3-instance PostgreSQL cluster with GCS backups      |
| `pooler.yaml`           | PgBouncer connection poolers (rw + ro)              |
| `scheduled-backup.yaml` | Daily base backup at 02:00 UTC                      |

## Storage Class

`pd-ssd` (SSD Persistent Disk). On GKE 1.28+, switch to `hyperdisk-balanced` for better price/performance by updating the `type` parameter in `storageclass.yaml` — the provisioner (`pd.csi.storage.gke.io`) stays the same.

## Node & Storage Sizing

### Recommended machine types per tier

Each PostgreSQL pod runs on a dedicated node. Budget ~800 MB–1 GB per node for OS + Kubernetes overhead. The `cluster.yaml` in this directory is pre-configured for the **Medium** tier.

| Tier       | Machine type    | vCPUs | RAM   | Pod CPU req / lim | Pod memory req / lim |
|------------|-----------------|-------|-------|-------------------|----------------------|
| **Small**  | `n2-standard-2` | 2     | 8 GB  | `250m` / `1`      | `512Mi` / `1Gi`      |
| **Medium** | `n2-standard-4` | 4     | 16 GB | `1` / `2`         | `4Gi` / `4Gi`        |
| **Large**  | `n2-standard-8` | 8     | 32 GB | `4` / `4`         | `16Gi` / `16Gi`      |

For Large and above, prefer `n2-highmem` (8 GB RAM per vCPU) over `n2-standard` (4 GB per vCPU).

### GCP pd-ssd IOPS reference

`pd-ssd` IOPS scale with disk size: **6,000 + (30 × GiB)**, capped by the node's vCPU count (a 4-vCPU node caps at ~40,000 read IOPS). Throughput = 240 + (0.48 × GiB) MiB/s.

| Tier       | Volume size | IOPS    | Throughput |
|------------|-------------|---------|------------|
| **Small**  | 100 Gi      | ~9,000  | ~288 MiB/s |
| **Medium** | 500 Gi      | ~21,000 | ~480 MiB/s |
| **Large**  | 1,000 Gi    | ~36,000 | ~720 MiB/s |

On GKE 1.28+ you can switch to `hyperdisk-balanced` for better price/performance — update the `type` parameter in `storageclass.yaml`.

## Prerequisites

### 1. Create the backup secret

**Static service account key:**
```bash
kubectl create secret generic gcs-credentials \
  --from-file=credentials.json=/path/to/service-account.json
```

**Workload Identity (recommended):** Skip the secret. Bind the CloudNativePG service account to a GCP service account with `Storage Object Admin` on your bucket, then remove the `googleCredentials` block from `cluster.yaml`.

### 2. Edit placeholders in `cluster.yaml`

| Placeholder     | Replace with    |
|-----------------|-----------------|
| `<YOUR_BUCKET>` | GCS bucket name |

## Deploy

```bash
kubectl apply -f storageclass.yaml
kubectl apply -f cluster.yaml
kubectl apply -f pooler.yaml
kubectl apply -f scheduled-backup.yaml
kubectl cnpg status pg-cluster
```

## Connect

CloudNativePG auto-generates credentials and stores them in two secrets:

```bash
# Full connection URI (app user)
kubectl get secret pg-cluster-app -o jsonpath='{.data.uri}' | base64 -d

# Superuser URI
kubectl get secret pg-cluster-superuser -o jsonpath='{.data.uri}' | base64 -d
```

Reference in your application:
```yaml
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: pg-cluster-app
        key: uri
```

## Services

| Service                | Targets                | Use for              |
|------------------------|------------------------|----------------------|
| `pg-cluster-rw`        | Primary                | Direct writes        |
| `pg-cluster-ro`        | Replicas               | Direct reads         |
| `pg-cluster-pooler-rw` | Primary via PgBouncer  | Writes (recommended) |
| `pg-cluster-pooler-ro` | Replicas via PgBouncer | Reads (recommended)  |

## Verify Backups

```bash
# Check scheduled backup status
kubectl get scheduledbackup pg-cluster-backup

# Trigger a manual backup
kubectl cnpg backup pg-cluster

# List completed backups
kubectl get backup
```
