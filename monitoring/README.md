# Monitoring

Prometheus + Grafana observability for all workloads in this runbook.

## Stack

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) (`prometheus-community`) — batteries-included chart that deploys:

- **Prometheus Operator** — manages `PodMonitor`, `ServiceMonitor`, `PrometheusRule` CRDs
- **Prometheus** — metric collection and storage
- **Grafana** — dashboards
- **kube-state-metrics** — Kubernetes resource metrics

## Architecture

```
                   monitoring namespace
┌──────────────────────────────────────────────────┐
│  Prometheus ─────────────────── Grafana          │
│      │ scrape via CRDs           │ query         │
└──────┼───────────────────────────────────────────┘
       │
       ├── PodMonitor: pg-cluster
       │     cnpg-postgres-exporter sidecar (:9187)
       │     auto-created by CNPG operator
       │
       ├── ServiceMonitor: redis-replication
       │     redis-exporter sidecar (:9121)
       │
       └── PodMonitor: redis-operator
             controller metrics (:8080)
```

## Scraping across namespaces

`podMonitorSelectorNilUsesHelmValues: false` and `serviceMonitorSelectorNilUsesHelmValues: false` are set in the Helm values so Prometheus scrapes monitors from **all** namespaces — necessary because workloads live in `postgres` and `redis`, the OpsTree operator in `ot-operators`, and Prometheus in `monitoring`.

## Grafana dashboards

Dashboards are imported manually via the Grafana UI (Dashboards → Import).

| Dashboard      | Source      | Import                                                                                                                                       |
|----------------|-------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| CNPG cluster   | GitHub JSON | Download `cluster.json` from [cloudnative-pg/grafana-dashboards](https://github.com/cloudnative-pg/grafana-dashboards) and paste into Import |
| CNPG operator  | GitHub JSON | Download `operator.json` from same repo                                                                                                      |
| Redis exporter | Grafana.com | ID `763`                                                                                                                                     |

## Environments

| Directory | Environment     |
|-----------|-----------------|
| `k3d/`    | Local dev (k3d) |
