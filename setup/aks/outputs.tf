output "cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  description = "Name of the resource group containing the cluster"
  value       = azurerm_resource_group.this.name
}

output "host" {
  description = "Kubernetes API server endpoint"
  value       = azurerm_kubernetes_cluster.this.kube_config[0].host
  sensitive   = true
}

output "kube_admin_config_raw" {
  description = "Raw kubeconfig using local admin credentials (break-glass access)"
  value       = azurerm_kubernetes_cluster.this.kube_admin_config_raw
  sensitive   = true
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL — use this to configure federated workload identity credentials"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "cluster_identity_principal_id" {
  description = "Principal ID of the cluster's user-assigned managed identity"
  value       = azurerm_user_assigned_identity.cluster.principal_id
}
