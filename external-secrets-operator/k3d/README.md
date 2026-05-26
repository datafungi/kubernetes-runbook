# External Secrets Operator — k3d (Local Development)

ESO syncs secrets from OpenBao into Kubernetes Secrets. A single `ClusterSecretStore` connects to OpenBao using Kubernetes auth — no static tokens stored in the cluster.

## Files

| File                      | Purpose                                           |
|---------------------------|---------------------------------------------------|
| `values.yaml`             | ESO Helm values (single replica, small resources) |
| `clustersecretstore.yaml` | Cluster-wide store pointing to OpenBao            |

## Prerequisites

OpenBao must be deployed, initialized, unsealed, and configured (Kubernetes auth enabled, `external-secrets` role created). See [`openbao/k3d/README.md`](../../openbao/k3d/README.md).

## Install

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  -f external-secrets-operator/k3d/values.yaml
kubectl -n external-secrets rollout status deployment/external-secrets
```

## Apply ClusterSecretStore

```bash
kubectl apply -f external-secrets-operator/k3d/clustersecretstore.yaml
```

Verify it is ready:

```bash
kubectl get clustersecretstore openbao
```

Expected output:

```
NAME      AGE   STATUS   CAPABILITIES   READY
openbao   10s   Valid    ReadWrite      True
```

If `STATUS` is `InvalidStore`, check that OpenBao is unsealed and the Kubernetes auth role is configured correctly:

```bash
kubectl describe clustersecretstore openbao
```

## Usage Pattern

Any namespace can sync a secret from OpenBao by creating an `ExternalSecret` that references the `openbao` ClusterSecretStore:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: my-secret          # name of the Kubernetes Secret to create
  data:
    - secretKey: password    # key in the Kubernetes Secret
      remoteRef:
        key: my-app          # OpenBao path: secret/data/my-app
        property: password   # field within that secret
```

ESO will create and keep the Kubernetes Secret in sync, refreshing it every `refreshInterval`.

## Tear-down

```bash
kubectl delete -f external-secrets-operator/k3d/clustersecretstore.yaml
helm uninstall external-secrets -n external-secrets
kubectl delete namespace external-secrets
```
