output "agc_id" {
  description = "Value for the Gateway annotation alb.networking.azure.io/alb-id."
  value       = module.agc.agc_id
}

output "frontend_name" {
  description = "Value for the Gateway's spec.addresses entry (type alb.networking.azure.io/alb-frontend)."
  value       = module.agc.frontend_name
}

output "frontend_fqdn" {
  description = "Public hostname of the gateway."
  value       = module.agc.frontend_fqdn
}

output "dns_record_instructions" {
  description = "What to enter at the DNS provider. A CNAME, not an A record: AGC exposes a hostname, not an IP."
  value       = "DNS → Add record: Type=CNAME, Name=<app label>, Value=${module.agc.frontend_fqdn}, TTL=600"
}

output "agc_subnet_cidr" {
  description = "Source range of gateway traffic — the ipBlock a pod NetworkPolicy must allow."
  value       = module.agc.subnet_address_prefix
}

output "alb_identity_client_id" {
  description = "Client ID for the ALB Controller's service account (workload identity). Feed it to the Helm chart via Argo CD."
  value       = module.agc.alb_identity_client_id
}

output "alb_namespace_service_account" {
  description = "The subject the identity's federated credential trusts."
  value       = "system:serviceaccount:azure-alb-system:alb-controller-sa"
}
