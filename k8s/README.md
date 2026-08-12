# Deploying Content Hub to the private AKS cluster

```
k8s/
  base/                    namespace, 3 deployments+services, ingress, HPAs, network policies
  overlays/dev/            pins the ACR registry + image tags, forces imagePullPolicy: Always
  platform/                Helm values for the internal ingress controller
```

## The constraint that shapes everything

`aks-dev-lab-001` is a **private cluster**: the API server has no public
endpoint, and the app has no public ingress. Two consequences drive the design
below.

**CI cannot run `kubectl` directly.** A GitHub-hosted runner has no route into
the spoke. The deploy workflow therefore uses `az aks command invoke`, which
asks the AKS resource provider to run the command from a pod *inside* the
cluster and streams the output back. That is a control-plane (ARM) call, so it
needs no network route at all — only the two authorisations listed below.

**The app is reached over a private IP.** ingress-nginx is installed with an
internal Azure load balancer that takes a frontend IP from `snet-aks-user-dev`
(10.1.2.0/24). You reach it from the mgmt VM, or by tunnelling through it.

## Order of operations

```
1. terraform apply  infra/landing-zones/dev     → creates the ACR, grants kubelet AcrPull
2. run workflow     aks-platform-bootstrap      → installs internal ingress-nginx
3. run workflow     app-deploy                  → builds, pushes, rolls out
```

Step 1 is the existing `terraform-deploy` pipeline — the ACR module is wired
into the dev landing zone, so nothing new to run by hand. Step 2 is once per
cluster. Step 3 runs on every push to `main` that touches `apps/**` or `k8s/**`.

### Authorisations the deploy SP needs

Both are already in place; listed so a failure is diagnosable:

- **ARM** — `Microsoft.ContainerService/managedClusters/runcommand/action`,
  covered by the SP's Owner assignment at the root management group.
- **Kubernetes** — `Azure Kubernetes Service RBAC Cluster Admin` on the
  cluster, granted by `infra/modules/aks` because
  `grant_operator_cluster_admin = true` in the dev landing zone. Azure RBAC for
  Kubernetes is enabled on this cluster, so a kubeconfig alone is not enough.

## Reaching the app

Get the internal load balancer's IP:

```bash
az aks command invoke -g rg-spoke-dev-vinorg-001 -n aks-dev-lab-001 \
  --command "kubectl -n ingress-nginx get svc ingress-nginx-controller \
             -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
```

Then tunnel to it from your laptop through the public mgmt VM (its IP is the
`mgmt_vm_public_ip` output of the dev landing zone):

```bash
ssh -L 8080:<INGRESS_IP>:80 azureadmin@<mgmt_vm_public_ip>
open http://localhost:8080
```

This works because the jump VNet (10.4.0.0/24, centralindia) is peered directly
to the dev spoke, and the spoke NSG's `allow-mgmt-0` rule admits that range.
Peering is non-transitive, which is exactly why that direct peering exists.

### Running kubectl from the mgmt / jump VM

**Always sign in with the managed identity, never interactively.** Entra
security defaults block the device-code flow (`AADSTS530035: Access has been
blocked by security defaults`), and neither VM has a browser for the redirect
flow. `az login --identity` is exempt because no interactive user is involved.

Both VMs already have `az`, `kubectl`, `helm` and `kubelogin` from cloud-init.

```bash
# laptop -> mgmt VM (SSH is restricted to mgmt_ssh_source_prefix)
ssh azureadmin@<mgmt_vm_public_ip>

az login --identity
az aks get-credentials -g rg-spoke-dev-vinorg-001 -n aks-dev-lab-001 --overwrite-existing
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

This needs the VM's identity to hold **both** AKS roles: `Cluster User Role`
(the ARM permission to fetch the kubeconfig) and `RBAC Cluster Admin` (what
Azure RBAC checks on each kubectl call). Missing the first fails at
`get-credentials`; missing the second fails at the first kubectl call. The jump
VM gets them from the aks module's `jump_vm_principal_id`; the mgmt VM gets them
via `additional_admin_principal_ids`.

Do **not** add these with `az role assignment create` — Terraform then fails
with `RoleAssignmentExists` on the next apply. Let the pipeline create them.

To reach the jump VM (no public IP) from the mgmt VM, forward your SSH agent:
`ssh -A azureadmin@<mgmt_vm_public_ip>` then `ssh azureadmin@10.4.0.5`.

Alternatively, SSH to the jump VM and
`az aks get-credentials -g rg-spoke-dev-vinorg-001 -n aks-dev-lab-001` — its
managed identity already holds cluster admin, and the hub DNS resolver answers
the private API FQDN.

## Applying by hand

From the jump VM, with credentials loaded:

```bash
kubectl apply -k k8s/overlays/dev
kubectl -n content-hub rollout status deploy/backend
```

Locally you can render and inspect without a cluster:

```bash
kubectl kustomize k8s/overlays/dev
```

## Resource budget

The user node pool is a **single `Standard_D2as_v5` — 2 vCPU / 8 GiB**, and
southindia's quota has no room for a second one. Everything here is sized
against that ceiling.

| Workload            | Replicas | CPU request | Memory request |
| ------------------- | -------- | ----------- | -------------- |
| content-api         | 2        | 50m         | 96Mi           |
| backend             | 2        | 50m         | 96Mi           |
| frontend            | 2        | 20m         | 32Mi           |
| ingress-nginx       | 2        | 100m        | 128Mi          |
| **Total requested** |          | **~440m**   | **~700Mi**     |

Against roughly 1900m allocatable, that leaves headroom for the HPAs (capped at
4 replicas — the cluster autoscaler is not enabled, so scaling past what one
node holds only produces Pending pods).

Two deliberate choices:

- **Memory has limits, CPU does not.** Memory exhaustion is a hard failure, so
  it is capped. CPU limits only add throttling latency to a request-serving
  process whose share is already reserved by its request.
- **Pod anti-affinity is `preferred`, not `required`.** With one node a hard
  rule would leave every second replica permanently Pending.

## Troubleshooting

**`ImagePullBackOff` on the first deploy after `terraform apply`**
AcrPull role assignments take a minute or two to propagate. The rollout wait is
set to 300s to ride this out. Confirm the assignment exists:

```bash
az role assignment list --scope $(az acr show -n acrdevvinorg001 --query id -o tsv) -o table
```

**Pods stuck `Pending`**
Almost always node capacity. `kubectl -n content-hub describe pod <name>` will
say `Insufficient cpu`. Drop a replica or lower requests.

**Every pod's DNS times out, but all nodes are `Ready`** *(hit this for real — see below)*
The spoke NSG must permit the Azure CNI Overlay pod CIDR. Overlay pod traffic
between nodes keeps the **pod** source/destination IPs (`192.168.x.x`) — Azure
does not SNAT it to the node IPs — so it matches none of the `10.x` allow rules
and falls through to `deny-all-inbound`. Intra-node traffic never reaches the
NSG, which is why CoreDNS's own readiness probe passes and the cluster looks
healthy. The `allow-aks-pods-outbound-sourced` / `allow-spoke-to-aks-pods` rules
in `infra/modules/spoke-network` fix it; `aks_pod_cidr` must be passed in.

Distinguishing test — from a pod, a *cluster-internal* name failing to resolve
rules out anything to do with internet access:

```bash
az aks command invoke -g rg-spoke-dev-vinorg-001 -n aks-dev-lab-001 \
  --command 'kubectl --server=https://$KUBERNETES_SERVICE_HOST:443 get nodes'
```

The `--server` override matters: without it `kubectl` needs DNS to resolve
`kubernetes.default.svc` and fails for the very reason you are debugging.

**`backend` pods running but never `Ready`**
Readiness calls `content-api`. Check `content-api` is up, then suspect the
NetworkPolicies — `allow-backend-to-content-api` is the relevant one:

```bash
kubectl -n content-hub delete netpol --all   # restores allow-all while you debug
```

**Ingress Service stuck on `<pending>` for its external IP**
The AKS control-plane identity needs Network Contributor on the spoke VNet to
allocate an IP from `snet-aks-user-dev`; `infra/modules/aks` grants it. Also
check the subnet name in `platform/ingress-nginx-values.yaml` still matches.

**`az aks command invoke` returns a permissions error**
See the authorisations section above — it is one of those two, not a network
problem.

## Going fully private

The registry keeps a public endpoint (Basic SKU) so a GitHub-hosted runner can
push to it. To close that:

1. `acr_sku = "Premium"` and `public_network_access_enabled = false`.
2. Add a private endpoint in `snet-data-dev` against a `privatelink.azurecr.io`
   zone in the hub, alongside the existing Key Vault pattern.
3. Move the `build` job to a self-hosted runner on the jump VM — a hosted
   runner will no longer be able to push.

The pull path does not change: it is already identity-based, with the kubelet's
managed identity holding AcrPull and no `imagePullSecret` anywhere.
