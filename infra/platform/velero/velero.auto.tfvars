# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.

org_name = "vinorg"
location = "southindia" # primary region — must match the dev landing zone

# storage_account_name is NOT set here: it is derived from infra/backend.json
# (stotfstatevinorg003 -> stovelerovinorg003). If an apply fails with
# StorageAccountAlreadyTaken, bump the suffix in backend.json and update the
# `storageAccount:` lines in k8s/gitops/platform/velero/values-{dev,dr}.yaml,
# which name it literally (Helm values, so Terraform cannot feed them). The
# argocd-bootstrap guard compares the two and fails the run if they drift.

# RAGRS = geo-replicated WITH a readable secondary. The secondary lands in
# southindia's Azure pair (centralindia), NOT in the DR region — pairing is a
# fixed property of the primary region, and indiasouthcentral has no pair. The
# DR cluster therefore reads backups one region away, which costs bandwidth and
# latency but not correctness.
#
# Downgrade to "LRS" only if you have decided DR means "rebuild in the same
# region" — LRS backups die with the region holding the cluster they protect.
account_replication_type = "RAGRS"

# Must exceed the longest backup TTL configured in
# k8s/gitops/platform/velero/schedules (daily = 720h/30d).
backup_soft_delete_days = 30

# Set false to apply this layer BEFORE the DR region exists — it then skips the
# landing-zones-dr state read entirely. Flip to true once DR is applied.
enable_dr = true
