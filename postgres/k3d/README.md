# PostgreSQL — k3d (Local Development)

3-instance HA cluster mirroring the cloud production configs. No WAL archiving or backups — local dev only.

## Files

| File                | Purpose                                                         |
|---------------------|-----------------------------------------------------------------|
| `storageclass.yaml` | `local-path` provisioner with `Retain` + `WaitForFirstConsumer` |
| `cluster.yaml`      | 3-instance PostgreSQL cluster                                   |
| `pooler.yaml`       | PgBouncer connection poolers (rw + ro)                          |

## Storage Path

The `local-path` provisioner stores PV data inside the k3d node container at:
```
/var/lib/rancher/k3s/storage/pvc-<uid>_<namespace>_<pvc-name>/
```

To expose this path on your host and persist data across cluster restarts, pass a volume mount at cluster creation:
```bash
k3d cluster create dev \
  --volume /tmp/k3d-storage:/var/lib/rancher/k3s/storage@all
```

Data is then accessible on your host at `/tmp/k3d-storage/pvc-<uid>_<namespace>_<pvc-name>/`.

## Deploy

```bash
kubectl apply -f storageclass.yaml
kubectl apply -f cluster.yaml
kubectl apply -f pooler.yaml
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

## Sizing

This setup runs 3 PostgreSQL pods on dedicated 4 GB agent nodes. The pod memory limit is `1Gi`, so the effective working set is capped there regardless of available node RAM.

| Resource                       | Value                            |
|--------------------------------|----------------------------------|
| Pod CPU                        | `250m` request / `1` limit       |
| Pod memory                     | `512Mi` request / `1Gi` limit    |
| `shared_buffers`               | `256MB` (25% of pod limit)       |
| `max_connections`              | `50`                             |
| Max app connections via pooler | ~200 (PgBouncer queues the rest) |
| Storage size                   | 2 Gi per instance                |
| Practical throughput           | ~500–1,000 TPS                   |

Storage uses `local-path` (hostPath) which passes through Docker's overlay filesystem to your host disk. IOPS and latency are determined by the host machine — NVMe gives acceptable dev performance, but this setup is not suitable for realistic load testing. For a load test, use a Medium-tier cloud deployment (4 vCPU / 4 Gi pod, 100 Gi cloud-managed SSD).

## Services

| Service                | Targets                | Use for              |
|------------------------|------------------------|----------------------|
| `pg-cluster-rw`        | Primary                | Direct writes        |
| `pg-cluster-ro`        | Replicas               | Direct reads         |
| `pg-cluster-pooler-rw` | Primary via PgBouncer  | Writes (recommended) |
| `pg-cluster-pooler-ro` | Replicas via PgBouncer | Reads (recommended)  |

## Tear-down

```bash
kubectl delete -f pooler.yaml
kubectl delete -f cluster.yaml
```

The `Retain` reclaim policy keeps PVCs and their backing volumes alive after the cluster is deleted. This is intentional — it prevents accidental data loss. To fully clean up:

```bash
# List retained PVCs
kubectl get pvc -n default -l cnpg.io/cluster=pg-cluster

# Delete them (data will be permanently lost)
kubectl delete pvc -n default -l cnpg.io/cluster=pg-cluster

# Remove the StorageClass
kubectl delete -f storageclass.yaml
```

To delete the k3d cluster itself, see [`setup/k3d/README.md`](../../setup/k3d/README.md).
