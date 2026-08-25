output "storage_account_name" {
  description = "Backup store account name — goes into the Velero BackupStorageLocation config as `storageAccount`."
  value       = azurerm_storage_account.velero.name
}

output "storage_account_id" {
  value = azurerm_storage_account.velero.id
}

output "container_name" {
  description = "Blob container holding backups — the BackupStorageLocation `bucket`."
  value       = azurerm_storage_container.velero.name
}

output "identity_client_id" {
  description = <<-EOT
    CLIENT id of Velero's managed identity. This is the value that goes into the
    velero ServiceAccount's azure.workload.identity/client-id annotation and
    into AZURE_CLIENT_ID in the Velero credentials secret.

    Note it is the client id, NOT the principal (object) id — workload identity
    federation matches on client id, and using the principal id fails at token
    exchange with an unhelpful "AADSTS700016: application not found".
  EOT
  value       = azurerm_user_assigned_identity.velero.client_id
}

output "identity_principal_id" {
  description = "Principal (object) id — used for further role assignments, not for the workload identity annotation."
  value       = azurerm_user_assigned_identity.velero.principal_id
}

output "identity_name" {
  value = azurerm_user_assigned_identity.velero.name
}

output "federated_subjects" {
  description = "The exact ServiceAccount subjects federated here. Compare against the running SA when Velero reports a credentials error."
  value       = { for k, v in azurerm_federated_identity_credential.velero : k => v.subject }
}

output "primary_blob_endpoint" {
  value = azurerm_storage_account.velero.primary_blob_endpoint
}

output "secondary_blob_endpoint" {
  description = "Read-only endpoint in the Azure paired region. Empty unless account_replication_type is RAGRS/RAGZRS. This is what a DR restore reads from while the primary region is down."
  value       = azurerm_storage_account.velero.secondary_blob_endpoint
}
