output "resource_group_name" {
  value = module.spoke_network.resource_group_name
}

output "location" {
  description = "DR region, sourced from the connectivity layer."
  value       = local.location
}

output "spoke_vnet_id" {
  value = module.spoke_network.vnet_id
}

output "spoke_subnet_ids" {
  value = module.spoke_network.subnet_ids
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_node_resource_group" {
  description = "MC_* group holding the cluster's disks — the scope Velero needs for snapshot rights (infra/platform/velero)."
  value       = module.aks.node_resource_group
}

output "aks_oidc_issuer_url" {
  description = "Workload identity issuer — federated by the velero layer so Velero here can reach the shared backup store."
  value       = module.aks.oidc_issuer_url
}

output "aks_pod_cidr" {
  value = local.aks_pod_cidr
}

output "ingress_internal_ip" {
  description = "Static private VIP the DR ingress controller must claim. Keep in sync with azure-load-balancer-ipv4 in k8s/gitops/platform/ingress-nginx/values-dr.yaml and with ingress_internal_ip in the DR appgw layer."
  value       = local.ingress_internal_ip
}
