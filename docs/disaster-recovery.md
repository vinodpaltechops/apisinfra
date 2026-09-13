# Disaster recovery

Multi-region active-passive: two AKS clusters, one Front Door, one geo-replicated
backup store, and GitOps keeping both clusters on the same commit.

```
                        internet
                           │
                  app.sometestdemo.in  (CNAME)
                           │
                 ┌─────────▼─────────┐
                 │  Azure Front Door │   anycast, ~100 PoPs
                 │  priority routing │   probes /healthz every 30s
                 └────┬─────────┬────┘
              priority 1        priority 2
                   │                 │
     ┌─────────────▼──────┐   ┌──────▼─────────────┐
     │ agw-dev  southindia│   │ agw-dr  indiasouth │  App Gateway WAF_v2
     │ (hub VNet 10.0.7)  │   │ (DR spoke 10.5.7)  │  OWASP 3.2 + FDID lock
     └─────────┬──────────┘   └──────────┬─────────┘
               │ 10.1.2.250              │ 10.5.2.250
     ┌─────────▼──────────┐   ┌──────────▼─────────┐
     │  aks-dev-lab-001   │   │  aks-dr-lab-001    │  private, 2 nodes each
     │  Argo CD + Velero  │   │  Argo CD + Velero  │
     └─────────┬──────────┘   └──────────┬─────────┘
               │                          │
               └──────────┬───────────────┘
                          ▼
              stovelerovinorg002  (RAGRS blob)
              primary/  ← written by dev, read by both
              dr/       ← written by dr
```

> ## ⚠ Current deployment: no Front Door
>
> Azure **forbids Front Door on Free Trial and Student subscriptions**:
>
> ```
> Code="BadRequest" Message="Free Trial and Student account is forbidden
> for Azure Frontdoor resources."
> ```
>
> This subscription is `FreeTrial_2014-09-01`, so the `frontdoor` job is
> commented out of `terraform-deploy.yml`. The layer, module and tfvars are
> intact and correct — it is a subscription restriction, not a config error.
>
> **What still works:** everything that makes DR real. Two regions, two private
> AKS clusters, two App Gateways, Argo CD converging both on the same commit,
> and Velero restoring a primary-region backup into the DR cluster.
>
> **What does not:** automatic failover. There is no health probe shifting
> traffic on its own, so the region-loss RTO below does **not** apply as
> written — see *Manual failover* in §8. Both gateways are reachable on their
> own public IPs and you move the DNS A record between them by hand.
>
> To restore the designed behaviour, upgrade to Pay-As-You-Go and follow the
> four-step re-enable list in `terraform-deploy.yml`. Be aware that lifting the
> spending limit starts real billing — the two App Gateway WAF_v2 instances
> alone are the dominant cost.

## Objectives, and what actually determines them

| | Target | What sets it |
| --- | --- | --- |
| **RTO** (region loss) | **~2–3 min** | Front Door health probes: 30s interval × 4 samples, 3 required. Nothing is deployed during failover — the DR cluster is already running the current release. |
| **RTO** (namespace/data loss) | **~10–30 min** | Velero restore time, dominated by volume size. |
| **RPO** (Kubernetes objects) | **0** | They are in Git and reconciled into both clusters continuously. Velero is not the recovery path for these. |
| **RPO** (volume data) | **≤ 1 hour** | `hourly-content-hub` schedule. The app is currently stateless, so this is a bound on future state, not present state. |

The RTO for region loss is short **because failover deploys nothing**. That is
the entire point of running Argo CD per-cluster rather than centrally — see
[k8s/gitops/README.md](../k8s/gitops/README.md).

## What protects what

Two very different failure classes, and it is worth being precise about which
component covers which — the common mistake is assuming Velero covers both.

**Region loss** → Front Door + the warm DR cluster. Velero plays no part.
Kubernetes objects come from Git, and the DR cluster is already running them.

**Data or namespace loss** (a bad migration, a deleted namespace, ransomware)
→ Velero. Git cannot help: it holds the desired state, not the *contents* of
volumes, and re-applying a manifest recreates an empty PVC.

Which is why the backups are configured the way they are:

- **Filesystem backup (Kopia), not disk snapshots.** An Azure managed-disk
  snapshot is region-locked and cannot be restored in the DR region without an
  explicit cross-region copy. Snapshots are much faster per GB, which is exactly
  what makes them tempting — and they would fail the only restore that matters.
- **RAGRS storage**, so the secondary copy is *readable* with no failover step.
  Plain GRS replicates identically but keeps the secondary invisible until you
  initiate an account failover — a slow, account-wide operation you do not want
  to discover mid-incident.

  Note where that secondary lands: **centralindia**, not the DR region.
  Replication targets the Azure *pair* of the account's own region
  (southindia → centralindia), and indiasouthcentral has no pair of its own. So
  the DR cluster reads backups one region away rather than locally — RA-GRS
  secondary endpoints are globally reachable, so this costs restore bandwidth
  and latency, not correctness. The property that matters is preserved: the
  backups are outside southindia.
- **No storage account keys at all** (`shared_access_key_enabled = false`).
  Every caller presents an Entra token. A leaked key would otherwise bypass
  every other control on the one thing ransomware goes looking for.
- **Blob versioning + 30-day soft delete**, so a Velero client that is
  compromised or simply buggy cannot make the bytes unrecoverable.

## Standing it up

Order matters. Layers 6–9 are the DR block in `terraform-deploy.yml`.

```
1-5. (existing)  management-groups → policies → connectivity → dev → appgw
6.   landing-zones/dr      spoke + private AKS in the DR region
7.   platform/velero       backup store, federates BOTH clusters
8.   platform/appgw-dr     DR region's App Gateway
9.   platform/frontdoor    global entry point
```

**Step 0 — create the state containers.** Each DR layer uses a new backend
container, and the azurerm backend does *not* create one: `terraform init`
fails with "container does not exist". They are declared in
`infra/platform/bootstrap`, which is deliberately outside `terraform-deploy`
because it owns the backend the pipeline itself uses. So this is manual, once:

```bash
terraform -chdir=infra/platform/bootstrap init
terraform -chdir=infra/platform/bootstrap apply   # adds landing-zones-dr, velero, appgw-dr, frontdoor
```

Additive and safe to re-run — `prevent_destroy` guards the existing containers
and no state file is touched.

**Then: policy, not quota.**

Quota works out with no request. Every Azure region defaults to 4 vCPU here,
and the workload divides into exactly 4-vCPU units:

| Region | Holds | vCPU |
| --- | --- | --- |
| southindia | hub + dev spoke + dev AKS (2 nodes) | 4/4 |
| centralindia | jump VNet + mgmt VM | 4/4 |
| indiasouthcentral | DR spoke + DR AKS (2 nodes) | 4/4 |

That is why DR sits in **indiasouthcentral** (Hyderabad) rather than
centralindia — the jump and mgmt VMs already fill centralindia's 4.

There is **no headroom** anywhere, and that has a consequence worth knowing
before you need it: an AKS node-pool rotation or node-image upgrade needs a
temporary surge of +2 vCPU, so both will fail at 4/4. Raise the relevant limit
to 6 first.

```bash
az vm list-usage --location indiasouthcentral -o table | grep -iE "total regional|DASv5"
```

What *does* need doing first is the **policy**. `allowed_locations` in
`infra/platform/policies` feeds a Deny assignment at the org root, so any
region missing from it fails the apply outright. `indiasouthcentral` is already
added; if you change `dr_location` again, add the new region there too and
apply that layer before the DR layer.

> **Do not use westindia.** It cannot run AKS at all — absent from
> `Microsoft.ContainerService/managedClusters`' location list, and
> `az vm list-skus --location westindia` returns **zero** VM SKUs. It still
> publishes vCPU quota entries, so checking quota alone makes it look like a
> free, quota-unconstrained alternative.

Then bootstrap GitOps into each cluster:

```bash
terraform -chdir=infra/platform/velero output -raw identity_client_id
# paste into BOTH k8s/gitops/platform/velero/values-{dev,dr}.yaml, commit

gh workflow run argocd-bootstrap.yml -f cluster=dev
gh workflow run argocd-bootstrap.yml -f cluster=dr
```

### The DNS cutover

Applying the frontdoor layer changes nothing users see — `app.sometestdemo.in`
still resolves to the primary gateway's A record until you move it by hand.
That is deliberate: the cutover stays a reversible, one-record decision.

```bash
terraform -chdir=infra/platform/frontdoor output dns_records
```

1. Create the `_dnsauth.app` **TXT** record. Wait for validation:
   ```bash
   az afd custom-domain show -g rg-frontdoor-vinorg-001 \
     --profile-name afd-vinorg-001 --custom-domain-name app-sometestdemo-in \
     --query domainValidationState -o tsv     # Pending → Approved
   ```
2. Replace the `app` **A** record with the **CNAME** to `<endpoint>.azurefd.net`.
3. Confirm traffic actually flows through Front Door, then close the origins:
   uncomment `allowed_source_prefixes` and `frontdoor_id` in **both**
   `appgw.auto.tfvars` and `appgw-dr.auto.tfvars`, and re-apply those layers.

Step 3 is what stops someone reaching a gateway's public IP directly and
bypassing Front Door's WAF, routing and failover. Restricting the NSG to
`AzureFrontDoor.Backend` alone is **not** sufficient — that service tag covers
every Front Door profile in Azure, including other tenants'. The `X-Azure-FDID`
header check is the half that actually identifies *your* profile.

Do not do step 3 before step 2. An FDID rule with no Front Door in front blocks
everything, health probes included.

---

# Runbooks

## 0. Manual failover (current setup — no Front Door)

Until Front Door is available, failover is a DNS change you make. Get both
gateway IPs:

```bash
terraform -chdir=infra/platform/appgw    output -raw appgw_public_ip   # southindia
terraform -chdir=infra/platform/appgw-dr output -raw appgw_public_ip   # indiasouthcentral
```

Both gateways serve the same `app_fqdn` on host-based listeners and read the
same certificate, so they are interchangeable targets — point the `app` A
record at whichever region you want live.

```bash
# verify the DR gateway serves the app BEFORE you need it
curl -H "Host: app.sometestdemo.in" http://<dr-gateway-ip>/healthz
```

Run that check on a schedule. It is the whole reason to have a warm standby,
and the failure it catches — a DR region that quietly stopped serving — is
invisible until the moment you depend on it.

Two properties to keep in mind, both consequences of DNS rather than anycast:

- **RTO is TTL-bound.** The record is at 600s, so budget ~10 minutes plus
  whatever clients cache beyond their instructions. Some cache far longer.
- **Nothing is automatic.** A region can fail at 3am and the site stays down
  until a human changes DNS. That gap is precisely what Front Door closes, and
  it is the honest reason this is a stopgap rather than a design.

---

## 1. Region failure — the primary is gone (WITH Front Door)

**Front Door handles this on its own.** There is no action to take to restore
service. Verify, then investigate.

```bash
# origin health as Front Door sees it
az afd origin list -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw -o table

# is the site up?
curl -sSf -o /dev/null -w '%{http_code}\n' https://app.sometestdemo.in/healthz
```

If the site is down while the DR origin is healthy, the problem is the DNS
cutover or the FDID lock, not the failover.

**Failing back** happens automatically once the primary's probe passes again.
Front Door drains over `restore_traffic_time_to_healed_or_new_endpoint_in_minutes`
(5 min), so in-flight requests are not cut off. To *prevent* automatic failback
while you investigate, disable the primary origin explicitly:

```bash
az afd origin update -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw --origin-name origin-primary --enabled-state Disabled
```

Re-enable it when you are ready. Do this rather than letting a flapping primary
pull traffic back and forth.

## 2. Forcing a failover (planned test — do this quarterly)

The point of a DR test is to find the thing that has silently broken since the
last one. Prefer the method that exercises the real path.

```bash
# Best: make the primary genuinely fail its probe, without touching Front Door.
# Scale the primary's frontend to zero — /healthz starts 503ing, Front Door
# notices within ~2 min and shifts to DR.
kubectl --context dev -n content-hub scale deploy/frontend --replicas=0

# watch from outside
while :; do curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' \
  https://app.sometestdemo.in/ ; sleep 5; done
```

Argo CD's `selfHeal` will scale it back up — that is the intended behaviour, so
either accept a short test window or suspend auto-sync on the `content-hub`
Application first:

```bash
kubectl --context dev -n argocd patch application content-hub \
  --type merge -p '{"spec":{"syncPolicy":null}}'
# ... test ...
kubectl --context dev -n argocd patch application content-hub --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

**What to actually check during the test** — the failover itself is the easy
part, and rarely what is broken:

- Does the DR cluster serve the **same build**? `kubectl --context dr -n content-hub get deploy -o jsonpath='{..image}'`
- Is the DR TLS certificate valid? Both gateways read the *same* Key Vault
  secret, so an expiry is regional only if someone copied it.
- Has DR's node count drifted? A DR cluster silently scaled to zero is the
  classic finding.

## 3. Restoring a namespace (Velero)

```bash
# from the mgmt VM, against whichever cluster you are recovering
velero backup get
velero restore create --from-backup hourly-content-hub-20260820011700 \
  --include-namespaces content-hub --wait
velero restore logs <restore-name>
```

**Argo CD will fight you** if you restore over a namespace it manages: the
restored objects differ from Git, and `selfHeal` reverts them within the
reconcile interval. Suspend auto-sync on the affected Application first, restore,
verify, then re-enable — the patch commands in runbook 2 apply here too.

For volume data specifically, this ordering is what you want anyway: Argo CD
recreates the *objects* correctly from Git in seconds; Velero is only needed for
the PVC *contents*.

## 4. Restoring the primary's backups into the DR cluster

This is the cross-region case the whole design exists for. The DR cluster
already has a read-only view of the primary's backups — nothing needs copying.

```bash
# on the DR cluster, the primary's backups appear under a second location
velero backup-location get           # default (dr/), primary-readonly (primary/)
velero backup get --selector velero.io/storage-location=primary-readonly

velero restore create --from-backup <primary-backup-name> \
  --include-namespaces content-hub --wait
```

`primary-readonly` is `accessMode: ReadOnly` deliberately. Without it, the DR
cluster's Velero would treat the primary's Kopia repository as its own and start
expiring the primary's backups against its own retention clock — destroying, in
the standby, exactly the thing the standby exists to restore from.

## 5. Rolling back a bad release

`git revert` is the rollback. Both clusters converge on whatever `main` says.

```bash
git revert <the deploy commit>
git push origin main
```

There is no `kubectl rollout undo` step any more — `selfHeal` would put the
committed image straight back within the reconcile interval.

## 6. Standing DR back down

Comment-out points, in the order you would use them:

| To remove | Do this |
| --- | --- |
| Front Door only | Restore the `app` **A** record to the primary gateway's IP **first**, then destroy `infra/platform/frontdoor`. Reverse order is a hard outage, not a fallback. |
| DR region | Comment out the DR block in `terraform-deploy.yml`; run the destroy pipeline. In `terraform-destroy.yml`, also change `dev: needs: [appgw, dr]` back to `needs: appgw`. |
| DR DNS zone | `enable_dr_region = false` in `infra/platform/connectivity/dr.tf`, apply, **then** comment out the file. Commenting first orphans the zone. |
| DR from Velero | `enable_dr = false` in `velero.auto.tfvars`. Removes the DR federated credential; backups untouched. |
| Front Door origin lock | Comment out `frontdoor_id` + `allowed_source_prefixes` in both appgw tfvars, re-apply. |

**`infra/platform/velero` is deliberately absent from the destroy pipeline.** It
holds the backup storage account, and destroying it deletes every backup — the
one thing a teardown must never take with it. Tear it down by hand, on purpose:

```bash
terraform -chdir=infra/platform/velero destroy
```

## Known gaps

Stated plainly, because a DR design that hides its gaps is worse than one that
does not exist.

- **The ACR is single-region.** On Basic, both clusters pull from
  `acrdevvinorg001` in southindia. During a primary-region failure the DR
  cluster keeps running images already on its nodes, but a scale-out, node
  replacement or rescheduled pod cannot pull. Fix: `acr_sku = "Premium"` +
  `acr_geo_replication_locations` in `dev.auto.tfvars` (~10× the cost; the login
  server name does not change, so nothing else needs editing).
- **The Key Vault holding the TLS certificate is single-region**, in the dev
  spoke. The DR gateway reads it through the AzureServices bypass. If that vault
  is unavailable *and* a gateway restarts, the DR gateway cannot fetch the
  certificate. Front Door's own managed certificate is unaffected.
- **The hub is single-region.** DNS resolution for both spokes goes through the
  hub Private DNS Resolver in southindia. A full southindia outage takes the
  resolver with it — the DR cluster keeps serving (its pods do not need the hub
  resolver for in-cluster DNS), but `kubectl` against its private API server
  from the mgmt VM would fail to resolve.
- **The mgmt VM is in centralindia**, a third region — so managing the DR
  cluster during a southindia outage depends on centralindia being up as well.
- **Backups are not co-located with the DR cluster.** The RAGRS secondary lands
  in centralindia (southindia's Azure pair); indiasouthcentral has no pair of
  its own. Restores into DR therefore pull across a region boundary. Correct,
  but slower than the earlier centralindia-DR design would have been — that is
  the trade made to avoid a quota increase.
- **Zero vCPU headroom in every region.** All three sit at 4/4, so an AKS
  node-pool rotation or node-image upgrade — each needing a +2 vCPU surge —
  fails until the limit is raised to 6. This is a latent operational blocker,
  not just a capacity note: it blocks patching.
- **DR capacity equals primary capacity, which is one node.** This is a warm
  standby sized for the current load, not headroom. Front Door sends *all*
  traffic to it on failover, and the HPA caps at 4 replicas with no cluster
  autoscaler.
- **No automated DR drill.** Runbook 2 is manual. The failure mode of every DR
  design is that nobody runs it until they need it.
