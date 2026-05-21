# PostgreSQL — AKS (Azure Kubernetes Service)

3-instance HA cluster with Azure Premium SSD storage and WAL archiving to Azure Blob Storage.

## Files

| File                    | Purpose                                                |
|-------------------------|--------------------------------------------------------|
| `storageclass.yaml`     | Azure Premium SSD (`Premium_LRS`) with `Retain` policy |
| `cluster.yaml`          | 3-instance PostgreSQL cluster with Azure Blob backups  |
| `pooler.yaml`           | PgBouncer connection poolers (rw + ro)                 |
| `scheduled-backup.yaml` | Daily base backup at 02:00 UTC                         |

## Storage Class

`Premium_LRS` (Azure Premium SSD). For workloads requiring >16,000 IOPS, create a separate StorageClass with `skuName: UltraSSD_LRS`.

## Node & Storage Sizing

### Recommended VM sizes per tier

Each PostgreSQL pod runs on a dedicated node. Budget ~800 MB–1 GB per node for OS + Kubernetes overhead. The `cluster.yaml` in this directory is pre-configured for the **Medium** tier.

| Tier       | VM SKU            | vCPUs | RAM   | Pod CPU req / lim | Pod memory req / lim |
|------------|-------------------|-------|-------|-------------------|----------------------|
| **Small**  | `Standard_D2s_v3` | 2     | 8 GB  | `250m` / `1`      | `512Mi` / `1Gi`      |
| **Medium** | `Standard_D4s_v3` | 4     | 16 GB | `1` / `2`         | `4Gi` / `4Gi`        |
| **Large**  | `Standard_E8s_v3` | 8     | 32 GB | `4` / `4`         | `16Gi` / `16Gi`      |

For Large and above, prefer memory-optimized `E`-series VMs (8 GB RAM per vCPU) over `D`-series (4 GB per vCPU).

### Azure Premium SSD IOPS reference

Premium SSD v1 (`Premium_LRS`) provisions IOPS by disk tier — capacity and IOPS are coupled:

| Tier       | Disk tier | Volume size | Provisioned IOPS | Throughput |
|------------|-----------|-------------|------------------|------------|
| **Small**  | P10       | 128 Gi      | 500 IOPS         | 100 MB/s   |
| **Medium** | P20       | 512 Gi      | 2,300 IOPS       | 150 MB/s   |
| **Large**  | P30       | 1,024 Gi    | 5,000 IOPS       | 200 MB/s   |

**Premium SSD v2 (`PremiumV2_LRS`) is recommended for new deployments.** It decouples capacity from IOPS: baseline 3,000 IOPS / 125 MB/s at any size, provisioned independently up to 80,000 IOPS / 1,200 MB/s. Update `skuName: PremiumV2_LRS` in `storageclass.yaml` to use it.

## Prerequisites

### 1. Create the namespace and backup secret

```bash
kubectl create namespace postgres
kubectl create secret generic azure-storage-secret \
  --from-literal=storage-account-name=<STORAGE_ACCOUNT> \
  --from-literal=storage-account-key=<STORAGE_KEY> \
  -n postgres
```

### 2. Edit placeholders in `cluster.yaml`

| Placeholder         | Replace with               |
|---------------------|----------------------------|
| `<STORAGE_ACCOUNT>` | Azure storage account name |
| `<CONTAINER>`       | Azure Blob container name  |

## Deploy

```bash
kubectl apply -f storageclass.yaml
kubectl apply -f cluster.yaml
kubectl apply -f pooler.yaml
kubectl apply -f scheduled-backup.yaml
kubectl cnpg status pg-cluster -n postgres
```

## Connect

CloudNativePG auto-generates credentials and stores them in two secrets:

```bash
# Full connection URI (app user)
kubectl get secret pg-cluster-app -n postgres -o jsonpath='{.data.uri}' | base64 -d

# Superuser URI
kubectl get secret pg-cluster-superuser -n postgres -o jsonpath='{.data.uri}' | base64 -d
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
kubectl get scheduledbackup pg-cluster-backup -n postgres

# Trigger a manual backup
kubectl cnpg backup pg-cluster -n postgres

# List completed backups
kubectl get backup -n postgres
```
