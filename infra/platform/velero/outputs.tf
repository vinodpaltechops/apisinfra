# These four values are what the in-cluster Velero configuration needs. The
# ArgoCD bootstrap workflow reads them from this layer's state and substitutes
# them into k8s/gitops/platform/velero/values-*.yaml, so the client id and
# storage account name are never hand-copied into Git.

output "storage_account_name" {
  description = "BackupStorageLocation `storageAccount`."
  value       = module.velero_backend.storage_account_name
}

output "container_name" {
  description = "BackupStorageLocation `bucket`."
  value       = module.velero_backend.container_name
}

output "resource_group_name" {
  description = "BackupStorageLocation `resourceGroup` — the group holding the STORAGE ACCOUNT, not the cluster."
  value       = azurerm_resource_group.velero.name
}

output "identity_client_id" {
  description = "Goes into the velero ServiceAccount's azure.workload.identity/client-id annotation. CLIENT id, not principal id — see the module output."
  value       = module.velero_backend.identity_client_id
}

output "subscription_id" {
  description = "BackupStorageLocation `subscriptionId`."
  value       = data.azurerm_client_config.current.subscription_id
}

output "federated_subjects" {
  description = "ServiceAccount subjects currently federated. Compare against the running SA when Velero logs a credentials failure — a namespace or SA rename silently breaks the token exchange."
  value       = module.velero_backend.federated_subjects
}

output "secondary_blob_endpoint" {
  description = "Read-only replica endpoint in the paired region. Empty unless account_replication_type is RAGRS/RAGZRS."
  value       = module.velero_backend.secondary_blob_endpoint
}
