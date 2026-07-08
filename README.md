# Azure Landing Zone — Terraform

Hub-spoke landing zone following the Cloud Adoption Framework (CAF), used to
set up advanced infrastructure on Azure for deploying APIs and applications
on APIM and AKS.

## Prerequisites

```bash
# 1. Install tools
brew install terraform azure-cli  # or use apt/choco

# 2. Login to Azure
az login
az account set --subscription "<your-management-subscription-id>"

# 3. Create a service principal for Terraform
az ad sp create-for-rbac \
  --name "sp-terraform-landingzone" \
  --role "Owner" \
  --scopes "/providers/Microsoft.Management/managementGroups/<your-tenant-root-id>"

# 4. Export credentials as env vars (NEVER put these in code)
export ARM_CLIENT_ID="<appId>"
export ARM_CLIENT_SECRET="<password>"
export ARM_TENANT_ID="<tenant>"
export ARM_SUBSCRIPTION_ID="<management-subscription-id>"
```

## Deploy order

```
1. bootstrap/           → creates remote state storage
2. management-groups/   → builds MG hierarchy
3. policies/            → assigns Azure Policy
4. connectivity/        → deploys Hub VNet, Firewall, Bastion, DNS Resolver
5. landing-zones/dev/   → dev spoke VNet + peering + UDR
6. landing-zones/qa/    → qa spoke VNet + peering + UDR
7. landing-zones/prod/  → prod spoke VNet + peering + UDR
```

## Running each layer

```bash
cd bootstrap/
terraform init
terraform plan -var="management_subscription_id=$ARM_SUBSCRIPTION_ID"
terraform apply -var="management_subscription_id=$ARM_SUBSCRIPTION_ID"

# After bootstrap, grab the storage account name from output:
terraform output storage_account_name
# Then update backend "storage_account_name" in each subsequent layer's main.tf
```

## Key design decisions

- **One state file per layer** — blast radius isolation; a mistake in a spoke doesn't touch the hub state
- **Two Terraform providers in peering module** — peering touches two subscriptions simultaneously
- **UDR is mandatory** — VNet peering alone does NOT route through the firewall
- **DNS servers on spoke VNets** — must point to Hub DNS Resolver or private endpoints won't resolve
- **Firewall SKU = Premium** — required for TLS inspection and IDPS in production
