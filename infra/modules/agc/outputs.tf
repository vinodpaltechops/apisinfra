output "agc_id" {
  description = "Resource ID of the traffic controller. Goes in the Gateway's alb.networking.azure.io/alb-id annotation."
  value       = azapi_resource.agc.id
}

output "agc_name" {
  value = azapi_resource.agc.name
}

output "resource_group_name" {
  value = azurerm_resource_group.agc.name
}

output "frontend_name" {
  description = "Goes in the Gateway's spec.addresses (type alb.networking.azure.io/alb-frontend)."
  value       = azapi_resource.frontend.name
}

output "frontend_fqdn" {
  description = "Public hostname of the gateway. Point the app's DNS CNAME here."
  value       = azapi_resource.frontend.output.properties.fqdn
}

output "subnet_id" {
  value = azurerm_subnet.agc.id
}

output "subnet_address_prefix" {
  description = "Source range the gateway's traffic arrives from — what a pod NetworkPolicy ipBlock must allow."
  value       = var.subnet_address_prefix
}

output "alb_identity_client_id" {
  description = "Client ID the ALB Controller's service account is annotated with (azure.workload.identity/client-id)."
  value       = azurerm_user_assigned_identity.alb.client_id
}

output "alb_identity_principal_id" {
  value = azurerm_user_assigned_identity.alb.principal_id
}
