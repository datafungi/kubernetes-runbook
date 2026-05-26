terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# User-assigned identity created before the cluster so we can grant it
# Network Contributor on the VNet before AKS needs it (Kubenet manages
# route tables on the subnet, which requires this permission at create time).
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "${var.cluster_name}-identity"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.cluster_name}-vnet"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidr]
}


resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = var.system_node_vm_size
    vnet_subnet_id = azurerm_subnet.nodes.id

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  azure_active_directory_role_based_access_control {
    admin_group_object_ids = var.aad_admin_group_object_ids
    azure_rbac_enabled     = true
  }

  local_account_disabled = false

  tags = var.tags

}

# Dedicated worker pool — Regular priority, always available, guarantees
# provisioning succeeds and provides a baseline for non-spot-tolerant workloads.
resource "azurerm_kubernetes_cluster_node_pool" "worker" {
  name                  = "worker"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.worker_node_vm_size
  mode                  = "User"
  vnet_subnet_id        = azurerm_subnet.nodes.id
  node_count            = var.worker_node_count

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.tags
}

# Spot pool — scales 0→N for burst workloads that tolerate eviction.
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.worker_node_vm_size
  mode                  = "User"
  vnet_subnet_id        = azurerm_subnet.nodes.id

  auto_scaling_enabled = true
  min_count            = var.spot_min_count
  max_count            = var.spot_max_count

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1

  node_labels = {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
  ]

  tags = var.tags
}
