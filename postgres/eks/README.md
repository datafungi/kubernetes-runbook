# PostgreSQL — EKS (Elastic Kubernetes Service)

3-instance HA cluster with EBS gp3 storage and WAL archiving to S3.

Requires the **EBS CSI driver** add-on (included by default on EKS 1.23+).

## Files

| File                    | Purpose                                              |
|-------------------------|------------------------------------------------------|
| `storageclass.yaml`     | EBS gp3 (4,000 IOPS / 200 MB/s) with `Retain` policy |
| `cluster.yaml`          | 3-instance PostgreSQL cluster with S3 backups        |
| `pooler.yaml`           | PgBouncer connection poolers (rw + ro)               |
| `scheduled-backup.yaml` | Daily base backup at 02:00 UTC                       |

## Storage Class

`gp3` with 4,000 IOPS and 200 MB/s throughput baseline. Tune `iops` up to 16,000 in `storageclass.yaml` for latency-sensitive workloads, or switch `type` to `io2` for up to 64,000 IOPS.

## Node & Storage Sizing

### Recommended instance types per tier

Each PostgreSQL pod runs on a dedicated node. Budget ~800 MB–1 GB per node for OS + Kubernetes overhead. The `cluster.yaml` in this directory is pre-configured for the **Medium** tier.

| Tier       | Instance type | vCPUs | RAM   | Pod CPU req / lim | Pod memory req / lim |
|------------|---------------|-------|-------|-------------------|----------------------|
| **Small**  | `m5.large`    | 2     | 8 GB  | `250m` / `1`      | `512Mi` / `1Gi`      |
| **Medium** | `m5.xlarge`   | 4     | 16 GB | `1` / `2`         | `4Gi` / `4Gi`        |
| **Large**  | `m5.2xlarge`  | 8     | 32 GB | `4` / `4`         | `16Gi` / `16Gi`      |

For Large and above, prefer memory-optimized `r6i` instances (8 GB RAM per vCPU) over `m5` (4 GB per vCPU).

### EBS gp3 IOPS reference

The 3,000 IOPS / 125 MiB/s baseline is included at no extra cost regardless of volume size. Provision additional IOPS and throughput separately as needed. Update `iops` and `throughput` in `storageclass.yaml` to match your tier.

| Tier       | Volume size | IOPS             | Throughput           |
|------------|-------------|------------------|----------------------|
| **Small**  | 20 Gi       | 3,000 (baseline) | 125 MiB/s (baseline) |
| **Medium** | 100 Gi      | 6,000            | 250 MiB/s            |
| **Large**  | 500 Gi      | 16,000           | 500 MiB/s            |

## Prerequisites

### 1. Create the namespace and backup secret

```bash
kubectl create namespace postgres
```

**Static IAM credentials:**
```bash
kubectl create secret generic aws-s3-credentials \
  --from-literal=ACCESS_KEY_ID=<YOUR_KEY_ID> \
  --from-literal=ACCESS_SECRET_KEY=<YOUR_SECRET> \
  --from-literal=DATA_ACCESS_REGION=<YOUR_REGION> \
  -n postgres
```

**IRSA (recommended):** Skip the secret. Annotate the CloudNativePG service account with an IAM role ARN that has `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on your bucket, then remove the `s3Credentials` block from `cluster.yaml`.

```bash
kubectl annotate serviceaccount cnpg-manager \
  -n cnpg-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>
```

### 2. Edit placeholders in `cluster.yaml`

| Placeholder     | Replace with   |
|-----------------|----------------|
| `<YOUR_BUCKET>` | S3 bucket name |

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
