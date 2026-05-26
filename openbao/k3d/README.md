# OpenBao — k3d (Local Development)

Standalone single-pod OpenBao. TLS disabled, UI enabled, `local-path` storage. Not suitable for production.

## Files

| File              | Purpose                                           |
|-------------------|---------------------------------------------------|
| `values.yaml`     | Helm values: standalone mode, local-path storage  |
| `unseal-job.yaml` | Job to unseal OpenBao after a pod/cluster restart |

## Install

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
helm install openbao openbao/openbao \
  --namespace openbao --create-namespace \
  -f openbao/k3d/values.yaml
kubectl wait pod/openbao-0 -n openbao --for=condition=Ready --timeout=120s
```

## Initialize (once only)

Run init with a single unseal key for simplicity. Save the output — you cannot recover these keys.

```bash
kubectl exec -n openbao openbao-0 -- bao operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > ~/.openbao-k3d-init.json

cat ~/.openbao-k3d-init.json
```

The output contains `unseal_keys_b64[0]` (the unseal key) and `root_token`. Store them in a Kubernetes Secret so the unseal Job can use them:

```bash
UNSEAL_KEY=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['unseal_keys_b64'][0])" ~/.openbao-k3d-init.json)
ROOT_TOKEN=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['root_token'])" ~/.openbao-k3d-init.json)

kubectl create secret generic openbao-unseal-keys \
  --namespace openbao \
  --from-literal=unseal-key="$UNSEAL_KEY" \
  --from-literal=root-token="$ROOT_TOKEN"
```

## Unseal

Apply the unseal Job after init and after any cluster/pod restart:

```bash
kubectl apply -f openbao/k3d/unseal-job.yaml
kubectl -n openbao wait --for=condition=complete job/openbao-unseal --timeout=60s
```

The Job cleans itself up after 120 seconds (`ttlSecondsAfterFinished`). Re-apply it on each restart.

Verify:

```bash
kubectl exec -n openbao openbao-0 -- bao status
```

## Configure OpenBao (once only)

Port-forward and set credentials:

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &

export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=$(kubectl get secret openbao-unseal-keys -n openbao \
  -o jsonpath='{.data.root-token}' | base64 -d)
```

Enable the KV-v2 secrets engine:

```bash
bao secrets enable -path=secret kv-v2
```

Enable and configure Kubernetes auth (External Secrets Operator uses this):

```bash
bao auth enable kubernetes

bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"
```

Create a policy that grants ESO read access to all secrets:

```bash
bao policy write external-secrets - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
EOF
```

Bind the ESO service account to that policy:

```bash
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h
```

## Store Secrets

Store the Redis password (replace the value with your own):

```bash
bao kv put secret/redis password="<your-redis-password>"
```

Verify:

```bash
bao kv get secret/redis
```

Kill the port-forward when done:

```bash
kill %1
```

## UI

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200
```

Open http://localhost:8200 — sign in with the root token from `openbao-unseal-keys`.

## After a Cluster Restart

OpenBao seals itself whenever the pod restarts. Re-apply the unseal Job:

```bash
kubectl apply -f openbao/k3d/unseal-job.yaml
kubectl -n openbao wait --for=condition=complete job/openbao-unseal --timeout=60s
kubectl delete job openbao-unseal -n openbao   # clean up; or let ttl expire
```

## Sizing

| Resource   | Value                           |
|------------|---------------------------------|
| Pod CPU    | `100m` request / `250m` limit   |
| Pod memory | `256Mi` request / `256Mi` limit |
| Storage    | 2Gi (`local-path`)              |

## Tear-down

```bash
helm uninstall openbao -n openbao
kubectl delete namespace openbao
```

PVCs use the `Delete` reclaim policy on `local-path` and are removed automatically with the namespace.
