# AKS Dev Cluster

Terraform configuration for a development AKS cluster in **Central India** using:

- **System pool**: 1 × `Standard_D4as_v4` (Regular priority) for kube-system workloads
- **Worker pool**: 1–3 × `Standard_D4as_v4` Spot VMs with cluster autoscaler
- **Network**: Azure CNI Overlay with a dedicated VNet (`10.240.0.0/16`)
- **Auth**: Azure AD RBAC with local admin kubeconfig fallback

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- Azure CLI logged in: `az login`
- An Azure AD group whose object ID will become cluster-admin

## Usage

```hcl
# terraform.tfvars
cluster_name               = "aks-dev"
resource_group_name        = "rg-aks-dev"
aad_admin_group_object_ids = ["<your-aad-group-object-id>"]
```

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Get kubeconfig

```bash
# AAD-authenticated (requires group membership)
az aks get-credentials --resource-group rg-aks-dev --name aks-dev

# Local admin fallback (break-glass)
terraform output -raw kube_admin_config_raw > ~/.kube/aks-dev-admin.yaml
export KUBECONFIG=~/.kube/aks-dev-admin.yaml
```

## Scheduling on spot workers

Spot nodes are tainted `kubernetes.azure.com/scalesetpriority=spot:NoSchedule`.
Add this toleration to any workload that should run on the worker pool:

```yaml
tolerations:
  - key: "kubernetes.azure.com/scalesetpriority"
    operator: "Equal"
    value: "spot"
    effect: "NoSchedule"
```
