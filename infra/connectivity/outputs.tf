output "hub_vnet_id" {
  value       = module.hub_vnet.vnet_id
  description = "Used by spoke VNet peering"
}

output "hub_vnet_name" {
  value       = module.hub_vnet.vnet_name
  description = "Used by spoke peering resources"
}

output "hub_rg_name" {
  value       = azurerm_resource_group.hub.name
  description = "Used by spoke resources"
}

output "dns_inbound_ip" {
  value       = azurerm_private_dns_resolver_inbound_endpoint.hub.ip_configurations[0].private_ip_address
  description = "Set this as dns_servers on all spoke VNets"
}

output "law_id" {
  value       = azurerm_log_analytics_workspace.hub.id
  description = "Used by spoke diagnostic settings"
}
