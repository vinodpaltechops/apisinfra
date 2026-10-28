#!/usr/bin/env bash
# One-time setup: create an Azure AD app + Service Principal, wire GitHub OIDC
# federated credentials (no client secret), and grant RBAC. Run locally once
# with an account that can create app registrations + assign roles.
#
#   ./scripts/setup-azure-oidc.sh
#
# Then copy the printed values into GitHub → Settings → Secrets and variables →
# Actions (Variables: AZURE_*; Secret: TF_VAR_ADMIN_PASSWORD).
set -euo pipefail

# ── EDIT THESE ────────────────────────────────────────────────────────────────
APP_NAME="gha-azure-landing-zone"
GH_REPO="vinodpaltechops/apisinfra" # owner/repo
# ──────────────────────────────────────────────────────────────────────────────

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
# The tenant root management group id equals the tenant id.
ROOT_MG="$TENANT_ID"

echo "Subscription: $SUBSCRIPTION_ID"
echo "Tenant:       $TENANT_ID"

# 1) App registration + service principal — reused if one with this name
#    already exists, so the script can be re-run to add a federated credential
#    (a new branch, say) without minting a second app and a new client id.
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
  az ad sp create --id "$APP_ID" >/dev/null
  echo "App (client) id: $APP_ID (created)"
else
  # Covers an app whose service principal was never created (a partial first run).
  az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" >/dev/null
  echo "App (client) id: $APP_ID (existing)"
fi

# 2) Federated credentials — GitHub OIDC, no secret.
#    One subject per trigger context the pipeline runs under.
EXISTING_FICS="$(az ad app federated-credential list --id "$APP_ID" --query "[].name" -o tsv)"
add_fic() {
  if grep -qx "$1" <<<"$EXISTING_FICS"; then
    echo "  federated credential: $2 (already present, skipped)"
    return
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$1\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$2\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" >/dev/null
  echo "  federated credential: $2"
}
add_fic "main"        "repo:${GH_REPO}:ref:refs/heads/main"   # apply on main
add_fic "dev"         "repo:${GH_REPO}:ref:refs/heads/dev"    # apply on dev (AGC work is merged here first)
add_fic "pull-request" "repo:${GH_REPO}:pull_request"          # plan on PRs
add_fic "env-production" "repo:${GH_REPO}:environment:production"

# 3) RBAC (lab-grade — broad on purpose).
#    - Owner on the subscription: the infra creates role assignments (AKS→DNS
#      zone, Key Vault RBAC, VM login), which need User Access Administrator /
#      Owner, plus everything else.
az role assignment create --assignee "$APP_ID" --role "Owner" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null
echo "  role: Owner @ subscription"

#    - Owner at the tenant root MG: needed to create/associate management groups
#      and assign MG-scoped policies (DINE). Requires YOU to have elevated
#      access at root; if this line fails, either grant it via an admin, or drop
#      the management-groups / policies / policies-dine layers from CI.
if az role assignment create --assignee "$APP_ID" --role "Owner" \
  --scope "/providers/Microsoft.Management/managementGroups/${ROOT_MG}" >/dev/null 2>&1; then
  echo "  role: Owner @ tenant root MG"
else
  echo "  WARN: could not assign Owner at root MG (need elevated access)."
  echo "        CI can still run subscription-scoped layers (connectivity, dev)."
fi

cat <<EOF

────────────────────────────────────────────────────────────────────────────
Add to GitHub → Settings → Secrets and variables → Actions:

  Repository VARIABLES:
    AZURE_CLIENT_ID        = ${APP_ID}
    AZURE_TENANT_ID        = ${TENANT_ID}
    AZURE_SUBSCRIPTION_ID  = ${SUBSCRIPTION_ID}

  Repository SECRET:
    TF_VAR_ADMIN_PASSWORD  = <your Linux/Windows VM admin password>

Optional (gate the deploy): Settings → Environments → "production" →
  add Required reviewers.
────────────────────────────────────────────────────────────────────────────
EOF
