# PostgreSQL on Kubernetes — CloudNativePG

Manifests for deploying PostgreSQL using the [CloudNativePG operator](https://cloudnative-pg.io/) across four environments.

## Directory Structure

```
postgres/
├── k3d/                      # Local development (k3d / k3s)
│   ├── storageclass.yaml     # local-path with Retain + WaitForFirstConsumer
│   ├── cluster.yaml          # 3-instance HA cluster, mirrors production config
│   └── pooler.yaml           # PgBouncer (rw + ro)
├── aks/                      # Azure Kubernetes Service
│   ├── storageclass.yaml     # Azure Premium SSD (Premium_LRS)
│   ├── cluster.yaml          # 3-instance HA cluster, Azure Blob backups
│   ├── pooler.yaml           # PgBouncer (rw + ro)
│   └── scheduled-backup.yaml # Daily base backup at 02:00 UTC
├── gke/                      # Google Kubernetes Engine
│   ├── storageclass.yaml     # SSD Persistent Disk (pd-ssd)
│   ├── cluster.yaml          # 3-instance HA cluster, GCS backups
│   ├── pooler.yaml           # PgBouncer (rw + ro)
│   └── scheduled-backup.yaml # Daily base backup at 02:00 UTC
└── eks/                      # Elastic Kubernetes Service (AWS)
    ├── storageclass.yaml     # EBS gp3
    ├── cluster.yaml          # 3-instance HA cluster, S3 backups
    ├── pooler.yaml           # PgBouncer (rw + ro)
    └── scheduled-backup.yaml # Daily base backup at 02:00 UTC
```

## Prerequisites

### 1. Install the CloudNativePG Operator

**Helm (recommended):**
```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm upgrade --install cnpg \
  --namespace cnpg-system \
  --create-namespace \
  cnpg/cloudnative-pg
```

**kubectl:**
```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.1.yaml
```

Verify:
```bash
kubectl get pods -n cnpg-system
```

### 2. Install the cnpg kubectl Plugin (optional but recommended)

```bash
kubectl krew install cnpg
```

---

## PostgreSQL Version

Specify the version and image type via `imageName` in `cluster.yaml`. If omitted, the operator uses its bundled default (currently `18.3-system-trixie` — the deprecated `system` type).

```yaml
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:17-standard-trixie
```

### Image types

CloudNativePG publishes two current image types. The legacy `system` type (which the short `:17` tag resolves to) is deprecated — do not use it for new deployments.

| Type       | Includes                                             | When to use                                                                  |
|------------|------------------------------------------------------|------------------------------------------------------------------------------|
| `minimal`  | Core PostgreSQL binaries only                        | Simple OLTP, smallest attack surface, tight CVE SLAs                         |
| `standard` | `minimal` + pgvector, PGAudit, LLVM JIT, all locales | AI/embedding workloads, compliance auditing (SOC2/HIPAA), analytical queries |
| `system`   | **Deprecated** — do not use                          | —                                                                            |

All images are cosign-signed, include SBOM attestations, and are rebuilt weekly to pick up Debian and PGDG security patches. `minimal` has a smaller CVE surface because it ships fewer packages.

### Tag format

```
<major>.<minor>-<type>-<os>     # pinned:  17.6-minimal-trixie
<major>-<type>-<os>             # rolling: 17-standard-trixie
```

OS options: `trixie` (Debian 13, current) · `bookworm` (Debian 12, oldstable). Use `trixie` for new deployments.

### Supported versions and EOL dates

| Version | EOL date      | Recommendation                      |
|---------|---------------|-------------------------------------|
| **18**  | November 2030 | Latest — use for new projects       |
| **17**  | November 2029 | Stable — recommended for production |
| **16**  | November 2028 | Stable                              |
| **15**  | November 2027 | Stable                              |
| **14**  | November 2026 | Approaching EOL — plan upgrade      |
| **13**  | November 2025 | EOL — do not use                    |

### Upgrading

**Minor version** (e.g., 17.5 → 17.6): update `imageName` and apply. The operator performs a rolling restart — replicas updated one at a time, then the primary. With `primaryUpdateStrategy: unsupervised` this is fully automatic and zero-downtime.

**Major version** (e.g., 16 → 17): supported in-place as of CloudNativePG v1.26+ via `pg_upgrade --link`. Update `imageName` to the new major version tag and apply. The operator shuts the cluster down briefly, runs the upgrade, then rebuilds replicas — no separate cluster or `pg_dump` required. Plan for a short maintenance window.

---

## k3d — Local Development

3-instance HA setup using a `Retain`-policy StorageClass, mirroring the cloud production configs. No WAL archiving — backups are out of scope for local dev.

### Storage path

The `local-path` provisioner stores PV data inside the k3d node container at:
```
/var/lib/rancher/k3s/storage/pvc-<uid>_<namespace>_<pvc-name>/
```

To make this path accessible on your host and survive cluster restarts, mount a host volume when creating the k3d cluster:
```bash
k3d cluster create dev \
  --volume /tmp/k3d-storage:/var/lib/rancher/k3s/storage@all
```

Data is then readable on the host at `/tmp/k3d-storage/pvc-<uid>_<namespace>_<pvc-name>/`.

### Deploy

```bash
kubectl apply -f k3d/storageclass.yaml
kubectl apply -f k3d/cluster.yaml
kubectl apply -f k3d/pooler.yaml
kubectl cnpg status pg-cluster
```

---

## AKS — Azure Kubernetes Service

### Backup secret

```bash
kubectl create secret generic azure-storage-secret \
  --from-literal=storage-account-name=<STORAGE_ACCOUNT> \
  --from-literal=storage-account-key=<STORAGE_KEY>
```

### Edit placeholders in `aks/cluster.yaml`

| Placeholder         | Replace with               |
|---------------------|----------------------------|
| `<STORAGE_ACCOUNT>` | Azure storage account name |
| `<CONTAINER>`       | Azure Blob container name  |

### Deploy

```bash
kubectl apply -f aks/storageclass.yaml
kubectl apply -f aks/cluster.yaml
kubectl apply -f aks/pooler.yaml
kubectl apply -f aks/scheduled-backup.yaml
```

### Storage class

`managed-csi-premium` (Premium SSD / `Premium_LRS`) — use `UltraSSD_LRS` for workloads requiring >16,000 IOPS (requires a custom StorageClass with `skuName: UltraSSD_LRS`).

---

## GKE — Google Kubernetes Engine

### Backup secret

```bash
kubectl create secret generic gcs-credentials \
  --from-file=credentials.json=/path/to/service-account.json
```

> **Workload Identity (recommended):** Bind the CloudNativePG service account to a GCP service account with `Storage Object Admin` on your bucket. Remove the `googleCredentials` block from `gke/cluster.yaml`.

### Edit placeholders in `gke/cluster.yaml`

| Placeholder     | Replace with    |
|-----------------|-----------------|
| `<YOUR_BUCKET>` | GCS bucket name |

### Deploy

```bash
kubectl apply -f gke/storageclass.yaml
kubectl apply -f gke/cluster.yaml
kubectl apply -f gke/pooler.yaml
kubectl apply -f gke/scheduled-backup.yaml
```

### Storage class

`pd-ssd` (SSD Persistent Disk). On GKE 1.28+, switch to `hyperdisk-balanced` for better price/performance — update the `type` parameter in `storageclass.yaml` and the `provisioner` stays `pd.csi.storage.gke.io`.

---

## EKS — Elastic Kubernetes Service

Requires the **EBS CSI driver** add-on (included by default on EKS 1.23+).

### Backup secret

```bash
kubectl create secret generic aws-s3-credentials \
  --from-literal=ACCESS_KEY_ID=<YOUR_KEY_ID> \
  --from-literal=ACCESS_SECRET_KEY=<YOUR_SECRET> \
  --from-literal=DATA_ACCESS_REGION=<YOUR_REGION>
```

> **IRSA (recommended):** Annotate the CloudNativePG service account with an IAM role ARN (`eks.amazonaws.com/role-arn`) that has `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on your bucket. Remove the `s3Credentials` block from `eks/cluster.yaml`.

### Edit placeholders in `eks/cluster.yaml`

| Placeholder     | Replace with   |
|-----------------|----------------|
| `<YOUR_BUCKET>` | S3 bucket name |

### Deploy

```bash
kubectl apply -f eks/storageclass.yaml
kubectl apply -f eks/cluster.yaml
kubectl apply -f eks/pooler.yaml
kubectl apply -f eks/scheduled-backup.yaml
```

### Storage class

`gp3` with 4,000 IOPS and 200 MB/s throughput baseline. Increase `iops` up to 16,000 in `storageclass.yaml` for latency-sensitive workloads, or switch to `io2` for up to 64,000 IOPS.

---

## Services Reference

The operator creates these services automatically for every cluster:

| Service                | Targets                | Use for                   |
|------------------------|------------------------|---------------------------|
| `pg-cluster-rw`        | Primary only           | Direct writes (no pooler) |
| `pg-cluster-ro`        | Replicas only          | Direct reads (no pooler)  |
| `pg-cluster-r`         | Any instance           | Round-robin (no pooler)   |
| `pg-cluster-pooler-rw` | Primary via PgBouncer  | Writes (cloud setups)     |
| `pg-cluster-pooler-ro` | Replicas via PgBouncer | Reads (cloud setups)      |

---

## Common Operations

### Check cluster status
```bash
kubectl cnpg status pg-cluster
```

### Get connection credentials
```bash
# Full URI
kubectl get secret pg-cluster-app -o jsonpath='{.data.uri}' | base64 -d

# Individual fields
kubectl get secret pg-cluster-app -o jsonpath='{.data.host}' | base64 -d
kubectl get secret pg-cluster-app -o jsonpath='{.data.password}' | base64 -d
```

### Connect application pods

Reference the secret in your deployment:
```yaml
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: pg-cluster-app
        key: uri
```

### Trigger a manual backup
```bash
kubectl cnpg backup pg-cluster
```

### Recover from backups

Only the cloud manifests in this repo (`aks/`, `gke/`, `eks/`) support recovery from backups. The `k3d/` setup does **not** archive WAL or take base backups.

CloudNativePG recovery is **not in-place**. Restore into a **new** cluster, validate it, then cut applications over. For disaster recovery, the durable source of truth is the object store configured under `spec.backup.barmanObjectStore`; `Backup` objects are only available if the original namespace still exists.

#### Before you restore

1. If the source cluster still exists, stop or quiesce application writes first.
2. Trigger a final backup if needed:
   ```bash
   kubectl cnpg backup pg-cluster
   ```
3. Inspect available backups:
   ```bash
   kubectl get backup
   kubectl describe backup <backup-name>
   kubectl get scheduledbackup
   ```
4. Copy the environment's `cluster.yaml` to a new recovery manifest and change `metadata.name` to something new such as `pg-cluster-restore`. Keep `instances`, `storage`, and `postgresql.parameters` aligned with the source cluster during recovery.

`Status.Backup Id` from `kubectl describe backup` can be used as `recoveryTarget.backupID` when you need to pin recovery to a specific base backup.

#### Fast path: restore from an existing `Backup` object

Use this only when the `Backup` custom resource still exists in the same namespace.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-cluster-restore
spec:
  instances: 3
  storage:
    size: 50Gi
    storageClass: <same storageClass as source cluster>
  postgresql:
    parameters:
      # copy from the source environment's cluster.yaml
  bootstrap:
    recovery:
      backup:
        name: <backup-cr-name>
```

Apply it and watch the restore:
```bash
kubectl apply -f restore.yaml
kubectl cnpg status pg-cluster-restore
kubectl get pods -l cnpg.io/cluster=pg-cluster-restore
```

#### Durable DR path: restore from the object store

Use this when the Kubernetes `Backup` objects are gone but the backup bucket/container still exists. Copy the **same** provider-specific `barmanObjectStore` credentials and `destinationPath` from the source environment's `cluster.yaml`, then add `bootstrap.recovery` plus `externalClusters`.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-cluster-restore
spec:
  instances: 3
  primaryUpdateStrategy: unsupervised
  storage:
    size: 50Gi
    storageClass: <same storageClass as source cluster>
  postgresql:
    parameters:
      # copy from the source environment's cluster.yaml
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      barmanObjectStore:
        destinationPath: "<same destinationPath as source cluster>"
        serverName: pg-cluster
        # copy the matching credentials block from aks/gke/eks cluster.yaml
        wal:
          maxParallel: 8
```

Notes:

- Copy the exact provider-specific credential block from `aks/cluster.yaml`, `gke/cluster.yaml`, or `eks/cluster.yaml`.
- `serverName: pg-cluster` makes the recovery cluster read the original backup catalog even though the `externalClusters` entry is named `origin`.
- If you want the restored cluster to keep taking backups after cutover, configure its `backup` section with a **different** bucket prefix or server name. Do not make the recovered cluster write back into the same backup catalog it is restoring from.

Apply and monitor:
```bash
kubectl apply -f restore.yaml
kubectl cnpg status pg-cluster-restore
kubectl get pods -l cnpg.io/cluster=pg-cluster-restore
```

#### Point-in-time recovery (PITR)

To stop replay at a specific point, add `recoveryTarget` under `bootstrap.recovery`:

```yaml
spec:
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "2026-05-20T02:15:00Z"
```

Rules that matter in practice:

- Always include an explicit timezone in `targetTime` such as `Z` or `+00:00`.
- If `targetTime` or `targetLSN` is set, CloudNativePG automatically picks the closest completed base backup before that target unless you also set `backupID`.
- If you recover by `targetName`, `targetXID`, or `targetImmediate`, you must set `backupID`.
- If `recoveryTarget` is omitted, recovery replays to the latest available WAL on the default timeline.

Example with an explicit base backup:

```yaml
spec:
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        backupID: "20260520T020000"
        targetTime: "2026-05-20T02:15:00Z"
```

#### Validate and cut over

1. Wait for `kubectl cnpg status pg-cluster-restore` to show a healthy primary and replicas.
2. Fetch the restored connection secret:
   ```bash
   kubectl get secret pg-cluster-restore-app -o jsonpath='{.data.uri}' | base64 -d
   ```
3. Run application smoke tests and data checks against `pg-cluster-restore-rw` or `pg-cluster-restore-pooler-rw`.
4. Repoint applications to the restored cluster.
5. Only delete the old cluster after the restored one is accepted and backup archiving is confirmed.

Important constraints:

- Backups do **not** include Kubernetes secrets. Expect new `*-app` / `*-superuser` secrets unless you explicitly provide them on the recovery cluster.
- During recovery, PostgreSQL is up but not writable until replay finishes and the cluster is promoted.
- Keep `.spec.postgresql.parameters` compatible with the original cluster until recovery completes; change tuning afterwards if needed.
- Test this procedure regularly. A backup policy is not complete until a full restore has been proven end-to-end.

Official references:

- https://cloudnative-pg.io/docs/1.29/recovery/
- https://cloudnative-pg.io/docs/1.29/backup/
- https://cloudnative-pg.io/docs/1.27/appendixes/backup_barmanobjectstore/

### Promote a replica manually
```bash
kubectl cnpg promote pg-cluster <replica-pod-name>
```

### Reload PostgreSQL configuration
```bash
kubectl cnpg reload pg-cluster
```

---

## Resource Sizing

Resources apply to every pod (primary + all replicas). Multiply by `instances` (3) for total cluster footprint. CloudNativePG recommends **Guaranteed QoS** for PostgreSQL pods — memory request should equal memory limit to prevent OOM eviction of the postmaster.

### PostgreSQL Pod Resources

| Tier       | Typical use case                                        | CPU req / lim | Memory req / lim | Storage |
|------------|---------------------------------------------------------|---------------|------------------|---------|
| **Small**  | Dev / staging, <50 connections, <20 GB data             | `250m` / `1`  | `512Mi` / `1Gi`  | 20 Gi   |
| **Medium** | General production, ~200 connections, <100 GB data      | `1` / `2`     | `4Gi` / `4Gi`    | 100 Gi  |
| **Large**  | High-traffic production, ~300 connections, <500 GB data | `4` / `4`     | `16Gi` / `16Gi`  | 500 Gi  |

### PostgreSQL Tuning Parameters

All SSD-backed environments should also set `random_page_cost = "1.1"` and `effective_io_concurrency = "200"` — the defaults are tuned for spinning disk.

| Parameter                      | What it does                                                                          | Small (1 Gi pod) | Medium (4 Gi pod) | Large (16 Gi pod) |
|--------------------------------|---------------------------------------------------------------------------------------|------------------|-------------------|-------------------|
| `shared_buffers`               | PostgreSQL's main in-memory cache for table and index pages.                          | `256MB`          | `1GB`             | `4GB`             |
| `effective_cache_size`         | Planner estimate of total OS + PostgreSQL cache available for reads.                  | `768MB`          | `3GB`             | `12GB`            |
| `work_mem`                     | Memory available per sort, hash, or similar query operation before spilling to disk.  | `8MB`            | `10MB`            | `20MB`            |
| `maintenance_work_mem`         | Memory used by maintenance tasks such as `VACUUM`, `CREATE INDEX`, and `ALTER TABLE`. | `64MB`           | `256MB`           | `1GB`             |
| `max_connections`              | Hard cap on concurrent backend connections accepted by PostgreSQL.                    | `50`             | `200`             | `300`             |
| `wal_buffers`                  | Memory reserved for buffering WAL records before they are flushed to disk.            | `16MB`           | `16MB`            | `16MB`            |
| `checkpoint_completion_target` | Spreads checkpoint I/O across more of the checkpoint interval to reduce write spikes. | `0.9`            | `0.9`             | `0.9`             |

`max_connections` is kept low because PgBouncer handles application-facing fan-out — each pooler pod multiplies effective client capacity.

### PgBouncer Pooler Settings

| Tier       | `max_client_conn` | `default_pool_size` | `reserve_pool_size` |
|------------|-------------------|---------------------|---------------------|
| **Small**  | `200`             | `10`                | `5`                 |
| **Medium** | `1000`            | `25`                | `10`                |
| **Large**  | `2000`            | `30`                | `10`                |

`default_pool_size` is sized so all pools together stay within PostgreSQL's `max_connections`. PgBouncer is single-threaded — increase `instances` in the Pooler spec (e.g., `instances: 3`) before approaching ~15,000 QPS.

### Recommended Node Sizes

Each PostgreSQL pod runs on a dedicated node (CloudNativePG default pod anti-affinity). Budget ~800 MB–1 GB per node for OS + Kubernetes overhead on top of the pod's memory limit.

| Tier       | AWS          | GCP             | Azure             | vCPUs | Node RAM |
|------------|--------------|-----------------|-------------------|-------|----------|
| **Small**  | `m5.large`   | `n2-standard-2` | `Standard_D2s_v3` | 2     | 8 GB     |
| **Medium** | `m5.xlarge`  | `n2-standard-4` | `Standard_D4s_v3` | 4     | 16 GB    |
| **Large**  | `m5.2xlarge` | `n2-standard-8` | `Standard_E8s_v3` | 8     | 32 GB    |

For Large and above, prefer memory-optimized instances (AWS `r6i`, GCP `n2-highmem`, Azure `E`-series) — PostgreSQL's primary bottleneck is RAM, not CPU.

---

## Production Checklist

- [ ] Operator installed in a dedicated namespace (`cnpg-system`)
- [ ] `instances: 3` (odd number for quorum)
- [ ] `WaitForFirstConsumer` storage binding mode (all StorageClasses here use this)
- [ ] `reclaimPolicy: Retain` on the StorageClass (all StorageClasses here use this)
- [ ] WAL archiving configured and a restore has been tested end-to-end
- [ ] Backup secret created before applying `cluster.yaml`
- [ ] Scheduled backup deployed and verified with `kubectl get scheduledbackup`
- [ ] Apps connecting via the pooler service, not directly to PostgreSQL
- [ ] Resource requests/limits tuned to actual workload
- [ ] Monitoring: `kubectl cnpg status` or scrape the built-in Prometheus metrics endpoint
