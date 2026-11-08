# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
# Subscription IDs are identifiers, not credentials — safe to commit.
#
# Deliberately EMPTY. Every layer deploys into the subscription Terraform is
# authenticated against (ARM_SUBSCRIPTION_ID in CI, the az CLI session locally),
# and main.tf defaults `landing_zones` to exactly that. Hardcoding the id here
# means moving subscriptions fails with ARM's "not found in the current tenant",
# because the old id belongs to a tenant this login can no longer see.
#
# Only fill this in when a branch genuinely lives in a DIFFERENT subscription
# from the one Terraform runs as:
#
# subscription_ids = {
#   "connectivity" = "<uuid>"
#   "identity"     = "<uuid>"
#   "dev"          = "<uuid>"
#   "qa"           = "<uuid>"
#   "prod"         = "<uuid>"
# }
