output "registry_name" {
  description = "Short name — `az acr login --name <this>`."
  value       = azurerm_container_registry.this.name
}

output "login_server" {
  description = "Image prefix, e.g. acrdevvinorg001.azurecr.io."
  value       = azurerm_container_registry.this.login_server
}

output "registry_id" {
  value = azurerm_container_registry.this.id
}
