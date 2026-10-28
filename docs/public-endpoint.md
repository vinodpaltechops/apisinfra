# Publishing the app on your own domain

Puts `app.yourdomain.com` (GoDaddy) in front of the private AKS workload via an
Application Gateway WAF_v2 in the hub.

```
internet ──> GoDaddy DNS  app.yourdomain.com  A ──> <appgw public IP>
         ──> Application Gateway WAF_v2      (hub,   10.0.7.0/24)
         ──> internal load balancer          (spoke, 10.1.2.250)
         ──> ingress-nginx ──> frontend  (/)  ·  backend (/api)
```

Only the gateway is on the internet. The API server keeps no public endpoint,
the nodes keep no public IPs, and the ingress load balancer stays internal.
Traffic reaches the spoke over the existing hub↔spoke peering and is admitted
by the NSG's `allow-from-hub` rule (`10.0.0.0/16 → 10.1.0.0/16`), which is
already there — nothing new to open.

**Cost warning:** WAF_v2 is roughly **$250–300/month** at idle (a fixed gateway
charge plus capacity units), far more than everything else in this lab
combined. `min_capacity = 0` keeps it as low as it goes. Destroy the `appgw`
layer when you are not using it.

## Prerequisites

- A domain in GoDaddy, and access to its DNS management page.
- The dev landing zone applied, and the app deployed
  (`aks-platform-bootstrap` → `app-deploy`).
- The `appgw` state container. It is in `bootstrap`'s list now, but if you are
  not re-running bootstrap, create it once by hand:

  ```bash
  az storage container create --name appgw \
    --account-name stotfstatevinorg003 --auth-mode login
  ```

## Step 1 — Set your hostname

Edit [`infra/platform/appgw/appgw.auto.tfvars`](../infra/platform/appgw/appgw.auto.tfvars):

```hcl
app_fqdn = "app.yourdomain.com"   # <- your real domain
```

This value is used in three places — the listener, the `Host` header sent to
ingress-nginx, and later the TLS certificate subject — so it must be the exact
name you intend to browse to.

While testing you can also keep the gateway off the open internet:

```hcl
allowed_source_prefixes = ["163.223.165.0/24"]   # your ISP range
```

...and widen it to `["Internet"]` once it works.

## Step 2 — Re-deploy the ingress with a pinned VIP

The gateway's backend pool points at the literal address `10.1.2.250`, so the
ingress load balancer must stop taking whatever IP Azure hands out. That change
is already in `k8s/platform/ingress-nginx-values.yaml`
(`service.beta.kubernetes.io/azure-load-balancer-ipv4`), so just re-run the
**`aks-platform-bootstrap`** workflow, then confirm:

```bash
az aks command invoke -g rg-spoke-dev-vinorg-001 -n aks-dev-lab-001 \
  --command "kubectl -n ingress-nginx get svc ingress-nginx-controller"
```

`EXTERNAL-IP` must read **10.1.2.250**. If it does not, the gateway will come
up healthy-looking but every request will 502.

## Step 3 — Deploy the gateway

Run the **`terraform-deploy`** workflow (the `appgw` layer runs last), or:

```bash
cd infra/platform/appgw
terraform init -backend-config=../../backend.json
terraform apply
```

Creation takes 10–20 minutes — App Gateway is one of the slowest Azure
resources to provision. Then:

```bash
terraform output appgw_public_ip
terraform output dns_record_instructions
```

## Step 4 — Create the GoDaddy DNS record

GoDaddy → **My Products** → your domain → **DNS** → **Add New Record**:

| Field | Value |
|---|---|
| Type | `A` |
| Name | `app` (just the label — GoDaddy appends the domain) |
| Value | the `appgw_public_ip` from step 3 |
| TTL | 600 seconds (1 hour is the default; shorter helps while testing) |

Use **`A`, not `CNAME`** — you are pointing at an IP address. A `CNAME` would
only be right if you were pointing at another hostname.

Verify propagation (usually 5–30 minutes, occasionally longer):

```bash
dig +short app.yourdomain.com          # should print the gateway's public IP
nslookup app.yourdomain.com 8.8.8.8    # check a public resolver, not your cache
```

## Step 5 — Verify

```bash
curl -I http://app.yourdomain.com/
curl -s http://app.yourdomain.com/api/v1/meta
```

Then open `http://app.yourdomain.com` in a browser. The footer should show the
live pod names, exactly as it did over the SSH tunnel.

Check the gateway agrees the backend is healthy:

```bash
az network application-gateway show-backend-health \
  -g rg-hub-connectivity-lab -n agw-dev-vinorg-001 \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{ip:address,health:health}" -o table
```

## Step 6 — Add TLS (do this before real use)

Steps 1–5 leave you on **plain HTTP**. Anyone on the path can read the traffic,
and browsers will mark the site "Not secure". App Gateway does not do
Let's Encrypt itself, so the certificate is obtained separately and stored in
Key Vault.

### 6a. Get a certificate

Easiest is a DNS-01 challenge, which needs no inbound access:

```bash
brew install certbot                      # or apt install certbot
sudo certbot certonly --manual \
  --preferred-challenges dns \
  -d app.yourdomain.com
```

Certbot prints a `_acme-challenge.app` TXT record — add it in GoDaddy's DNS
page, wait for it to propagate, then continue. Convert the result to a PFX,
which is what Key Vault and App Gateway expect:

```bash
sudo openssl pkcs12 -export \
  -out app.pfx \
  -inkey /etc/letsencrypt/live/app.yourdomain.com/privkey.pem \
  -in    /etc/letsencrypt/live/app.yourdomain.com/fullchain.pem \
  -passout pass:
```

Let's Encrypt certificates last 90 days. For anything long-lived, either
automate renewal or buy a longer-lived certificate — an expired certificate
takes the site down exactly as hard as a broken backend.

### 6b. Import it into Key Vault — from inside the VNet

The dev Key Vault has `public_network_access_enabled = false`, so its data
plane is reachable **only** through the private endpoint. Note the `ip_rules`
in the module are inert while public access is off, so "allow my laptop's IP"
is not an available shortcut — the import has to run from a machine in the
VNet. The mgmt VM is that machine.

Copy the PFX up, then import from there:

```bash
scp app.pfx azureadmin@<mgmt_vm_public_ip>:~
ssh azureadmin@<mgmt_vm_public_ip>
```

The vault uses RBAC (`enable_rbac_authorization = true`), so subscription Owner
alone does **not** grant data-plane rights — importing a certificate needs an
explicit role. Grant it to yourself once:

```bash
az login --identity          # or your own account
VAULT_ID=$(az keyvault show -n kv-dev-lab-<suffix> --query id -o tsv)
az role assignment create --assignee <your-object-id> \
  --role "Key Vault Certificates Officer" --scope "$VAULT_ID"

az keyvault certificate import \
  --vault-name kv-dev-lab-<suffix> \
  --name app-tls \
  --file app.pfx
```

Do not create the gateway's own role assignment this way — Terraform creates
that one (6c), and a manual duplicate makes the next apply fail with
`RoleAssignmentExists`.

### 6c. Turn TLS on — Terraform does the rest

No `az identity create`, no `az role assignment`. The module creates its own
user-assigned identity and grants it `Key Vault Secrets User` on the vault.
Creating those by hand as well is what produces `RoleAssignmentExists` on the
next apply.

Collect the two IDs:

```bash
az keyvault secret show --vault-name kv-dev-lab-<suffix> --name app-tls --query id -o tsv
az keyvault show -n kv-dev-lab-<suffix> --query id -o tsv
```

Then in `appgw.auto.tfvars` — **strip the trailing version GUID** from the
secret ID so the gateway follows rotations automatically:

```hcl
enable_https                        = true
ssl_certificate_key_vault_secret_id = "https://kv-dev-lab-xxxx.vault.azure.net/secrets/app-tls"
key_vault_id                        = "/subscriptions/<sub>/resourceGroups/rg-spoke-dev-vinorg-001/providers/Microsoft.KeyVault/vaults/kv-dev-lab-xxxx"
```

`terraform apply`. The module adds the `:443` listener and converts `:80` into
a permanent redirect.

```bash
curl -I http://app.yourdomain.com/    # expect 301 -> https://
curl -I https://app.yourdomain.com/   # expect 200
```

### The HTTP/HTTPS switch

`enable_https` is a genuine toggle, not a one-way door:

| `enable_https` | `http_redirect_to_https` | Result |
| --- | --- | --- |
| `false` (default) | — | `:80` serves the app. No certificate needed |
| `true` | `true` (default) | `:80` → 301 → `:443` → app |
| `true` | `false` | **both** `http://` and `https://` serve the app |

Flipping it only adds or removes listeners and routing rules on the existing
gateway — **the public IP never changes**, so the GoDaddy A record stays valid
whichever way it is set. Set `http_redirect_to_https = false` while validating
a new certificate, so a bad cert cannot take the site down.

Misconfiguration is caught at **plan** time by preconditions, not 20 minutes
into an apply: `enable_https = true` with no certificate source, with both
sources, or with a Key Vault secret but no `key_vault_id`, each fail
immediately with a specific message.

### Alternative: skip Key Vault entirely

If the vault's private endpoint makes the import awkward, Terraform can upload
the PFX straight to the gateway instead — no vault, no identity, works from a
CI runner with no route into the VNet:

```hcl
enable_https             = true
ssl_certificate_pfx_path = "app.pfx"
# TF_VAR_ssl_certificate_pfx_password=... (never commit this)
```

The trade-off is real: the PFX, private key included, is then stored in
Terraform state. State sits in the backend storage account, encrypted at rest
and access-controlled, but anyone who can read state can read the key. Prefer
the Key Vault source when that matters.

## Troubleshooting

**Backend health `Unhealthy`**
Almost always the pinned VIP. Confirm the ingress Service really has
`EXTERNAL-IP 10.1.2.250` (step 2) and that it matches `ingress_internal_ip`.
Nothing enforces that link — it is a convention between a Helm annotation and a
tfvars entry, so it is the first thing to check.

**502 Bad Gateway**
The gateway reached the ingress but got nothing usable. Check the app is
actually running (`kubectl -n content-hub get pods`) and that the health probe
path `/healthz` still returns 200 through the ingress.

**Gateway stuck / unmanageable, no clear error**
The NSG's `allow-gateway-manager` rule (inbound 65200-65535 from the
`GatewayManager` service tag) is mandatory. It is in the module — but if you
edit that NSG, do not remove it.

**`ApplicationGatewayKeyVaultSecretAccessDenied` when enabling TLS**
The vault needs `public_network_access_enabled = true` (with
`default_action = "Deny"` kept), which is why
`keyvault_public_network_access_enabled` defaults to true in the dev layer.

The error text blames the identity, but that is usually a red herring — check
the role assignment first and you will normally find it correct. The real cause
is that App Gateway reads the certificate from its **control plane**, which is
Microsoft-operated and not in your VNet, so it cannot use the vault's private
endpoint. It resolves the vault's public FQDN via public DNS, and with the
public endpoint removed there is nothing to connect to. Authorization is never
reached, because the connection never succeeds.

A private endpoint serves *your* network. It does not make Azure's own control
plane able to reach the vault — the same reason `terraform apply` from a laptop
cannot write secrets to this vault, and why the certificate import has to run on
the mgmt VM.

Turning public access on does not expose the vault: `default_action` stays
`Deny`, so the internet still gets nothing. It re-activates the firewall so
`bypass = "AzureServices"` (which covers App Gateway) and `ip_rules` apply at
all. While public access is off, every one of those rules is inert.

**A legitimate request gets 403**
WAF false positive. Switch `waf_mode = "Detection"`, reproduce, find the rule
ID in the firewall log, then add a targeted exclusion — rather than leaving WAF
off:

```kusto
AzureDiagnostics
| where Category == "ApplicationGatewayFirewallLog"
| project TimeGenerated, ruleId_s, Message, requestUri_s, action_s
| order by TimeGenerated desc
```

**DNS still resolves to the old value**
GoDaddy's default TTL is 1 hour. Verify against a public resolver
(`nslookup app.yourdomain.com 8.8.8.8`) rather than your local cache.

## Turning it off

The gateway is the expensive part and is independent of everything else:

```bash
cd infra/platform/appgw && terraform destroy
```

The app stays reachable over the SSH tunnel to `10.1.2.250` exactly as before.
Destroy this layer **before** connectivity — it owns a subnet inside the hub
VNet, which cannot be deleted while that subnet is in use. The
`terraform-destroy` workflow already sequences it first.
