# k3d Cluster Setup

[k3d](https://k3d.io/) is a lightweight wrapper around k3s that runs Kubernetes nodes as Docker containers, making it easy to spin up local clusters for development and testing.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [k3d](https://k3d.io/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

### Docker daemon DNS (required on systemd-resolved hosts)

On Linux hosts that use `systemd-resolved` (Fedora, Ubuntu 20.04+), `/etc/resolv.conf` points to
the local stub resolver at `127.0.0.53`. Docker containers cannot reach that address, so image pulls
fail with `SERVFAIL` after a host reboot. Add the real upstream DNS to `/etc/docker/daemon.json`
before creating the cluster (or before the first reboot):

```json
{
  "dns": ["<your-upstream-dns>", "1.1.1.1"]
}
```

Find your upstream: `awk '/^nameserver/{print $2; exit}' /run/systemd/resolve/resolv.conf`

Apply without restarting Docker: `sudo systemctl reload docker` (or restart Docker if reload is
not supported). `startup.sh` patches node `/etc/resolv.conf` at runtime as a belt-and-suspenders
measure, but `daemon.json` is the durable fix.

## Cluster Configuration

The cluster is defined in [`config.yaml`](./config.yaml):

| Setting        | Value                                                   |
|----------------|---------------------------------------------------------|
| Cluster name   | `simple-cluster`                                        |
| Docker network | `k3dcluster`                                            |
| Server nodes   | 1 (2 GB RAM) — control plane only, tainted `NoSchedule` |
| Agent nodes    | 3 (4 GB RAM each) — one per PostgreSQL instance         |

The server node is tainted `node-role.kubernetes.io/control-plane:NoSchedule` so no workloads schedule on it. All three agent nodes are available exclusively for application pods, giving each PostgreSQL instance a dedicated 4 GB node.

The repo's `mnt/` directory is bind-mounted into every node at `/var/lib/rancher/k3s/storage` — the root used by the `local-path` StorageClass. All PV data (PostgreSQL, Redis, OpenBao, Airflow logs) is written under `mnt/` and survives cluster restarts.

`config.yaml` uses a `REPO_ROOT_PLACEHOLDER` token for the volume path because k3d requires an absolute path and the repo location differs per machine. The install script substitutes it automatically. To create the cluster manually, run the substitution yourself:

```bash
sed "s|REPO_ROOT_PLACEHOLDER|$(pwd)|g" setup/k3d/config.yaml | k3d cluster create --config -
```

| Host path (repo-relative) | In-container path                       | Used by                                          |
|---------------------------|-----------------------------------------|--------------------------------------------------|
| `mnt/`                    | `/var/lib/rancher/k3s/storage/`         | `local-path` StorageClass root                   |
| `mnt/airflow/`            | `/var/lib/rancher/k3s/storage/airflow/` | Airflow log PV (`airflow/k3d/logs-storage.yaml`) |

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
docker update --cpus=2 k3d-simple-cluster-agent-2
```

Adjust the `--cpus` value to suit your machine. The changes take effect immediately without restarting the containers.

## After a Host Restart

k3d survives host reboots automatically, but several stack components need manual recovery steps
(OpenBao re-seals, Redis loses replication state, etc.). Run the startup script once after every
host reboot:

```bash
./scripts/k3d/startup.sh
```

It handles, in order: k3d node DNS, ImagePullBackOff pods, CoreDNS, Redis split-brain, OpenBao
unseal, ESO ClusterSecretStore, and ExternalSecret force-sync.

## Notes

- The `serversMemory` / `agentsMemory` settings in `config.yaml` map to Docker's `--memory` flag for each container. You can also adjust memory after creation with `docker update --memory=<value>`.
- The volume mount is defined in `config.yaml` and applied to all nodes automatically. All PV data written by the `local-path` provisioner persists under `mnt/pvc-<uid>_<namespace>_<pvc-name>/` on your host. Static hostPath PVs (OpenBao, Redis, Airflow logs) write directly to their configured subdirectories under `mnt/`.
- The server node taint (`node-role.kubernetes.io/control-plane:NoSchedule`) is applied via a k3s `--node-taint` server arg in `config.yaml`. No additional configuration is needed on the PostgreSQL side — pods without a matching toleration are automatically excluded from the server node.
