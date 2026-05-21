# kubernetes-runbook

Production-ready Kubernetes manifests and runbooks for common stateful workloads.

## Services

| Service    | Operator / Tool              | Environments         |
|------------|------------------------------|----------------------|
| [PostgreSQL](postgres/README.md) | CloudNativePG | k3d, AKS, GKE, EKS |
| [Redis](redis/README.md)         | OpsTree redis-operator (Sentinel) | k3d |

## Cluster Setup

| Environment | Setup guide |
|-------------|-------------|
| k3d (local dev) | [`setup/k3d/README.md`](setup/k3d/README.md) |
| RKE2            | [`setup/rke2/README.md`](setup/rke2/README.md) |
