# Disaster recovery — complete reference

Everything about the DR setup in this repository: what exists, where it lives,
what protects what, how backups are taken, how a restore is performed, and what
happens — second by second — during a failover.

[docs/disaster-recovery.md](disaster-recovery.md) is the short operational
version. This document is the exhaustive one: every value, every dependency,
every failure mode, and the reasoning behind each.

**Source of truth.** Everything below is derived from the code in this
repository at commit `8c6dbda` on `feature/dr-multi-region-gitops`. Where a
value is a Terraform variable default that a tfvars file overrides, both are
shown. Live Azure state is not inspected here — see
[§13 Verification](#13-verification--what-to-check-and-how) for the commands
that confirm reality matches this document.

---

## Table of contents

1. [Design in one page](#1-design-in-one-page)
2. [Complete inventory](#2-complete-inventory)
3. [The traffic path, end to end](#3-the-traffic-path-end-to-end)
4. [RTO and RPO — targets and how they are derived](#4-rto-and-rpo--targets-and-how-they-are-derived)
5. [Failure-mode matrix — what protects what](#5-failure-mode-matrix--what-protects-what)
6. [The backup subsystem](#6-the-backup-subsystem)
7. [Restore procedures](#7-restore-procedures)
8. [Failover](#8-failover)
9. [Failback](#9-failback)
10. [Build order, state layout and toggles](#10-build-order-state-layout-and-toggles)
11. [The DNS cutover and the origin lock](#11-the-dns-cutover-and-the-origin-lock)
12. [DR drill — quarterly test plan](#12-dr-drill--quarterly-test-plan)
13. [Verification — what to check and how](#13-verification--what-to-check-and-how)
14. [Known gaps and open items](#14-known-gaps-and-open-items)
15. [Standing DR down](#15-standing-dr-down)
16. [Command quick reference](#16-command-quick-reference)

---

## 1. Design in one page

**Posture:** active–passive, two Azure regions, one public hostname.

**Four moving parts:**

| Part | What it does | Where it is defined |
| --- | --- | --- |
| **Azure Front Door** | Global anycast entry point. Priority-routes to the healthy region. This is the failover mechanism. | [infra/platform/frontdoor/](../infra/platform/frontdoor/), [infra/modules/frontdoor/](../infra/modules/frontdoor/) |
| **Two App Gateways (WAF_v2)** | One per region. TLS termination, OWASP 3.2 WAF, forwarding to that region's internal ingress. | [infra/platform/appgw/](../infra/platform/appgw/), [infra/platform/appgw-dr/](../infra/platform/appgw-dr/) |
| **Two AKS clusters, each with its own Argo CD** | Both continuously converge on the same Git commit. The standby is *warm* — already running the current release. | [infra/landing-zones/dr/](../infra/landing-zones/dr/), [k8s/gitops/](../k8s/gitops/) |
| **Velero → one RAGRS blob store** | Filesystem (Kopia) backups of both clusters into one geo-replicated container, cross-readable between regions. | [infra/platform/velero/](../infra/platform/velero/), [k8s/gitops/platform/velero/](../k8s/gitops/platform/velero/) |

**The single most important property:** *failover deploys nothing.* Because each
cluster runs its own Argo CD syncing the same repository, the DR cluster is
already running the current release before any incident starts. Recovery is
therefore bounded by Front Door's health-probe window (~2 minutes), not by a
deployment.

**The second most important property:** Velero is **not** the region-failure
recovery path. It exists for data loss, namespace deletion and ransomware.
Conflating the two is the most common way a DR design turns out not to work.

```
                        internet
                           │
                  app.sometestdemo.in  (CNAME → *.azurefd.net)
                           │
                 ┌─────────▼─────────┐
                 │  Azure Front Door │   anycast, ~100 PoPs
                 │  afd-vinorg-001   │   HEAD /healthz every 30s per PoP
                 │  strict priority  │   4 samples, 3 must pass
                 └────┬─────────┬────┘
              priority 1        priority 2
                   │                 │
     ┌─────────────▼──────┐   ┌──────▼─────────────┐
     │ agw-dev-vinorg-001 │   │ agw-dr-vinorg-001  │  App Gateway WAF_v2
     │ southindia         │   │ indiasouthcentral  │  OWASP 3.2, Prevention
     │ hub VNet 10.0.7/24 │   │ DR spoke 10.5.7/24 │  + X-Azure-FDID lock
     └─────────┬──────────┘   └──────────┬─────────┘
               │ 10.1.2.250              │ 10.5.2.250   (internal LB VIPs)
     ┌─────────▼──────────┐   ┌──────────▼─────────┐
     │  aks-dev-lab-001   │   │  aks-dr-lab-001    │  private clusters
     │  Argo CD + Velero  │   │  Argo CD + Velero  │  2 nodes each
     │  content-hub ns    │   │  content-hub ns    │  same commit, always
     └─────────┬──────────┘   └──────────┬─────────┘
               │ writes primary/          │ writes dr/, READS primary/
               └──────────┬───────────────┘
                          ▼
              stovelerovinorg001   (southindia, RAGRS)
              container: velero
                primary/  ← written by dev, read by both
                dr/       ← written by dr
              RA secondary copy lands in centralindia
```

---

## 2. Complete inventory

### 2.1 Regions and what each holds

| Region | Contents | vCPU used / limit |
| --- | --- | --- |
| **southindia** (Chennai) | Hub VNet, dev spoke, `aks-dev-lab-001` (2 nodes), `agw-dev-vinorg-001`, Key Vault `kv-dev-lab-d5f9ug`, ACR `acrdevvinorg001`, Velero storage account | 4 / 4 |
| **centralindia** (Pune) | Jump VNet `vnet-jump-dev-001` (10.4.0.0/24), mgmt VM. Also receives the RAGRS **secondary** copy of the backup store. | 4 / 4 |
| **indiasouthcentral** (Hyderabad) | DR spoke, `aks-dr-lab-001` (2 nodes), `agw-dr-vinorg-001` | 4 / 4 |

`dr_location = "indiasouthcentral"` is defined **once**, in
[infra/platform/connectivity/dr.tf:89](../infra/platform/connectivity/dr.tf#L89),
and read by every other layer through the `dr_location` output. Reasons for that
region, from the same file: it is the only India region with 4 free vCPU (the
jump + mgmt VMs consume centralindia's), it is genuinely separate infrastructure
from Chennai and Pune, and it exposes 3 availability zones.

> **Never set `dr_location = "westindia"`.** West India cannot run AKS —
> it is absent from `Microsoft.ContainerService/managedClusters`' location
> list, and `az vm list-skus --location westindia` returns zero VM SKUs. It
> still publishes vCPU quota entries, so checking quota alone makes it look
> like a free alternative.

### 2.2 Network addressing

| Network | CIDR | Notes |
| --- | --- | --- |
| Hub VNet (southindia) | `10.0.0.0/16` | App Gateway subnet `snet-appgw` = `10.0.7.0/24` |
| Dev spoke | `10.1.0.0/16` | ingress VIP `10.1.2.250` |
| Jump VNet (centralindia) | `10.4.0.0/24` | mgmt VM; peered to hub **and** to both spokes |
| **DR spoke** | `10.5.0.0/16` | see below |
| `snet-aks-system-dr` | `10.5.1.0/24` | system node pool |
| `snet-aks-user-dr` | `10.5.2.0/24` | user node pool + **ingress VIP `10.5.2.250`** |
| `snet-app-dr` | `10.5.3.0/24` | unused today; NAT-gateway attached |
| `snet-data-dr` | `10.5.4.0/24` | unused today; NAT-gateway attached |
| `snet-appgw` (DR) | `10.5.7.0/24` | created by the appgw module inside the DR spoke |
| DR AKS pod CIDR (overlay) | `100.64.0.0/16` | RFC 6598; deliberately different from dev's `192.168.0.0/16` |
| AKS service CIDR (both) | `172.16.0.0/16` | `dns_service_ip = 172.16.0.10` |

The DR ingress VIP `10.5.2.250` appears in **three** places that must stay in
sync — it is a static address precisely so the App Gateway backend pool survives
the Service being recreated:

1. [infra/landing-zones/dr/main.tf:85](../infra/landing-zones/dr/main.tf#L85) (`local.ingress_internal_ip`, exported as an output)
2. [k8s/platform/ingress-nginx-values-dr.yaml:34](../k8s/platform/ingress-nginx-values-dr.yaml#L34) (`azure-load-balancer-ipv4`)
3. the DR App Gateway backend pool, which reads it from the DR landing zone's state rather than re-typing it

### 2.3 Peerings

| Peering | Type | Why |
| --- | --- | --- |
| DR spoke ↔ hub | Global | Carries DNS queries to the hub Private DNS Resolver — that is what resolves the DR cluster's private API FQDN |
| jump VNet ↔ DR spoke | Global | VNet peering is **non-transitive**, so jump↔hub does not reach the DR spoke. The mgmt VM needs a direct route to run `kubectl` against the DR API server |

Both halves of the jump↔DR peering are declared in the **DR layer**
([infra/landing-zones/dr/main.tf:212-234](../infra/landing-zones/dr/main.tf#L212-L234))
so that destroying that layer removes them cleanly, and they are serialised with
`depends_on` because Azure rejects concurrent writes to the two sides of a
peering pair.

### 2.4 DNS

| Zone | Linked to | Purpose |
| --- | --- | --- |
| `privatelink.southindia.azmk8s.io` | Hub VNet | Dev cluster's private API server A-record |
| `privatelink.indiasouthcentral.azmk8s.io` | Hub VNet | **DR** cluster's private API server A-record |

Two zones are required because the privatelink AKS zone name embeds the
*cluster's* region, not the hub's. Pointing the DR cluster at the southindia
zone produces an FQDN nothing ever registers into, and the cluster create fails
~45 minutes in during private-cluster reconcile with an unresolvable API server.

Both zones are linked to the **hub only**. Every spoke sets its VNet DNS servers
to the hub resolver's inbound IP, so a lookup from any spoke is answered from
whichever hub-linked zone matches the name — including across regions.

### 2.5 Compute

| Cluster | Region | Nodes | VM size | Private | Pod networking |
| --- | --- | --- | --- | --- | --- |
| `aks-dev-lab-001` | southindia | 1 system + 1 user | `Standard_D2as_v5` | yes, BYO DNS zone | Azure CNI Overlay |
| `aks-dr-lab-001` | indiasouthcentral | 1 system + 1 user | `Standard_D2as_v5` | yes, BYO DNS zone | Azure CNI Overlay |

Both clusters have `oidc_issuer_enabled = true` and
`workload_identity_enabled = true` — that is the prerequisite for Velero's
secret-less authentication ([§6.3](#63-the-authentication-chain-step-by-step)).

The system pool carries `only_critical_addons_enabled = true`
(`CriticalAddonsOnly` taint); the user pool is labelled
`nodepool-type: user`, which every platform component's `nodeSelector` targets.

### 2.6 Shared, single-region dependencies

These are deliberately **not** duplicated in the DR region. Each is a
documented trade-off, and each is also a gap — see [§14](#14-known-gaps-and-open-items).

| Resource | Region | Why shared | Consequence |
| --- | --- | --- | --- |
| ACR `acrdevvinorg001` | southindia | One build is deployable in both regions with no promotion step | Basic SKU is single-region: during a southindia outage the DR cluster runs images already on its nodes but cannot pull new ones |
| Key Vault `kv-dev-lab-d5f9ug` | southindia (dev spoke) | Both gateways serve `app.sometestdemo.in`, so both need the same certificate. One vault entry = one renewal | If the vault is unavailable *and* a gateway restarts, the DR gateway cannot fetch the certificate |
| Hub Private DNS Resolver | southindia | Single resolution path for both spokes | A southindia outage takes it with it: DR pods keep serving (in-cluster DNS is CoreDNS), but `kubectl` against the DR private API server would fail to resolve |
| mgmt VM | centralindia | One bastion replacement drives both clusters | Managing DR during a southindia outage also depends on centralindia |

The DR gateway reads the certificate through Key Vault's **AzureServices bypass**
(`public_network_access_enabled = true`, `default_action = Deny`), which is not
region-scoped — the same path the primary gateway already uses. The appgw module
creates a *separate* managed identity per gateway and grants each `Key Vault
Secrets User`, so the two assignments never collide.

### 2.7 Terraform layers and state

One state file per layer, all in `stotfstatevinorg002` /
`rg-tfstate-vinorg-001`. The DR add-on introduces four new containers:

| Layer | Container | Key | Purpose |
| --- | --- | --- | --- |
| [infra/landing-zones/dr](../infra/landing-zones/dr/) | `landing-zones-dr` | `landing-zones-dr.tfstate` | DR spoke + private AKS |
| [infra/platform/velero](../infra/platform/velero/) | `velero` | `velero.tfstate` | Backup store + identity + federation |
| [infra/platform/appgw-dr](../infra/platform/appgw-dr/) | `appgw-dr` | `appgw-dr.tfstate` | DR App Gateway |
| [infra/platform/frontdoor](../infra/platform/frontdoor/) | `frontdoor` | `frontdoor.tfstate` | Global entry point |

The azurerm backend does **not** create its container; `terraform init` fails
with "container does not exist". All four names are declared in
[infra/platform/bootstrap/main.tf](../infra/platform/bootstrap/main.tf#L71-L110)
and must be applied by hand **before** any DR layer is first planned — bootstrap
is deliberately outside `terraform-deploy.yml` because it owns the backend the
pipeline itself uses.

### 2.8 Cross-layer state reads

The dependency graph that forces the deploy order:

```
connectivity ──dr_location, aks_dr_private_dns_zone_id, hub_*──▶ landing-zones/dr
landing-zones/dev ──mgmt VM identity, ACR name, RG name──────▶ landing-zones/dr
landing-zones/dev ──aks_oidc_issuer_url, node RG───────────────▶ platform/velero
landing-zones/dr  ──aks_oidc_issuer_url, node RG───────────────▶ platform/velero
landing-zones/dr  ──location, RG, ingress VIP──────────────────▶ platform/appgw-dr
platform/appgw    ──appgw_public_ip (priority 1)───────────────▶ platform/frontdoor
platform/appgw-dr ──appgw_public_ip (priority 2)───────────────▶ platform/frontdoor
```

Note the *reverse* consequence: **DR must be destroyed before dev**, because DR
reads dev's state and owns both halves of the jump↔DR peering. The destroy
pipeline sequences it that way (`dev: needs: [appgw, dr]`).

---

## 3. The traffic path, end to end

A single request, in order, with the configuration that governs each hop:

| # | Hop | Configuration |
| --- | --- | --- |
| 1 | Client → `app.sometestdemo.in` | CNAME to `fde-vinorg-<random6>.azurefd.net`. The anycast address never changes, so failover requires no DNS change and no TTL wait |
| 2 | Front Door edge | Custom domain with an **Azure-managed certificate**, `minimum_tls_version = TLS12`. `https_redirect_enabled = true`; `link_to_default_domain = false` so the app is *only* reachable on the custom domain |
| 3 | Route `route-app` | `patterns_to_match = ["/*"]`, `supported_protocols = [Http, Https]`, `forwarding_protocol = HttpsOnly`. Caching: compression on for HTML/CSS/JS/JSON/SVG, `IgnoreQueryString` |
| 4 | Origin group `og-appgw` | Strict priority. `origin-primary` priority 1, `origin-dr` priority 2, `additional_latency_in_milliseconds = 0`, `restore_traffic_time_to_healed_or_new_endpoint_in_minutes = 5` |
| 5 | Front Door → App Gateway | Over the public internet to the gateway's **public IP**, on 443. `origin_host_header = app.sometestdemo.in` — it must be the real FQDN, because the gateway's listener and the ingress rule are both host-based. `certificate_name_check_enabled = false` (a certificate can never match a bare IP) |
| 6 | App Gateway NSG | `allow-gateway-manager` (GatewayManager → 65200-65535, mandatory), `allow-azure-lb`, `allow-web-inbound` on 80/443 from `allowed_source_prefixes` |
| 7 | App Gateway WAF policy | `Prevention` mode, OWASP 3.2 managed rule set, `request_body_check = true`, max body 128 KB, upload limit 100 MB. Plus the **X-Azure-FDID custom rule** at priority 1 when `frontdoor_id` is set |
| 8 | App Gateway listener | Host-based on `app.sometestdemo.in`. `:443` with the Key Vault certificate; `:80` also serves the app (`http_redirect_to_https = false`) so a direct-to-origin `curl` remains possible while debugging |
| 9 | App Gateway → ingress | Backend pool = the region's internal LB VIP, HTTP on :80, `request_timeout = 30`, `host_name = app_fqdn` re-sent so the host-based Ingress rule matches |
| 10 | ingress-nginx (`nginx-internal`) | Internal LB, `externalTrafficPolicy: Local`, 1 replica (a PDB above 1 makes a single-node pool undrainable) |
| 11 | Ingress rules | `/api` → `backend:8000`, `/` → `frontend:8080` |

### 3.1 Health probes — three tiers, one endpoint

| Probe | Configured where | Target | Interval | Failure threshold |
| --- | --- | --- | --- | --- |
| Front Door → gateway | [modules/frontdoor/main.tf:87-101](../infra/modules/frontdoor/main.tf#L87-L101) | `HEAD https://<gw-ip>/healthz` with Host `app.sometestdemo.in` | 30s **per edge PoP** | 4 samples, 3 must pass |
| App Gateway → ingress | [modules/appgw/main.tf:344-356](../infra/modules/appgw/main.tf#L344-L356) | `GET http://<VIP>/healthz`, match 200-399 | 30s, timeout 30s | 3 consecutive failures |
| kubelet → frontend pod | [k8s/base/frontend.yaml](../k8s/base/frontend.yaml#L66-L75) | `GET /healthz` (startup, liveness, readiness) | pod defaults | pod defaults |

All three probe **the same application endpoint**, which is the point: "healthy"
means the same thing at every tier — the frontend pod answered, not merely that
a TCP port is open. `/healthz` is served by nginx in the frontend container
([apps/frontend/nginx/default.conf.template](../apps/frontend/nginx/default.conf.template));
the two Python services expose their own `/healthz` and `/readyz`, where
readiness (but never liveness) depends on downstream availability.

Front Door uses `HEAD` because it is cheaper than `GET` at ~100 PoPs × 30s. That
is only safe because `/healthz` answers HEAD as well — an endpoint implementing
only GET would report healthy forever under a HEAD probe.

---

## 4. RTO and RPO — targets and how they are derived

| Scenario | Objective | Value | What actually determines it |
| --- | --- | --- | --- |
| **Region loss** (southindia gone) | **RTO** | **~2–3 min** | Front Door probe window: 30s interval × 4 samples, 3 required. Nothing is deployed — the DR cluster already runs the current release |
| Region loss | **RPO** — Kubernetes objects | **0** | They live in Git and are reconciled continuously into both clusters. Velero is not involved |
| Region loss | **RPO** — volume data | **≤ 1 hour** | `hourly-content-hub` schedule. The app is currently stateless, so this bounds *future* state |
| **Namespace / data loss** | **RTO** | **~10–30 min** | Velero restore time, dominated by volume size and cross-region bandwidth |
| Namespace / data loss | **RPO** | **≤ 1 hour** | Same hourly schedule |
| **Bad release** | **RTO** | **~3–5 min** | `git revert` + push; both clusters' Argo CD reconcile within ~3 min |
| **Bad release** | **RPO** | **0** | Git history is the recovery source |

### 4.1 Deriving the region-loss RTO

With `sample_size = 4` and `successful_samples_required = 3`, an origin is
declared unhealthy as soon as **2 of the last 4 samples fail**. At a 30s
interval that is a **60–120 second detection window**, per edge PoP.

```
t+0s      southindia becomes unreachable
t+0-30s   each PoP's next probe to origin-primary times out      (sample 1 fails)
t+30-60s  second probe fails                                     (sample 2 fails)
          → only 2 of the last 4 can succeed → origin-primary UNHEALTHY
t+60-120s each PoP independently shifts new connections to origin-dr (priority 2)
t+~120s   effectively all traffic served from indiasouthcentral
```

Front Door evaluates health **per PoP**, so the shift is staggered rather than
instantaneous globally — a user in one geography may recover slightly before
another. In-flight requests that were already routed to the dead origin fail;
clients that retry are routed to DR. Adding client retry and TLS handshake time
gives the ~2–3 minute figure quoted above.

**Why not tighter?** A shorter window makes a transient blip trigger a
cross-region failover, and flapping between regions is worse than a brief 502
from one. `additional_latency_in_milliseconds = 0` is equally load-bearing: any
positive value tells Front Door to treat origins within that latency band as
equivalent and spread traffic across them, which would silently convert this
active-passive design into active-active against a standby sized for neither.

### 4.2 Deriving the RTO for an *application* failure in the primary

Different chain, and slower, because the App Gateway must notice first:

```
t+0s      frontend pods stop answering /healthz in southindia
t+0-90s   App Gateway probe: 3 consecutive failures at 30s → backend Unhealthy
t+90s     gateway starts returning 502 to Front Door's probes
t+90-150s Front Door accumulates 2 failing samples → origin-primary UNHEALTHY
t+150s+   traffic shifts to DR
```

So ~2.5–3.5 minutes for a pod-level failure, versus ~2 minutes for a region
loss. Worth knowing, because the most likely real incident is the slower one.

### 4.3 What would invalidate these numbers

- **The DNS cutover has not been done.** If `app.sometestdemo.in` is still an A
  record to the primary gateway, Front Door is inert and the RTO for region loss
  is *unbounded* — there is no failover at all. See [§11](#11-the-dns-cutover-and-the-origin-lock).
- **The DR cluster has drifted.** A DR cluster silently scaled to zero, or
  running an older commit because its Argo CD is out of sync, turns a 2-minute
  failover into an outage.
- **The certificate expired.** Both gateways read the same Key Vault secret, so
  expiry is global rather than regional — unless someone copied the certificate
  into a second vault, in which case it is regional and invisible until failover.
- **ACR is unreachable and DR needs to pull.** A pod reschedule during failover
  requires the single-region ACR.
- **RPO ≤ 1 hour assumes the hourly schedule is running.** A Schedule paused by
  hand is un-paused by Argo CD's `selfHeal` within the reconcile interval — but
  a Velero server that cannot authenticate fails every backup while reporting
  Healthy. That is why the bootstrap workflow guards the identity client-id.

---

## 5. Failure-mode matrix — what protects what

The single most common misconception is that Velero covers region loss. It does
not, and it is not meant to.

| Failure | Detected by | Recovery mechanism | Human action | Data loss |
| --- | --- | --- | --- | --- |
| Primary region down | Front Door health probe | Automatic shift to priority-2 origin | **None** — verify only | None (stateless app) |
| Primary App Gateway down | Front Door health probe | Same | None | None |
| Primary AKS API server down | App Gateway probe → Front Door probe | Same (running pods keep serving until the gateway probe fails; a true control-plane-only outage may not fail the probe at all) | Investigate | None |
| Primary ingress or app pods down | App Gateway probe → Front Door probe | Same, ~3 min | None; investigate | None |
| Namespace deleted | Argo CD (OutOfSync) | Argo CD recreates objects from Git within the reconcile interval; Velero restores PVC **contents** | Suspend auto-sync → `velero restore` → re-enable | ≤ 1 h of volume data |
| Bad release deployed | Users / monitoring | `git revert` → both clusters converge | Revert + push | None |
| Volume data corrupted | Application | Velero restore from a pre-corruption backup | Runbook [§7.1](#71-restoring-a-namespace-into-the-same-cluster) | Down to the chosen backup |
| Ransomware / malicious delete in-cluster | Investigation | Blob versioning + 30-day soft delete + no storage keys | Runbook [§7.5](#75-recovering-a-deleted-or-overwritten-backup) | Bounded by soft-delete window |
| Backup storage account primary down | Velero errors | RA-GRS read-only secondary in centralindia, reachable with **no failover step** | Point restores at the secondary endpoint | None (backups are read-only during the outage) |
| Certificate expired | TLS errors at both gateways | Rotate in Key Vault; both gateways use the **unversioned** secret URL and pick it up automatically | Rotate | None |
| ACR down during a DR failover | Image pull errors on reschedule | None today — a genuine gap | Avoid rescheduling; long-term fix is Premium + geo-replication | None |

---

## 6. The backup subsystem

Two halves, deliberately split: the **Azure half** is Terraform
([infra/platform/velero](../infra/platform/velero/) →
[infra/modules/velero-backend](../infra/modules/velero-backend/)); the
**in-cluster half** is GitOps
([k8s/gitops/platform/velero](../k8s/gitops/platform/velero/) and
[k8s/gitops/platform/backup-schedules](../k8s/gitops/platform/backup-schedules/)).
The Terraform layer creates **zero** Kubernetes objects.

### 6.1 The Azure half — storage, identity, federation

**Resource group `rg-velero-vinorg-001`** (southindia) is separate from both
spokes on purpose: deleting a spoke's resource group is a normal, recoverable
operation and it must not take the backups with it.

**Storage account `stovelerovinorg001`:**

| Setting | Value | Why |
| --- | --- | --- |
| `account_tier` / `account_kind` | Standard / StorageV2 | — |
| `account_replication_type` | **RAGRS** | Geo-replicated **with a readable secondary**. Plain GRS replicates identically but keeps the secondary invisible until an account-wide failover — a slow operation you do not want to discover mid-incident. LRS is not a DR configuration at all |
| `access_tier` | Hot | Restores are latency-sensitive; Cool adds per-GB read cost |
| `shared_access_key_enabled` | **`false`** | The account has **no access keys at all**, so no SAS can be minted. Every caller presents an Entra token and holds an RBAC role. This is the single most valuable control on a backup store — backups are what ransomware goes looking for |
| `min_tls_version` | TLS1_2 | — |
| `allow_nested_items_to_be_public` | `false` | — |
| `public_network_access_enabled` | `true` | See the note below |
| `versioning_enabled` | `true` | A compromised or buggy Velero client calling delete cannot make the bytes unrecoverable |
| `delete_retention_policy.days` | **30** | Blob soft delete |
| `container_delete_retention_policy.days` | **30** | Container soft delete |
| Container | `velero` (private) | Shared by both clusters, separated by prefix |

`network_rules` is deliberately **not** set
([modules/velero-backend/main.tf:72-79](../infra/modules/velero-backend/main.tf#L72-L79)):
the account has no keys, so its only door is Entra + RBAC, and the two clusters
reach it from load-balancer egress IPs in two regions that Azure may rotate.
An IP allowlist buys little and breaks backups *silently* when an egress IP
changes — the failure surfaces as a missed backup, which nobody notices until a
restore. The real hardening step is a private endpoint plus a
`privatelink.blob` zone link per region.

**Identity `id-velero`** (user-assigned) holds:

- `Storage Blob Data Contributor` at the **storage account** scope. Read *and*
  write, because Velero uploads backup tarballs and Kopia repository data and
  prunes them at TTL expiry. `Blob Data Owner` would additionally allow changing
  ACLs, which Velero never does.
- Two **federated identity credentials** — `fedcred-velero-primary` and
  `fedcred-velero-dr` — each with:
  - `issuer` = that cluster's OIDC issuer URL
  - `subject` = `system:serviceaccount:velero:velero`
  - `audience` = `api://AzureADTokenExchange`

**One identity, two clusters, one container.** That is what lets the DR cluster
read backups the primary wrote without copying anything.

**Snapshot role: off.** `enable_snapshot_role` defaults to `false`, so the
`snapshot_scopes` passed by the velero layer generate nothing. Only the
CSI/volume-snapshot data mover would need it, and this design deliberately does
not use snapshots ([§6.2](#62-the-in-cluster-half--why-filesystem-backup)). If
you ever turn it on, note the module grants broad `Contributor` on each cluster's
`MC_*` node resource group; narrowing it to `Disk Snapshot Contributor` +
`Disk Contributor` is the better shape.

### 6.2 The in-cluster half — why filesystem backup

**Velero Helm chart `8.2.0`, pinned identically in both clusters**
([apps/dev/velero.yaml](../k8s/gitops/apps/dev/velero.yaml#L25),
[apps/dr/velero.yaml](../k8s/gitops/apps/dr/velero.yaml#L23)), plus
`velero/velero-plugin-for-microsoft-azure:v1.11.1` loaded as an init container.
The pin must match across regions: a backup written by one Kopia repository
format is not guaranteed readable by a different one, and the DR cluster exists
to read the primary's backups.

**The single most important configuration choice in the whole DR design:**

```yaml
configuration:
  volumeSnapshotLocation: []      # explicitly empty, not omitted
  defaultVolumesToFsBackup: true  # Kopia filesystem backup
```

An Azure managed-disk snapshot is **region-locked**. A snapshot taken in
southindia cannot be attached to a node in indiasouthcentral without an explicit
cross-region copy — a manual, slow step you would be discovering during an
incident. Snapshots are much faster per GB, which is exactly what makes them
tempting, and they would quietly fail the only restore that matters.

Kopia filesystem backup reads the volume through the node agent and writes into
blob storage, which is geo-replicated. The DR cluster restores from the same
container with no copy step and no region awareness. Slower per GB; the only
option that actually crosses a region boundary.

`volumeSnapshotLocation: []` must be **explicitly empty**. The chart's default
for that key is a single-element list, so omitting it renders a
`VolumeSnapshotLocation` with an empty `provider`, which Velero rejects at
startup and Argo CD reports as permanently Progressing.

`defaultVolumesToFsBackup: true` backs up every pod volume rather than requiring
an opt-in annotation per pod. Opt-in is how volumes get silently missed.

**Node agent (Kopia) is a DaemonSet** — `deployNodeAgent: true`, with a
`CriticalAddonsOnly` toleration so it also runs on the tainted system pool. No
node agent on a node means no volume data from that node, and **the backup still
reports Completed**, carrying manifests but no files. Memory limit is 512Mi
because Kopia buffers while hashing and uploading; too low a ceiling shows up as
an OOMKilled agent mid-backup and a PartiallyFailed backup.

**Per-cluster differences — the entire delta between the two values files:**

| | `values-dev.yaml` (primary) | `values-dr.yaml` (DR) |
| --- | --- | --- |
| BSL `default` prefix | `primary/` | `dr/` |
| Second BSL | — | `primary-readonly`, prefix `primary/`, **`accessMode: ReadOnly`** |
| Everything else | identical | identical |

The prefixes are what keep two Velero instances sharing one container apart.
Identical prefixes would let each believe it owns the same Kopia repository, and
they would prune each other's backups as expired.

**`accessMode: ReadOnly` on `primary-readonly` is load-bearing.** Without it,
the DR cluster's Velero would treat the primary's Kopia repository as its own
and start expiring the primary's backups against its own retention clock —
destroying, in the standby, exactly the thing the standby exists to restore
from.

Other notable values (identical in both files):

- `credentials.useSecret: false` — no credentials Secret exists in either cluster
- `podLabels: azure.workload.identity/use: "true"` — without this the webhook injects nothing and Velero looks for a credentials file that does not exist
- `defaultBackupTTL: 720h` (30 days)
- `nodeSelector: nodepool-type: user` for the server (the node agent is a DaemonSet and runs everywhere)
- `upgradeCRDs: false`, `cleanUpCRDs: false` — Argo CD applies CRDs from the chart with ServerSideApply, so the chart's hook job would race the sync
- `metrics.enabled: false` — no Prometheus in these clusters

### 6.3 The authentication chain, step by step

No secrets anywhere. The chain:

```
1. Velero pod carries label   azure.workload.identity/use: "true"
2. The workload-identity webhook injects a projected SA token + env vars
3. Velero presents that token to the cluster's OIDC issuer
4. Entra matches issuer + subject (system:serviceaccount:velero:velero)
   against a federated identity credential on id-velero
5. Entra returns an access token for id-velero
6. id-velero holds Storage Blob Data Contributor on stovelerovinorg001
7. Velero reads/writes blobs. useAAD: "true" — there is no key to fall back on
```

**Four values must agree exactly, or the exchange fails:**

| Value | Must be | Defined in |
| --- | --- | --- |
| Namespace | `velero` | Argo CD Application `destination.namespace` |
| ServiceAccount name | `velero` | `serviceAccount.server.name` in the values files |
| `azure.workload.identity/client-id` annotation | the **client** id of `id-velero` | both values files |
| Federated credential subject | `system:serviceaccount:velero:velero` | [modules/velero-backend/main.tf:129](../infra/modules/velero-backend/main.tf#L129) |

Failure signatures worth memorising:

- **`AADSTS70021` — no matching federated identity record.** The namespace or SA
  name does not match the federated credential subject.
- **`AADSTS700016` — application not found.** Someone pasted the *principal
  (object)* id instead of the **client** id.
- Both surface as "failed to get credentials" on every backup, while the Velero
  pod itself runs happily and Argo CD reports Healthy.

That last property is why
[.github/workflows/argocd-bootstrap.yml:93-110](../.github/workflows/argocd-bootstrap.yml#L93-L110)
refuses to bootstrap while the values file still holds
`REPLACE_WITH_VELERO_IDENTITY_CLIENT_ID`, and prints the exact value to paste:

```bash
terraform -chdir=infra/platform/velero output -raw identity_client_id
```

> **Current repository state:** both `values-dev.yaml` and `values-dr.yaml`
> still contain the `REPLACE_WITH_VELERO_IDENTITY_CLIENT_ID` placeholder. Until
> the real client id is committed, Velero cannot authenticate and **no backup
> will succeed**. See [§14.2](#142-open-items-in-the-repository-as-committed).

### 6.4 Schedules — what is backed up, and when

Defined as plain `Schedule` CRs in
[base/schedules.yaml](../k8s/gitops/platform/backup-schedules/base/schedules.yaml)
(kustomize-patchable, unlike Helm values), with a DR overlay that only changes
the cron times.

| Schedule | Primary cron | DR cron | Scope | TTL | Cluster-scoped resources |
| --- | --- | --- | --- | --- | --- |
| `hourly-content-hub` | `17 * * * *` | `37 * * * *` | `includedNamespaces: [content-hub]` | **48h** | `false` |
| `daily-full` | `40 2 * * *` (02:40 UTC ≈ 08:10 IST) | `0 3 * * *` | everything **except** `kube-system`, `gatekeeper-system`, `velero`, `argocd` | **720h (30d)** | `true` |

Both use `defaultVolumesToFsBackup: true` and `storageLocation: default` (so
each cluster writes to its own prefix — the DR cluster never writes into
`primary/`).

**Why the odd minutes.** Every cron-driven system in the world fires on the
hour; offsetting spreads load on the storage account and makes the backup's
timing distinguishable in logs. The DR overlay offsets by a further ~20 minutes
because both clusters write into the *same* storage account and each has 2 vCPU
to share between the backup and the application — two simultaneous Kopia uploads
is how a backup system becomes the outage.

**Why those exclusions on `daily-full`:**

- `kube-system` / `gatekeeper-system` — cluster-specific and rebuilt by AKS.
  Restoring them over a live cluster reliably breaks it: the objects reference
  node names, IPs and CA data that differ between clusters.
- `velero` — a backup containing the backup system's own state, restored by that
  same system, is a circular dependency with no upside.
- `argocd` — Argo CD reconstructs itself from Git; its live state is derived,
  not authoritative. Restoring stale `Application` objects over a healthy Argo CD
  makes it fight the repo.

**`hourly` excludes cluster-scoped resources; `daily` includes them.** That is
the difference between a namespace restore and a cluster rebuild.

**`skipImmediately: false`** on the hourly: skip a run rather than queue it if
the previous is still going.

**Argo CD delivery.** `velero` is at sync-wave `-1`, `backup-schedules` at `0`,
because `Schedule` is a Velero CRD and applying it before the chart registers
that CRD fails with "no matches for kind Schedule". CRD establishment is
asynchronous, so the `backup-schedules` Application's retry policy (5 attempts,
15s backoff ×2 up to 3m) is what actually covers the race.

`selfHeal: true` matters more on `backup-schedules` than anywhere else: a
Schedule paused by hand during an incident and then forgotten is a backup system
that has silently stopped. Argo CD un-pauses it within the reconcile interval.

### 6.5 What is in a backup, and what is not

| Content | In a Velero backup? | Real recovery source |
| --- | --- | --- |
| Deployments, Services, Ingresses, ConfigMaps | Yes | **Git** — Argo CD reconstructs them in seconds. The backup copy is for the "namespace deleted and the last good state is not the last commit" case |
| PersistentVolume **contents** | Yes, via Kopia | **Velero only.** Not in Git, reconstructible from nowhere. This is the entire reason Velero exists in a GitOps stack |
| Secrets in the namespace | Yes | Velero (they are namespace objects) |
| CRDs, ClusterRoles, StorageClasses | Only in `daily-full` | Velero / Git |
| Container images | **No** | ACR |
| Key Vault certificates | **No** | Key Vault (single region — a gap) |
| Terraform state | **No** | `stotfstatevinorg002` |
| Azure resources (VNets, AKS, gateways) | **No** | Terraform |
| Argo CD's own state | **No** (excluded) | Git |

> The Content Hub app is **currently stateless** — three services, no PVCs. That
> makes these schedules cheap today and, more importantly, means the restore
> path is proven *before* the first stateful component arrives rather than
> after.

### 6.6 Retention arithmetic

```
hourly TTL           48h   ─┐
daily TTL           720h   ─┼─ must all stay BELOW ──▶ blob soft delete 30d
defaultBackupTTL    720h   ─┘
```

`backup_soft_delete_days = 30` must **exceed** the longest backup TTL, so that a
backup deleted at expiry is still recoverable from blob soft delete for a while
afterwards. Today `daily-full`'s TTL (30 days) and the soft-delete window (30
days) are *equal*, which leaves no margin: raise `backup_soft_delete_days` if you
want genuine slack, or lower the daily TTL. The variable's own validation only
enforces 1–365 days, so this relationship is a documented invariant rather than
an enforced one.

Blob **versioning** is a separate control from soft delete: versioning preserves
overwritten content, soft delete preserves *deleted* content. Both are on.

### 6.7 Blob layout

```
stovelerovinorg001 / velero /
  primary/                        ← written by aks-dev-lab-001
    backups/<backup-name>/        metadata, tarballs, logs
    kopia/                        Kopia repository (volume data)
    restores/<restore-name>/      restore logs
  dr/                             ← written by aks-dr-lab-001
    backups/ kopia/ restores/
```

Two independent Kopia repositories under one container. Velero namespaces its
own objects by backup name, so the two clusters cannot collide as long as the
prefixes differ.

---

## 7. Restore procedures

All commands run from the mgmt VM (centralindia), which has `kubectl` access to
both private clusters via its managed identity:

```bash
ssh azureadmin@<mgmt_vm_public_ip>
az login --identity

# primary
az aks get-credentials -g rg-spoke-dev-vinorg-001 -n aks-dev-lab-001 --overwrite-existing
# DR
az aks get-credentials -g rg-spoke-dr-vinorg-001  -n aks-dr-lab-001  --overwrite-existing
```

### 7.0 The rule that governs every restore: Argo CD will fight you

Both clusters run `syncPolicy.automated` with `selfHeal: true` on every
Application. A restore writes objects that differ from Git, and Argo CD reverts
them within the reconcile interval (~3 min).

**Always suspend auto-sync on the affected Application first:**

```bash
# suspend
kubectl -n argocd patch application content-hub --type merge -p '{"spec":{"syncPolicy":null}}'

# ... restore, verify ...

# resume
kubectl -n argocd patch application content-hub --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

For volume data this ordering is what you want anyway: **Argo CD recreates the
objects correctly from Git in seconds; Velero is only needed for the PVC
contents.** The efficient sequence is therefore "let Argo CD rebuild the
namespace, then restore only the volume data over it".

### 7.1 Restoring a namespace into the same cluster

```bash
# 1. Find the backup
velero backup get
velero backup describe hourly-content-hub-20260820011700 --details

# 2. Suspend Argo CD auto-sync (see §7.0)
kubectl -n argocd patch application content-hub --type merge -p '{"spec":{"syncPolicy":null}}'

# 3. Restore
velero restore create --from-backup hourly-content-hub-20260820011700 \
  --include-namespaces content-hub --wait

# 4. Inspect
velero restore describe <restore-name> --details
velero restore logs <restore-name>

# 5. Verify the app, then re-enable auto-sync
kubectl -n content-hub get pods,svc,ingress
curl -sSf -o /dev/null -w '%{http_code}\n' https://app.sometestdemo.in/healthz
kubectl -n argocd patch application content-hub --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Restoring **only** volume data (objects come from Git):

```bash
velero restore create --from-backup <backup> \
  --include-namespaces content-hub \
  --include-resources persistentvolumeclaims,persistentvolumes --wait
```

### 7.2 Restoring the primary's backups into the DR cluster

This is the cross-region case the whole design exists for. **Nothing needs
copying** — the DR cluster already has a read-only view of the primary's
backups.

```bash
# On the DR cluster. Two locations exist:
velero backup-location get
#   NAME               PROVIDER   BUCKET/PREFIX     ACCESS MODE   PHASE
#   default            azure      velero/dr/        ReadWrite     Available
#   primary-readonly   azure      velero/primary/   ReadOnly      Available

# List the PRIMARY cluster's backups
velero backup get --selector velero.io/storage-location=primary-readonly

# Restore one of them into this cluster
velero restore create --from-backup <primary-backup-name> \
  --include-namespaces content-hub --wait

velero restore logs <restore-name>
```

Points that matter:

- The primary backup's Kopia data is read from `primary/` in the **same**
  storage account. During a southindia outage that read is served by the RA-GRS
  **secondary endpoint** in centralindia — globally reachable, no failover step,
  no support ticket.
- The restore is slower than a same-region one: it pulls across a region
  boundary (indiasouthcentral ← centralindia). That is the trade made to avoid a
  quota increase; correctness is unaffected.
- Do **not** remove `accessMode: ReadOnly` to "make it writable". That flag is
  what stops this cluster expiring the primary's backups against its own
  retention clock.
- Suspend Argo CD auto-sync on the DR cluster first, exactly as in [§7.0](#70-the-rule-that-governs-every-restore-argo-cd-will-fight-you).

### 7.3 Rebuilding a cluster from scratch

Order matters, and most of it is **not** Velero:

```
1. terraform apply the landing zone            (AKS, networking)   ~45 min
2. gh workflow run argocd-bootstrap.yml -f cluster=<dev|dr>        ~5 min
3. Argo CD reconciles: ingress-nginx, velero, backup-schedules,
   content-hub — everything comes back from Git                    ~5 min
4. ONLY IF the app is stateful: velero restore the volume data
   from the latest daily-full, with auto-sync suspended
```

Steps 1–3 restore the entire cluster with no backup involved at all. Step 4 is
the only thing Velero is needed for.

If restoring `daily-full` (which carries `includeClusterResources: true`), be
deliberate about scope — restoring cluster-scoped objects over a freshly built
cluster can conflict with what AKS and Argo CD have already created:

```bash
velero restore create --from-backup daily-full-<ts> \
  --include-namespaces content-hub \
  --exclude-resources clusterroles,clusterrolebindings,customresourcedefinitions \
  --wait
```

### 7.4 Restoring when the primary storage endpoint is down

RA-GRS means the secondary is **readable immediately**, with no account
failover. Get the endpoint:

```bash
terraform -chdir=infra/platform/velero output -raw secondary_blob_endpoint
# https://stovelerovinorg001-secondary.blob.core.windows.net/
```

The secondary is read-only and lags the primary by the geo-replication delay
(typically minutes; check `Last Sync Time` in the portal or via
`az storage account show --expand geoReplicationStats`). New backups cannot be
written while the primary endpoint is down — restores work, backups do not.

Do **not** initiate an account failover as a first response: it is
account-wide, slow, and converts the account to LRS afterwards, leaving the
backups un-replicated exactly when you can least afford it.

### 7.5 Recovering a deleted or overwritten backup

Blob versioning + 30-day soft delete cover this. The account has no keys, so use
Entra auth (`--auth-mode login`) with an identity holding a blob data role:

```bash
# list soft-deleted blobs
az storage blob list --account-name stovelerovinorg001 --container-name velero \
  --prefix primary/backups/ --include d --auth-mode login -o table

# undelete
az storage blob undelete --account-name stovelerovinorg001 \
  --container-name velero --name "primary/backups/<backup>/<blob>" --auth-mode login

# list versions of an overwritten blob
az storage blob list --account-name stovelerovinorg001 --container-name velero \
  --prefix primary/ --include v --auth-mode login -o table
```

After restoring the blobs, force Velero to re-read the location:

```bash
velero backup-location get
kubectl -n velero delete pod -l deploy=velero   # or wait for the sync interval
```

### 7.6 Restore verification checklist

| Check | Command |
| --- | --- |
| Restore phase is `Completed`, not `PartiallyFailed` | `velero restore describe <name> --details` |
| No warnings hiding a skipped resource | `velero restore logs <name> \| grep -iE 'warn\|error'` |
| Pods are Running and Ready | `kubectl -n content-hub get pods` |
| Volume data is actually present (not an empty recreated PVC) | exec into the pod and inspect the mount |
| The public endpoint serves | `curl -sSf https://app.sometestdemo.in/healthz` |
| Argo CD auto-sync re-enabled | `kubectl -n argocd get app content-hub -o jsonpath='{.spec.syncPolicy}'` |
| Both clusters back in sync | `kubectl -n argocd get applications` on each |

---

## 8. Failover

### 8.1 Region failure — the automatic path

**There is no action to take to restore service.** Front Door handles it. Verify,
then investigate.

```bash
# Origin health as Front Door sees it
az afd origin list -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw -o table

# Is the site up?
curl -sSf -o /dev/null -w '%{http_code} %{time_total}s\n' https://app.sometestdemo.in/healthz

# Watch continuously from outside
while :; do curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' \
  https://app.sometestdemo.in/ ; sleep 5; done
```

Timeline as in [§4.1](#41-deriving-the-region-loss-rto): unhealthy at 60–120s,
traffic fully shifted by ~2 minutes, per PoP.

**If the site is down while the DR origin reports healthy**, the problem is
*not* the failover — it is one of:

1. the DNS cutover was never done (`app.sometestdemo.in` is still an A record to
   the primary gateway, which is in the dead region), or
2. the FDID origin lock is misconfigured on the DR gateway, or
3. the DR gateway's certificate cannot be fetched (Key Vault is in the dead
   region — see [§2.6](#26-shared-single-region-dependencies)).

**What does *not* happen during a failover, and should not:**

- No deployment. The DR cluster already runs the current commit.
- No DNS change. The anycast address never changes.
- No data movement. Backups are already cross-readable.
- No Terraform apply.
- No Velero restore (the app is stateless; and Velero is not the region-loss path).

### 8.2 Forcing a failover — planned test

Prefer the method that exercises the **real** path — make the primary genuinely
fail its health probe rather than reconfiguring Front Door:

```bash
# Suspend Argo CD auto-sync first, or selfHeal scales it straight back up
kubectl --context dev -n argocd patch application content-hub \
  --type merge -p '{"spec":{"syncPolicy":null}}'

# Make /healthz start failing in the primary region
kubectl --context dev -n content-hub scale deploy/frontend --replicas=0

# Watch from outside
while :; do curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' \
  https://app.sometestdemo.in/ ; sleep 5; done

# Restore
kubectl --context dev -n content-hub scale deploy/frontend --replicas=2
kubectl --context dev -n argocd patch application content-hub --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Expect ~2.5–3.5 minutes to shift (this is the slower, app-failure chain in
[§4.2](#42-deriving-the-rto-for-an-application-failure-in-the-primary)), a small
number of 502s in the window, then steady 200s served from indiasouthcentral.

**Alternative (blunter, tests less):** disable the primary origin directly.

```bash
az afd origin update -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw --origin-name origin-primary --enabled-state Disabled
```

This drains over `restore_traffic_time_to_healed_or_new_endpoint_in_minutes`
(5 min) so in-flight requests are not cut off — but it bypasses the health-probe
machinery entirely, which is the part most likely to be silently broken.

### 8.3 Partial failure modes and what actually happens

| Situation | Front Door behaviour | Notes |
| --- | --- | --- |
| Primary frontend pods down, cluster fine | Fails over after the appgw probe threshold (~3 min total) | The slower chain |
| Primary AKS **control plane** down, pods still serving | **No failover** — `/healthz` still answers | Correct: users are unaffected. But you cannot deploy or `kubectl` in that region |
| Primary ingress-nginx down | Gateway backend goes Unhealthy → failover | ~3 min |
| Primary gateway's public IP unreachable | Immediate probe failures → failover in ~2 min | Fastest path |
| **Both** origins unhealthy | Front Door returns errors; it does not invent a healthy origin | Genuine outage; check for a shared cause — certificate, ACR, WAF rule, or a bad commit reconciled into both clusters |
| A bad commit reaches both clusters | No failover — both are equally "healthy" | GitOps propagates mistakes to both regions in ~3 min. `git revert` is the fix |

That last row is the real residual risk of this design and is worth stating
plainly: **two clusters converging on one Git repo means a bad commit is a
global event, not a regional one.** Front Door cannot protect against it, and it
is the failure mode most likely to occur.

### 8.4 Rolling back a bad release

`git revert` is the rollback. Both clusters converge on whatever `main` says.

```bash
git revert <the deploy commit>
git push origin main
```

There is no `kubectl rollout undo` step any more — `selfHeal` would put the
committed image straight back within the reconcile interval.

---

## 9. Failback

**Automatic.** Once the primary's health probe passes again, Front Door shifts
traffic back to priority 1, draining over
`restore_traffic_time_to_healed_or_new_endpoint_in_minutes = 5` so in-flight
requests are not cut off.

**To prevent automatic failback while you investigate**, disable the primary
origin explicitly rather than letting a flapping primary pull traffic back and
forth:

```bash
az afd origin update -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw --origin-name origin-primary --enabled-state Disabled

# ... when ready ...
az afd origin update -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw --origin-name origin-primary --enabled-state Enabled
```

**Before re-enabling, confirm:**

| Check | Why |
| --- | --- |
| Argo CD on the primary is Synced and Healthy | It may have been out of sync for the whole outage |
| The primary runs the same image tag as DR | `kubectl -n content-hub get deploy -o jsonpath='{..image}'` on both |
| The primary's ingress VIP is still `10.1.2.250` | A recreated Service that failed to claim the static IP leaves the gateway pointing at nothing |
| The gateway backend pool is Healthy | `az network application-gateway show-backend-health` |
| Velero on the primary is taking backups again | `velero backup get` — a region outage does not pause the Schedule, so expect failures during it |

**If the app became stateful and DR served writes during the outage**, failback
is no longer a routing decision: data written in DR must be reconciled into the
primary first, and this design has no mechanism for that. Today the app is
stateless, so failback is genuinely just routing — do not assume that survives
the first stateful component.

---

## 10. Build order, state layout and toggles

### 10.1 Deploy order

`terraform-deploy.yml` runs layers strictly sequentially — each layer must be
fully plan+applied before its dependent can even plan.

```
approval
 1. platform/management-groups
 2. platform/policies              ← indiasouthcentral must be in allowed_locations
 3. platform/connectivity          ← creates privatelink.indiasouthcentral.azmk8s.io
 4. landing-zones/dev
 5. platform/appgw
── DR block (one commented-out block removes all of it) ──────────────
 6. landing-zones/dr               needs: dev
 7. platform/velero                needs: dr      (federates BOTH clusters)
 8. platform/appgw-dr              needs: dr
 9. platform/frontdoor             needs: [appgw, appgw-dr]
```

**Step 0, manual and once** — create the state containers:

```bash
terraform -chdir=infra/platform/bootstrap init
terraform -chdir=infra/platform/bootstrap apply   # adds landing-zones-dr, velero, appgw-dr, frontdoor
```

Additive and safe to re-run: `prevent_destroy` guards the existing containers and
no state file is touched.

**Then bootstrap GitOps into each cluster:**

```bash
terraform -chdir=infra/platform/velero output -raw identity_client_id
# paste into BOTH k8s/gitops/platform/velero/values-{dev,dr}.yaml, commit

gh workflow run argocd-bootstrap.yml -f cluster=dev
gh workflow run argocd-bootstrap.yml -f cluster=dr
```

The bootstrap workflow reaches each private cluster via `az aks command invoke`
(an ARM call, so the runner needs no network route into the spoke), pulls the
Argo CD chart **on the runner** and uploads it as a `.tgz` — a pod in a private
cluster is the least reliable place to do an outbound chart download. It applies
exactly one manifest by hand (the root Application); everything after that is
Argo CD pulling from the repo.

### 10.2 Policy and quota preconditions

**Policy, not quota, is the thing that blocks a DR deploy.** `allowed_locations`
in [infra/platform/policies](../infra/platform/policies/) feeds a **Deny**
assignment at the org root, so any region missing from it fails the apply
outright. `indiasouthcentral` is already added; if `dr_location` changes again,
add the new region there and apply that layer *first*.

Quota works out with no request — every region defaults to 4 vCPU and the
workload divides into exactly 4-vCPU units ([§2.1](#21-regions-and-what-each-holds)).
But there is **zero headroom anywhere**, and that has an operational consequence:
an AKS node-pool rotation or node-image upgrade needs a temporary surge of
+2 vCPU, so **both will fail at 4/4**. Raise the relevant limit to 6 before
attempting either. This blocks patching, not just growth.

```bash
az vm list-usage --location indiasouthcentral -o table | grep -iE "total regional|DASv5"
```

### 10.3 Every DR toggle in one table

| Toggle | Where | Effect |
| --- | --- | --- |
| `enable_dr_region` | [connectivity/dr.tf:32](../infra/platform/connectivity/dr.tf#L32) | Creates/destroys the DR privatelink DNS zone. The DR landing zone has a **precondition** that fails at *plan* time with a readable message if this is false |
| `dr_location` | [connectivity/dr.tf:89](../infra/platform/connectivity/dr.tf#L89) | The DR region, defined exactly once |
| `enable_dr` | [velero.auto.tfvars:26](../infra/platform/velero/velero.auto.tfvars#L26) | Federates the DR cluster into Velero's identity. `false` also stops this layer reading the DR state entirely, which is what makes it safe to apply **before** DR exists |
| `enable_dr_origin` | [frontdoor.auto.tfvars:18](../infra/platform/frontdoor/frontdoor.auto.tfvars#L18) | Adds the DR gateway as the priority-2 origin. `false` = single-origin Front Door; not user-visible either way |
| `frontdoor_id` | both appgw tfvars | Enables the X-Azure-FDID WAF lock. Must be null on the first apply |
| `allowed_source_prefixes` | both appgw tfvars | `["Internet"]` (primary, today) vs `["AzureFrontDoor.Backend"]` |
| The DR job block | [terraform-deploy.yml:120-162](../.github/workflows/terraform-deploy.yml#L120-L162) | Comment it out to return to the single-region stack |
| `enable_snapshot_role` | velero-backend module | `false`. Turning it on would grant Contributor on both `MC_*` node resource groups for a capability nothing uses |

### 10.4 The two-pass bootstrap (chicken and egg)

Front Door needs each gateway's public IP; each gateway needs Front Door's GUID.

```
pass 1: apply appgw + appgw-dr with frontdoor_id = null   → gateways exist, IPs known
pass 2: apply frontdoor                                   → GUID known
pass 3: set frontdoor_id in BOTH appgw tfvars, re-apply   → origin lock active
```

Setting `frontdoor_id` in pass 1 blocks **all** traffic including Front Door's
own health probes, so the origin never comes up healthy.

---

## 11. The DNS cutover and the origin lock

**Applying the frontdoor layer changes nothing users see.**
`app.sometestdemo.in` still resolves to the primary gateway's A record until you
move it by hand. That is deliberate: the cutover stays a reversible,
one-record decision — and restoring the A record is the rollback.

```bash
terraform -chdir=infra/platform/frontdoor output dns_records
```

### Step 1 — validation TXT

Create `_dnsauth.app` **TXT** = the validation token, TTL 3600. Binding the
custom domain to the route is what triggers Azure's ownership validation and
managed-certificate issuance; until this record resolves, the domain sits in
`Pending` and the route serves nothing on it.

```bash
az afd custom-domain show -g rg-frontdoor-vinorg-001 \
  --profile-name afd-vinorg-001 --custom-domain-name app-sometestdemo-in \
  --query domainValidationState -o tsv     # Pending → Approved
```

The `custom_domain_validation_expires` output is the deadline; after it, the
token must be regenerated.

### Step 2 — the cutover CNAME

Replace the `app` **A** record with a **CNAME** to `<endpoint>.azurefd.net`,
TTL 600. **This is the moment DR becomes real** — before it, there is no
failover mechanism in the path at all.

Confirm traffic actually flows through Front Door before proceeding:

```bash
curl -sI https://app.sometestdemo.in/ | grep -i "x-azure-ref\|x-cache"
dig +short app.sometestdemo.in
```

### Step 3 — close the origins

Only after step 2 is confirmed: uncomment `allowed_source_prefixes` and
`frontdoor_id` in **both** [appgw.auto.tfvars](../infra/platform/appgw/appgw.auto.tfvars#L55-L56)
and [appgw-dr.auto.tfvars](../infra/platform/appgw-dr/appgw-dr.auto.tfvars#L20),
and re-apply those layers.

**Both halves are required:**

- The NSG service tag `AzureFrontDoor.Backend` narrows the source to "any Front
  Door profile in Azure, **including other tenants'**". That is not a boundary.
- The **`X-Azure-FDID` header check** is the half that identifies *your* profile.
  Front Door stamps every origin request with the profile's GUID; a direct
  caller does not have it. The WAF custom rule blocks on
  mismatch-or-absence (`negation_condition = true`), at **priority 1** so it
  rejects bypass traffic before spending any WAF budget inspecting it.

Without step 3, anyone who finds a gateway's public IP can bypass Front Door's
WAF, routing and failover entirely.

> **Do not do step 3 before step 2.** An FDID rule with no Front Door in front
> blocks everything, health probes included.

**Current repository state:** the primary tfvars has
`allowed_source_prefixes = ["Internet"]` with the Front Door lines commented out,
and the DR tfvars has `frontdoor_id` commented out. So as committed, the origin
lock is **not** applied on either gateway.

---

## 12. DR drill — quarterly test plan

The failure mode of every DR design is that nobody runs it until they need it.
The point of a drill is to find the thing that has silently broken since the
last one — the failover itself is the easy part and rarely what is wrong.

| # | Check | Command / method | Pass criterion |
| --- | --- | --- | --- |
| 1 | Both clusters run the **same build** | `kubectl --context <c> -n content-hub get deploy -o jsonpath='{..image}'` on both | Identical tags |
| 2 | DR node count has not drifted | `kubectl --context dr get nodes` | 2 nodes, both Ready. *A DR cluster silently scaled to zero is the classic finding* |
| 3 | DR Argo CD is Synced/Healthy | `kubectl --context dr -n argocd get applications` | All Synced + Healthy |
| 4 | DR TLS certificate is valid | `openssl s_client -connect <dr-gw-ip>:443 -servername app.sometestdemo.in </dev/null 2>/dev/null \| openssl x509 -noout -dates` | Not near expiry |
| 5 | Both origins healthy at Front Door | `az afd origin list ... -o table` | Both enabled; priorities 1 and 2 |
| 6 | **Perform the failover** | [§8.2](#82-forcing-a-failover--planned-test) | Traffic shifts within ~3 min; 200s from DR |
| 7 | The app *works* in DR, not just answers | Exercise `/api/v1/catalog` and a real user journey | Correct responses, not just 200 on `/healthz` |
| 8 | Failback is clean | Restore replicas; watch traffic return | Returns to primary within ~5 min |
| 9 | Backups exist and are recent in **both** prefixes | `velero backup get` on each cluster | Hourly within the last hour; daily within 24 h |
| 10 | **Actually restore something** | [§7.2](#72-restoring-the-primarys-backups-into-the-dr-cluster) — restore a primary backup into DR | Restore `Completed`, no warnings |
| 11 | Velero identity still works | `kubectl -n velero logs deploy/velero \| grep -i "credential\|AADSTS"` | No credential errors |
| 12 | Soft delete + versioning still on | `az storage account blob-service-properties show -n stovelerovinorg001 -g rg-velero-vinorg-001` | 30 days, versioning enabled |
| 13 | Record the measured RTO | Wall clock from step 6 | Compare against the ~2–3 min target |

Item 10 is the one people skip and the one that matters: an untested restore is
a hypothesis, not a backup.

Everything in this list is manual today — **there is no automated DR drill**,
which is itself a known gap ([§14](#14-known-gaps-and-open-items)).

---

## 13. Verification — what to check and how

### Front Door

```bash
az afd profile show -g rg-frontdoor-vinorg-001 --name afd-vinorg-001 -o table
az afd origin-group show -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw
az afd origin list -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw --query "[].{name:name,host:hostName,priority:priority,enabled:enabledState}" -o table
az afd endpoint list -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 -o table

terraform -chdir=infra/platform/frontdoor output origin_hostnames
terraform -chdir=infra/platform/frontdoor output dns_records
```

### App Gateways

```bash
for rg_gw in "rg-hub-connectivity-lab:agw-dev-vinorg-001" "rg-spoke-dr-vinorg-001:agw-dr-vinorg-001"; do
  rg="${rg_gw%%:*}"; gw="${rg_gw##*:}"
  az network application-gateway show-backend-health -g "$rg" -n "$gw" \
    --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{addr:address,health:health}" -o table
done
```

The primary gateway sits in the hub resource group `rg-hub-connectivity-lab`;
the DR gateway sits in the DR spoke's group `rg-spoke-dr-vinorg-001` (confirm
with `terraform -chdir=infra/landing-zones/dr output resource_group_name`).

### Clusters

```bash
kubectl --context dr get nodes -o wide
kubectl --context dr -n argocd get applications
kubectl --context dr -n content-hub get deploy,pods,svc
kubectl --context dr -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'   # must be 10.5.2.250
```

### Velero

```bash
velero backup-location get
velero backup get
velero schedule get
velero backup describe <name> --details
kubectl -n velero get pods                     # 1 server + 1 node-agent per node
kubectl -n velero logs deploy/velero --tail=100
kubectl -n velero get sa velero -o jsonpath='{.metadata.annotations}'   # client-id
```

### Terraform outputs worth knowing

```bash
terraform -chdir=infra/platform/velero    output          # identity, endpoints, federated subjects
terraform -chdir=infra/platform/velero    output -raw secondary_blob_endpoint
terraform -chdir=infra/platform/velero    output federated_subjects
terraform -chdir=infra/platform/appgw-dr  output appgw_public_ip
terraform -chdir=infra/landing-zones/dr   output
```

`federated_subjects` is the fastest diagnostic when Velero reports a credentials
error: compare it against the running ServiceAccount.

---

## 14. Known gaps and open items

Stated plainly, because a DR design that hides its gaps is worse than one that
does not exist.

### 14.1 Architectural gaps

| # | Gap | Impact | Fix |
| --- | --- | --- | --- |
| 1 | **ACR is single-region** (Basic, southindia) | During a primary-region failure the DR cluster keeps running images already on its nodes, but a scale-out, node replacement or rescheduled pod **cannot pull** | `acr_sku = "Premium"` + `acr_geo_replication_locations` in `dev.auto.tfvars` (~10× cost; the login server name does not change, so nothing else needs editing) |
| 2 | **Key Vault holding the TLS certificate is single-region** (dev spoke) | If the vault is unavailable *and* a gateway restarts, the DR gateway cannot fetch the certificate. Front Door's own managed certificate is unaffected | A second vault + a second certificate copy — at the cost of a second thing to rotate and forget |
| 3 | **The hub is single-region** | DNS resolution for both spokes goes through the hub resolver in southindia. A full outage takes it with it: DR pods keep serving (CoreDNS is in-cluster), but `kubectl` against the DR private API server would fail to resolve | A second resolver in the DR region, or public API endpoints |
| 4 | **The mgmt VM is in centralindia**, a third region | Managing the DR cluster during a southindia outage also depends on centralindia | A second jump host, or `az aks command invoke` (which is an ARM call and needs no route) |
| 5 | **Backups are not co-located with the DR cluster** | The RA-GRS secondary lands in centralindia (southindia's Azure pair); indiasouthcentral has no pair. Restores into DR pull across a region boundary | Accept, or move DR to centralindia and raise its quota |
| 6 | **Zero vCPU headroom in every region** | All three sit at 4/4, so an AKS node-pool rotation or node-image upgrade — each needing +2 vCPU — fails. **This blocks patching**, not just growth | Raise the limits to 6 |
| 7 | **DR capacity equals primary capacity: one user node** | Warm standby sized for current load, not headroom. Front Door sends *all* traffic there on failover; the HPA caps at 4 replicas and there is no cluster autoscaler | Larger DR node pool, or enable the autoscaler |
| 8 | **No automated DR drill** | Runbook [§12](#12-dr-drill--quarterly-test-plan) is entirely manual | A scheduled workflow that scales the primary frontend to zero, asserts the failover, and restores |
| 9 | **A bad commit is a global event** | Both clusters converge on one repo in ~3 min. Front Door cannot protect against this, and it is the most likely failure mode | Progressive delivery: stagger the DR overlay's image bump behind the primary's |
| 10 | **`daily-full` TTL equals the soft-delete window** (both 30 days) | No margin between a backup expiring and its soft-delete protection lapsing | Raise `backup_soft_delete_days`, or lower the daily TTL |
| 11 | **The backup store has a public (Entra-authenticated) endpoint** | Not an open bucket — there are no keys — but not a private endpoint either | Private endpoint + `privatelink.blob` zone link **per region** |
| 12 | **Front Door origin TLS name checking is off** | The connection is TLS-encrypted over Azure's backbone, but the origin's identity is not verified. Residual risk: an in-path attacker inside Azure's network | Give each gateway a DNS name, issue a certificate covering both SANs, set `certificate_name_check_enabled = true` |

### 14.2 Open items in the repository as committed

These are not design gaps — they are steps that have not been completed yet, and
each one silently defeats part of the DR posture:

| # | Item | Consequence until done |
| --- | --- | --- |
| A | **`REPLACE_WITH_VELERO_IDENTITY_CLIENT_ID`** is still the placeholder in [values-dev.yaml:49](../k8s/gitops/platform/velero/values-dev.yaml#L49) and [values-dr.yaml:25](../k8s/gitops/platform/velero/values-dr.yaml#L25) | **Every backup fails** at "failed to get credentials" while Velero reports Healthy. The `argocd-bootstrap` workflow refuses to run until this is fixed |
| B | **The DNS cutover has not been performed** (documented as a deliberate manual step) | Front Door is inert; **there is no failover mechanism in the traffic path** |
| C | **`frontdoor_id` is commented out in both appgw tfvars** | Both gateway public IPs are independently reachable; Front Door's WAF, routing and failover can be bypassed by anyone who finds them |
| D | **Primary `allowed_source_prefixes = ["Internet"]`** | Same as C, at the NSG layer |
| E | The DR overlay pins `newTag: latest` in [k8s/overlays/dr/kustomization.yaml](../k8s/overlays/dr/kustomization.yaml#L20-L29) | `app-deploy` rewrites both overlays to the same `$SHA` on every release, so this resolves itself at the first deploy — but until then, `latest` with `imagePullPolicy: Always` means the two regions can run different bits |

---

## 15. Standing DR down

Comment-out points, in the order you would use them:

| To remove | Do this |
| --- | --- |
| **Front Door only** | Restore the `app` **A** record to the primary gateway's IP **first**, then destroy `infra/platform/frontdoor`. Reverse order is a hard outage, not a fallback |
| **DR region** | Comment out the DR block in `terraform-deploy.yml`; run the destroy pipeline. In `terraform-destroy.yml`, also change `dev: needs: [appgw, dr]` back to `needs: appgw` — leaving it pointing at a commented-out job makes the workflow fail to parse |
| **DR DNS zone** | `enable_dr_region = false` in `connectivity/dr.tf`, apply, **then** comment out the file. Commenting first orphans the zone (Terraform stops managing it; Azure keeps billing) |
| **DR from Velero** | `enable_dr = false` in `velero.auto.tfvars`. Removes the DR federated credential and stops the DR state read; backups untouched |
| **Front Door origin lock** | Comment out `frontdoor_id` + `allowed_source_prefixes` in both appgw tfvars, re-apply |

**Destroy order** (the mirror of deploy) is enforced by `terraform-destroy.yml`:

```
frontdoor → appgw-dr → landing-zones/dr → (appgw) → landing-zones/dev
          → connectivity → policies → management-groups
```

DR is destroyed **before** dev because it reads dev's state and owns both halves
of the jump↔DR peering; destroying dev first would pull those out from under a
DR layer still being destroyed.

> **`infra/platform/velero` is deliberately absent from the destroy pipeline.**
> It holds the backup storage account, and destroying it deletes every backup —
> the one thing a teardown must never take with it. Tear it down by hand, on
> purpose:
>
> ```bash
> terraform -chdir=infra/platform/velero destroy
> ```

---

## 16. Command quick reference

```bash
# ── Is the site up, and from where? ──────────────────────────────────────────
curl -sSf -o /dev/null -w '%{http_code} %{time_total}s\n' https://app.sometestdemo.in/healthz
curl -sI https://app.sometestdemo.in/ | grep -i x-azure-ref

# ── Front Door origin health ─────────────────────────────────────────────────
az afd origin list -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw -o table

# ── Prevent / allow automatic failback ───────────────────────────────────────
az afd origin update -g rg-frontdoor-vinorg-001 --profile-name afd-vinorg-001 \
  --origin-group-name og-appgw --origin-name origin-primary --enabled-state Disabled|Enabled

# ── Cluster access from the mgmt VM ──────────────────────────────────────────
az login --identity
az aks get-credentials -g rg-spoke-dev-vinorg-001 -n aks-dev-lab-001 --overwrite-existing
az aks get-credentials -g rg-spoke-dr-vinorg-001  -n aks-dr-lab-001  --overwrite-existing

# ── Backups ──────────────────────────────────────────────────────────────────
velero backup get
velero backup-location get
velero schedule get
velero backup create manual-$(date +%Y%m%d%H%M) --include-namespaces content-hub --wait

# ── Restore: same cluster ────────────────────────────────────────────────────
kubectl -n argocd patch application content-hub --type merge -p '{"spec":{"syncPolicy":null}}'
velero restore create --from-backup <backup> --include-namespaces content-hub --wait
velero restore logs <restore>
kubectl -n argocd patch application content-hub --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# ── Restore: primary's backups into DR ───────────────────────────────────────
velero backup get --selector velero.io/storage-location=primary-readonly
velero restore create --from-backup <primary-backup> --include-namespaces content-hub --wait

# ── Forced failover test ─────────────────────────────────────────────────────
kubectl --context dev -n argocd patch application content-hub --type merge -p '{"spec":{"syncPolicy":null}}'
kubectl --context dev -n content-hub scale deploy/frontend --replicas=0
# ... observe ... then reverse both

# ── Rollback a release ───────────────────────────────────────────────────────
git revert <deploy-commit> && git push origin main

# ── Terraform outputs ────────────────────────────────────────────────────────
terraform -chdir=infra/platform/velero   output -raw identity_client_id
terraform -chdir=infra/platform/velero   output -raw secondary_blob_endpoint
terraform -chdir=infra/platform/frontdoor output dns_records
```

---

## Related documents

- [docs/disaster-recovery.md](disaster-recovery.md) — the concise operational version and runbooks
- [k8s/gitops/README.md](../k8s/gitops/README.md) — Argo CD topology, per-cluster design, resource budget
- [k8s/README.md](../k8s/README.md) — cluster access path and troubleshooting
- [docs/public-endpoint.md](public-endpoint.md) — the App Gateway public entry point
- [README.md](../README.md) — landing zone overview and deploy order
