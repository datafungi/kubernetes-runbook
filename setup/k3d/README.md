# k3d Cluster Setup

[k3d](https://k3d.io/) is a lightweight wrapper around k3s that runs Kubernetes nodes as Docker containers, making it easy to spin up local clusters for development and testing.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [k3d](https://k3d.io/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Cluster Configuration

The cluster is defined in [`config.yaml`](./config.yaml):

| Setting        | Value             |
|----------------|-------------------|
| Cluster name   | `simple-cluster`  |
| Docker network | `k3dcluster`      |
| Server nodes   | 1 (2 GB RAM)      |
| Agent nodes    | 2 (4 GB RAM each) |

## Creating the Cluster

### If Tailscale is enabled

Tailscale reduces the network MTU to 1280. The Docker network **must** be created with a matching MTU before the cluster is created, otherwise inter-node communication will silently drop oversized packets.

```bash
docker network create --opt com.docker.network.driver.mtu=1280 k3dcluster
```

Then create the cluster:

```bash
k3d cluster create --config config.yaml
```

### Without Tailscale

```bash
k3d cluster create --config config.yaml
```

k3d will create the `k3dcluster` Docker network automatically if it does not already exist.

## Accessing the Cluster

k3d merges the cluster's kubeconfig into `~/.kube/config` automatically. To verify:

```bash
kubectl cluster-info
kubectl get nodes
```

## Deleting the Cluster

```bash
k3d cluster delete simple-cluster
```

If you created the Docker network manually (Tailscale path), remove it afterwards:

```bash
docker network rm k3dcluster
```

## Setting CPU Limits

k3d's `v1alpha5` config schema does not support per-node CPU limits. Apply them after cluster creation using `docker update`:

```bash
# Server node
docker update --cpus=2 k3d-simple-cluster-server-0

# Agent nodes
docker update --cpus=2 k3d-simple-cluster-agent-0
docker update --cpus=2 k3d-simple-cluster-agent-1
```

Adjust the `--cpus` value to suit your machine. The changes take effect immediately without restarting the containers.

## Notes

- The `serversMemory` / `agentsMemory` settings in `config.yaml` map to Docker's `--memory` flag for each container. You can also adjust memory after creation with `docker update --memory=<value>`.
