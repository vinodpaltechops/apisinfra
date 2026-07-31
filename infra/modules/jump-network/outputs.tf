output "vnet_id" {
  value = azurerm_virtual_network.jump.id
}

output "vnet_name" {
  value = azurerm_virtual_network.jump.name
}

output "subnet_id" {
  value = azurerm_subnet.jump.id
}
