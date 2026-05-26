variable "cluster_name" {
  description = "Name of the AKS cluster and DNS prefix"
  type        = string
  default     = "kuberneteslab-aks"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,63}$", var.cluster_name))
    error_message = "cluster_name must be 1-63 alphanumeric or hyphen characters."
  }
}

variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
  default     = "akslab-rg"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "centralindia"
}

variable "kubernetes_version" {
  description = "Kubernetes version. Null uses the latest stable AKS version."
  type        = string
  default     = null
}

variable "system_node_vm_size" {
  description = "VM SKU for the system node pool (runs kube-system only)"
  type        = string
  default     = "Standard_B2s"
}

variable "worker_node_vm_size" {
  description = "VM SKU for the spot worker node pool (4 vCPU / 16 GB)"
  type        = string
  default     = "Standard_D4as_v5"
}

variable "worker_node_count" {
  description = "Number of dedicated Regular-priority worker nodes (always on)"
  type        = number
  default     = 2

  validation {
    condition     = var.worker_node_count >= 1
    error_message = "worker_node_count must be at least 1."
  }
}

variable "spot_min_count" {
  description = "Minimum number of spot nodes (can be 0 to scale to zero when idle)"
  type        = number
  default     = 0
}

variable "spot_max_count" {
  description = "Maximum number of spot nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.spot_max_count >= 1
    error_message = "spot_max_count must be at least 1."
  }
}

variable "aad_admin_group_object_ids" {
  description = "Azure AD group object IDs granted cluster-admin access via AAD RBAC"
  type        = list(string)
}

variable "vnet_cidr" {
  description = "Address space for the dedicated VNet"
  type        = string
  default     = "10.240.0.0/16"
}

variable "subnet_cidr" {
  description = "Address prefix for the node subnet (must be within vnet_cidr)"
  type        = string
  default     = "10.240.0.0/20"
}

variable "pod_cidr" {
  description = "CIDR for Kubenet pod overlay IPs (must not overlap with VNet or service_cidr)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes service ClusterIPs (must not overlap with VNet, pod_cidr, or any peered VNet)"
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "IP address for the cluster DNS service (must be within service_cidr)"
  type        = string
  default     = "172.16.0.10"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    environment = "dev"
    managed-by  = "terraform"
  }
}
