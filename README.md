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
8. platform/appgw/      → public entry point (WAF_v2) for the dev workload

── DR add-on (comment out the DR block in terraform-deploy.yml to skip) ──
9.  landing-zones/dr/   → second-region spoke + private AKS
10. platform/velero/    → geo-replicated backup store, both clusters
11. platform/appgw-dr/  → DR region's App Gateway
12. platform/frontdoor/ → global entry point, priority failover
```

## Running each layer

The state storage account's name and resource group live in ONE file,
[infra/backend.json](infra/backend.json). Bootstrap creates the account from it,
and every other layer reads it — its backend at `init`, its
`terraform_remote_state` blocks via `jsondecode`. Storage account names are
globally unique across Azure, so if the name is taken (e.g. by an old
subscription), change it there and nowhere else.

```bash
# Bootstrap — local state, plain init. Also registers every resource provider
# namespace the stack needs, so a fresh subscription needs no manual setup.
terraform -chdir=infra/platform/bootstrap init
terraform -chdir=infra/platform/bootstrap apply

# Every other layer — the backend needs the shared file at init
terraform -chdir=infra/platform/connectivity init -backend-config=../../backend.json
terraform -chdir=infra/platform/connectivity plan
```

Forgetting `-backend-config` makes `init` prompt for `storage_account_name`
(or fail, under `-input=false`). After changing backend.json, re-run init with
`-reconfigure` in any layer you have already initialised locally.

## Application workload

A three-service demo application runs on the dev spoke's private AKS cluster:

```
apps/          content-api (FastAPI) → backend BFF (FastAPI) → frontend (React + nginx)
k8s/           kustomize manifests + internal ingress-nginx values
k8s/gitops/    Argo CD: root apps, Velero config, backup schedules
```

- [apps/README.md](apps/README.md) — architecture, API contracts, local dev
- [k8s/README.md](k8s/README.md) — deploy runbook, access path, troubleshooting
- [k8s/gitops/README.md](k8s/gitops/README.md) — Argo CD topology, resource budget
- [docs/disaster-recovery.md](docs/disaster-recovery.md) — DR architecture + runbooks
- [docs/dr-reference.md](docs/dr-reference.md) — DR complete reference: inventory, RTO/RPO derivation, backup/restore mechanics, failover timelines

Pipelines: `argocd-bootstrap` (once per cluster) then `app-deploy` (build → ACR
→ commit the tag → Argo CD rolls it out). `app-deploy` no longer touches the
clusters at all; its last step is a git commit.

## Disaster recovery

Active-passive across two regions. Azure Front Door priority-routes to a
per-region Application Gateway; each region's AKS cluster runs its own Argo CD
syncing this repo, so **failover deploys nothing** — the standby is already on
the current commit. Velero backs both clusters up to one RAGRS blob store, using
filesystem backup rather than disk snapshots because Azure disk snapshots cannot
cross a region.

RTO ≈ 2–3 min for region loss (Front Door probe window); RPO 0 for Kubernetes
objects, ≤ 1 h for volume data. Known gaps — a single-region ACR, Key Vault and
hub — are listed at the end of [docs/disaster-recovery.md](docs/disaster-recovery.md).

**The whole DR add-on is removable.** Every layer is its own directory, the
connectivity changes live in a single `dr.tf`, and the pipeline jobs sit in one
commented-out block. See the teardown table in the DR doc.

## Key design decisions

- **One state file per layer** — blast radius isolation; a mistake in a spoke doesn't touch the hub state
- **Two Terraform providers in peering module** — peering touches two subscriptions simultaneously
- **UDR is mandatory** — VNet peering alone does NOT route through the firewall
- **DNS servers on spoke VNets** — must point to Hub DNS Resolver or private endpoints won't resolve
- **Firewall SKU = Premium** — required for TLS inspection and IDPS in production
- **Argo CD per cluster, not a hub** — a hub in the primary region is down during the very incident DR exists for, and driving a private DR API server across non-transitive peering puts the most fragile link on the recovery path
- **Velero uses filesystem backup, not snapshots** — an Azure disk snapshot is region-locked, so it cannot serve the one restore that matters
- **Front Door origins are strict priority, not weighted** — `additional_latency_in_milliseconds = 0`; any positive value silently turns active-passive into active-active against a standby sized for neither
