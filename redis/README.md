# Redis on Kubernetes

Sentinel HA cluster managed by the [OpsTree redis-operator](https://github.com/OT-CONTAINER-KIT/redis-operator).

## Architecture

**Sentinel mode** — 1 master + N replicas with 3 Sentinel processes coordinating automatic failover. The entire dataset lives on a single master; replicas are read-only mirrors.

```
App → Sentinel :26379  ──► discovers master
         │
         ▼
redis-replication-0 :6379  (master)
         │ replication
redis-replication-1 :6379  (replica)
redis-replication-2 :6379  (replica)
```

Failover flow: if the master is unreachable for `downAfterMilliseconds`, 2 of 3 Sentinels (quorum) vote to promote the most up-to-date replica. The whole election + promotion takes ~10–30 seconds with the defaults in this repo.

**When to use Sentinel vs Cluster:**

|                                      | Sentinel           | Redis Cluster                      |
|--------------------------------------|--------------------|------------------------------------|
| Dataset fits on one node             | Yes                | No requirement                     |
| Write throughput scales horizontally | No (single master) | Yes (sharded)                      |
| Multi-key transactions               | Full support       | Limited (slot-aware)               |
| Standard Redis client                | Yes                | No (cluster-aware client required) |
| Setup complexity                     | Low                | High                               |

Use Sentinel when your data fits on one node and you need simple HA. Switch to Cluster when you need to shard writes or the dataset exceeds a single node's memory.

## Operator

[OpsTree redis-operator](https://github.com/OT-CONTAINER-KIT/redis-operator) (`ot-helm/redis-operator`).

Chosen over Bitnami Helm charts due to Bitnami's licensing changes following the Broadcom acquisition. OpsTree is actively maintained, CNCF Sandbox candidate, and provides GitOps-friendly declarative CRDs.

**CRDs used:**

| Kind               | API Version                          | Purpose                              |
|--------------------|--------------------------------------|--------------------------------------|
| `RedisReplication` | `redis.redis.opstreelabs.in/v1beta2` | Master + replica StatefulSet         |
| `RedisSentinel`    | `redis.redis.opstreelabs.in/v1beta2` | Sentinel deployment, failover config |

**Install the operator (one-time per cluster):**

```bash
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/
helm repo update
helm install redis-operator ot-helm/redis-operator \
  --namespace ot-operators --create-namespace
kubectl -n ot-operators rollout status deployment/redis-operator
```

## Environments

| Directory | Environment     | Status    |
|-----------|-----------------|-----------|
| `k3d/`    | Local dev (k3d) | Available |

## Authentication

The operator does **not** auto-generate credentials. Create a Kubernetes Secret before deploying:

```bash
kubectl create secret generic redis-secret \
  --from-literal=password=<YOUR_PASSWORD>
```

Or use the `secret.yaml` template in each environment directory (edit the password first).

Rotate by updating the Secret and rolling the pods:

```bash
kubectl rollout restart statefulset/redis-replication
kubectl rollout restart deployment/redis-sentinel
```

## Redis Version

Images are published on [quay.io/opstree/redis](https://quay.io/repository/opstree/redis). Use a pinned tag for reproducibility:

```yaml
kubernetesConfig:
  image: quay.io/opstree/redis:v7.0.15
```

The k3d manifests in this repo use `latest` for convenience. Pin to a specific patch release in any shared or long-lived environment.

**Supported versions:** Redis 6.0+ (Redis 7.x recommended).

## Monitoring

Enable the bundled redis-exporter to expose Prometheus metrics on port `9121`:

```yaml
redisExporter:
  enabled: true
  image: quay.io/opstree/redis-exporter:latest
```

Create a `ServiceMonitor` resource (requires Prometheus Operator) to auto-discover the scrape target.
