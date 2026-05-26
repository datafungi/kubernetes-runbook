# Redis — k3d (Local Development)

Sentinel HA cluster: 1 master + 2 replicas with 3 Sentinel instances coordinating failover.
Managed by the OpsTree redis-operator.

## Files

| File                  | Purpose                                                                         |
|-----------------------|---------------------------------------------------------------------------------|
| `externalsecret.yaml` | `ExternalSecret` — syncs Redis password from OpenBao via ESO                    |
| `replication.yaml`    | `RedisReplication` — 3-node master/replica group                                |
| `sentinel.yaml`       | `RedisSentinel` — 3 Sentinel instances, quorum = 2                              |
| `monitor.yaml`        | `ServiceMonitor` + `PodMonitor` for Prometheus (requires kube-prometheus-stack) |

## Prerequisites

Deploy in this order: **OpenBao → ESO → OpsTree operator → Redis**

Install the OpsTree redis-operator via Helm:

```bash
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/
helm repo update
helm install redis-operator ot-helm/redis-operator \
  --namespace ot-operators --create-namespace
kubectl -n ot-operators rollout status deployment/redis-operator
```

OpenBao and ESO must also be running. ESO syncs the Redis password from OpenBao into the `redis-secret` Kubernetes Secret, which the operator reads at startup. Store the password in OpenBao first (see [`openbao/k3d/README.md`](../../openbao/k3d/README.md)):

```bash
bao kv put secret/redis password="<your-redis-password>"
```

## Deploy

**Order matters** — Sentinel references the replication group by name and must be applied after the replication pods are Ready.

```bash
# 1. Create the namespace
kubectl create namespace redis

# 2. Sync the Redis password from OpenBao via ESO
kubectl apply -f redis/k3d/externalsecret.yaml
# Wait for ESO to create the secret (usually a few seconds)
kubectl get secret redis-secret -n redis

# 3. Deploy the replication group and wait for all 3 pods
kubectl apply -f redis/k3d/replication.yaml
kubectl rollout status statefulset/redis-replication -n redis

# 4. Deploy Sentinel
kubectl apply -f redis/k3d/sentinel.yaml
kubectl get redissentinel sentinel -n redis
```

Verify the topology:

```bash
# Check which pod is master
kubectl exec -it redis-replication-0 -n redis -- redis-cli -a <password> INFO replication | grep role

# Check sentinel sees the master
kubectl exec -it sentinel-0 -n redis -- redis-cli -p 26379 SENTINEL masters
```

## Connect

The password is managed by ESO and available in the synced secret:

```bash
kubectl get secret redis-secret -n redis -o jsonpath='{.data.password}' | base64 -d
```

### Sentinel-aware connection (recommended)

Apps connect to Sentinel on port `26379`. Sentinel returns the current master address, then the app connects directly to Redis. Use a Sentinel-capable client:

| Language | Library         | Constructor                                                |
|----------|-----------------|------------------------------------------------------------|
| Python   | `redis-py`      | `Redis.from_url("redis+sentinel://")` or `Sentinel([...])` |
| Go       | `go-redis`      | `NewSentinelClient`                                        |
| Node.js  | `ioredis`       | `new Redis({ sentinels: [...] })`                          |
| Java     | Lettuce / Jedis | `RedisClient.create(...)` (Sentinel URI)                   |

Sentinel service DNS:

```
sentinel-0.sentinel.redis.svc.cluster.local:26379
sentinel-1.sentinel.redis.svc.cluster.local:26379
sentinel-2.sentinel.redis.svc.cluster.local:26379
```

Reference in your application (Python `redis-py` example):

```yaml
env:
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: redis-secret
        key: password
  - name: REDIS_SENTINEL_HOSTS
    value: "sentinel-0.sentinel.redis.svc.cluster.local:26379,sentinel-1.sentinel.redis.svc.cluster.local:26379,sentinel-2.sentinel.redis.svc.cluster.local:26379"
  - name: REDIS_MASTER_NAME
    value: "myMaster"
```

### Direct connection (bypasses sentinel, not HA)

To connect directly to the current master for debugging:

```bash
kubectl exec -it redis-replication-0 -n redis -- redis-cli -a <password> PING
```

## Sizing

3 Redis pods on k3d agent nodes. Storage uses the k3d default `local-path` StorageClass (hostPath), backed by Docker's overlay filesystem. IOPS and latency depend on the host machine.

| Resource            | Value                           |
|---------------------|---------------------------------|
| Pod CPU             | `101m` request / `1` limit      |
| Pod memory          | `128Mi` request / `256Mi` limit |
| Sentinel CPU        | `101m` request / `1` limit      |
| Sentinel memory     | `128Mi` request / `128Mi` limit |
| Storage per replica | `1Gi`                           |

This setup is not suitable for realistic load testing. For load testing use a dedicated cloud environment with SSD-backed storage.

## Services

The operator creates headless services for DNS-based discovery:

| Service             | Port  | Use for                               |
|---------------------|-------|---------------------------------------|
| `redis-replication` | 6379  | Redis (direct pod DNS, all replicas)  |
| `sentinel`          | 26379 | Sentinel (master discovery, failover) |

Individual pod DNS: `<pod-name>.<service-name>.redis.svc.cluster.local`

## Tear-down

```bash
kubectl delete -f redis/k3d/monitor.yaml   # if monitoring stack is deployed
kubectl delete -f redis/k3d/sentinel.yaml
kubectl delete -f redis/k3d/replication.yaml
kubectl delete -f redis/k3d/externalsecret.yaml
```

The `local-path` StorageClass uses `Delete` reclaim policy — PVCs and their data are removed automatically when the StatefulSet is deleted. No manual PVC cleanup is required.

To delete the k3d cluster itself, see [`setup/k3d/README.md`](../../setup/k3d/README.md).
