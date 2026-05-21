# Monitoring — k3d (Local Development)

Prometheus + Grafana for local observability of CNPG and Redis workloads.

## Files

| File          | Purpose                                         |
|---------------|-------------------------------------------------|
| `values.yaml` | kube-prometheus-stack Helm values tuned for k3d |

## Prerequisites

CNPG and Redis must already be deployed (see their respective READMEs). The monitoring stack must be installed **before** applying the per-service monitor manifests because the `PodMonitor` and `ServiceMonitor` CRDs come from the stack.

## Install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f monitoring/k3d/values.yaml
kubectl -n monitoring rollout status deployment/monitoring-grafana
kubectl -n monitoring rollout status deployment/monitoring-kube-prometheus-stack-operator
```

## Apply service monitors

Each service ships its own monitor manifest alongside its other manifests:

```bash
# PostgreSQL PodMonitor
kubectl apply -f postgres/k3d/podmonitor.yaml

# Redis ServiceMonitor + operator PodMonitor
kubectl apply -f redis/k3d/monitor.yaml
```

## Verify scrape targets

```bash
# Port-forward Prometheus UI
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-stack-prometheus 9090:9090
```

Open http://localhost:9090/targets and confirm:
- `podMonitor/postgres/pg-cluster/0` — CNPG PostgreSQL instances
- `serviceMonitor/redis/redis-replication/0` — Redis exporter
- `podMonitor/ot-operators/redis-operator/0` — OpsTree operator controller

## Access Grafana

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```

URL: http://localhost:3000 — username: `admin`

```bash
# Retrieve the admin password
kubectl get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```

## Import dashboards

In Grafana: **Dashboards → Import**

### CNPG

Download the JSON files from https://github.com/cloudnative-pg/grafana-dashboards and paste into the import dialog:

- `charts/cluster.json` — per-cluster metrics (replication lag, WAL activity, connections)
- `charts/operator.json` — operator reconcile counts and errors

### Redis exporter

Enter ID **`763`** in the "Import via grafana.com" field. Select the Prometheus data source when prompted.

## Tear-down

```bash
kubectl delete -f redis/k3d/monitor.yaml
kubectl delete -f postgres/k3d/podmonitor.yaml
helm uninstall monitoring -n monitoring
# CRDs are not removed by helm uninstall — delete manually if needed:
kubectl delete crd alertmanagerconfigs.monitoring.coreos.com \
  alertmanagers.monitoring.coreos.com \
  podmonitors.monitoring.coreos.com \
  probes.monitoring.coreos.com \
  prometheuses.monitoring.coreos.com \
  prometheusrules.monitoring.coreos.com \
  scrapeconfigs.monitoring.coreos.com \
  servicemonitors.monitoring.coreos.com \
  thanosrulers.monitoring.coreos.com
```

## Sizing

All components run with ephemeral storage — metrics and dashboards do not survive pod restarts. This is intentional for local dev; use persistent volumes in shared or long-lived environments.

| Component          | CPU request            | Memory request          |
|--------------------|------------------------|-------------------------|
| Prometheus         | `200m` (chart default) | `400Mi` (chart default) |
| Grafana            | `100m` (chart default) | `128Mi` (chart default) |
| kube-state-metrics | `10m` (chart default)  | `32Mi` (chart default)  |

## Troubleshooting

**ServiceMonitor not picked up**

Verify the label OpsTree applied to the redis-replication service:

```bash
kubectl get svc redis-replication -n redis --show-labels
```

The ServiceMonitor in `redis/k3d/monitor.yaml` selects on `redis_setup_type: replication`. If the label differs, update the `selector.matchLabels` field.

**No metrics in Grafana**

Check that `redisExporter.enabled: true` is live on the cluster:

```bash
kubectl get redisreplication redis-replication -n redis -o jsonpath='{.spec.redisExporter.enabled}'
```

If it returns `false`, the manifest change hasn't been applied yet:

```bash
kubectl apply -f redis/k3d/replication.yaml
```
