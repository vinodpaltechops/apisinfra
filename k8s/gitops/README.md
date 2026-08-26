# GitOps — Argo CD across two clusters

```
k8s/gitops/
  bootstrap/            argocd Helm values + the ONE manifest applied by hand
  apps/dev/             child Applications for the PRIMARY cluster
  apps/dr/              child Applications for the DR cluster
  platform/velero/      Velero Helm values, one per cluster
  platform/backup-schedules/
    base/               Velero Schedule CRs
    overlays/dr/        same schedules, offset ~20 min
```

## The shape: one Argo CD per cluster

There is **no hub**. Each cluster runs its own Argo CD, syncing this same repo
at a different path:

| Cluster           | Region        | Root app          | Reads from          |
| ----------------- | ------------- | ----------------- | ------------------- |
| `aks-dev-lab-001` | southindia    | `root-app-dev`    | `k8s/gitops/apps/dev` |
| `aks-dr-lab-001`  | indiasouthcentral | `root-app-dr`     | `k8s/gitops/apps/dr`  |

The usual design — one Argo CD managing both clusters — was rejected for two
reasons, and both matter more than the operational convenience it buys:

1. **A hub in the primary region is down during the incident it exists for.**
   You would be reaching for the tool that deploys your app at the exact moment
   the region hosting that tool is gone.
2. **It puts the most fragile link on the recovery path.** Reaching the DR
   cluster from the primary means pod → private API server across
   non-transitive VNet peering, plus an Azure-RBAC token via kubelogin. That is
   the piece most likely to be quietly broken, and you would discover it during
   a failover.

Per-cluster instances have exactly one external dependency each: GitHub. Both
clusters converge on the same commit independently, so **a failover needs no
deployment action at all** — the DR cluster is already running the current
release.

The cost is real and worth naming: there is no single pane of glass. You check
sync status in two places, and a change that breaks one cluster's overlay can
leave the two regions genuinely out of step until you look.

## Bootstrapping a cluster

### Prerequisite: repository credentials

**This repo is PRIVATE**, so Argo CD cannot clone it anonymously. Without a
credential every Application fails with `authentication required` and the root
app produces no children — which reads like a broken app-of-apps rather than a
missing token.

Create a **fine-grained PAT** with read-only **Contents** on this repo and
nothing else, and add it as the repository secret `ARGOCD_REPO_PAT`:

```
GitHub → Settings → Developer settings → Personal access tokens
         → Fine-grained tokens → Generate new token
         Repository access: only vinodpaltechops/apisinfra
         Permissions: Contents = Read-only

Repo → Settings → Secrets and variables → Actions → New repository secret
         Name: ARGOCD_REPO_PAT
```

Read-only is the point: Argo CD only ever *reads* the repo. A token that can
write is a token that can rewrite your desired state from inside the cluster.

`argocd-bootstrap` builds the Argo CD repository Secret from it at run time and
uploads it as a file, so the token is never committed and never appears in a
command line. The workflow fails fast with instructions if the secret is unset.

### Prerequisite: images must exist

Argo CD syncs `content-hub` from the overlays, which pin an immutable image tag.
If ACR has no image at that tag the app lands in `ImagePullBackOff` and stays
there. Run `app-deploy` first — note that a rebuilt ACR is EMPTY even though the
pinned tag is still in Git, because the images died with the old registry.

```bash
az acr repository list -n acrdevvinorg001 -o tsv    # must not be empty
```

### Run it

```bash
# once per cluster — installs Argo CD, the repo credential, and the root app
gh workflow run argocd-bootstrap.yml -f cluster=dev
gh workflow run argocd-bootstrap.yml -f cluster=dr
```

The workflow refuses to run while `values-*.yaml` still holds the
`REPLACE_WITH_VELERO_IDENTITY_CLIENT_ID` placeholder, and prints the value to
paste. That guard exists because the failure it prevents is invisible: Argo CD
happily syncs a Velero whose ServiceAccount carries a bogus client id, reports
it Healthy, and every backup fails at "failed to get credentials".

```bash
# get the real value
terraform -chdir=infra/platform/velero output -raw identity_client_id
```

Both values files take the **same** client id — one identity federated into two
clusters is what lets the DR cluster read backups the primary wrote.

## Reaching the UI

Argo CD is `ClusterIP` only. The cluster is private, its ingress is internal,
and the App Gateway in front carries the *application's* certificate — putting
the deployment control plane on that public edge would be a poor trade.

```bash
ssh azureadmin@<mgmt_vm_public_ip>
az login --identity
az aks get-credentials -g rg-spoke-dev-vinorg-001 -n aks-dev-lab-001 --overwrite-existing
kubectl -n argocd port-forward svc/argocd-server 8080:80

# from your laptop, tunnelling through the same VM
ssh -L 8080:localhost:8080 azureadmin@<mgmt_vm_public_ip>
open http://localhost:8080

# initial password (delete the secret once you have changed it)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## How a release reaches the clusters

```
push to main (apps/**)
  → app-deploy: test → build → push :$SHA to ACR
  → kustomize edit set image in BOTH k8s/overlays/dev and k8s/overlays/dr
  → commit "[skip ci]" back to main
  → each cluster's Argo CD notices within ~3 min → rolls out
```

`app-deploy` no longer runs `kubectl` at all, so it needs no cluster
credentials and no run-command permission. Its blast radius is a git commit.

Two consequences worth internalising:

- **The workflow goes green when the tag is committed, not when pods are
  Ready.** Watch the rollout in Argo CD, not in Actions.
- **`git revert` is the rollback.** There is no `kubectl rollout undo` any
  more — `selfHeal` would put the committed image straight back.

The old push-based deploy job is preserved, commented out, at the bottom of
`app-deploy.yml`. If you restore it, first set `syncPolicy.automated` to null on
the `content-hub` Applications, or Argo CD and the pipeline will fight over the
same Deployments within seconds of each other.

## Resource budget

Everything below lands on a **single `Standard_D2as_v5`** — 2 vCPU / 8 GiB,
~1900m and ~5.4Gi allocatable. This is the constraint that shaped every
`resources:` block in this tree.

| Component                    | CPU req  | Memory req |
| ---------------------------- | -------- | ---------- |
| content-hub (3 svc × 2)      | 240m     | 448Mi      |
| ingress-nginx                | 100m     | 128Mi      |
| Argo CD (4 pods)             | 350m     | 640Mi      |
| Velero server                | 100m     | 128Mi      |
| Velero node-agent            | 100m     | 128Mi      |
| **Total**                    | **~890m** | **~1.5Gi** |

That leaves roughly half the CPU for HPA headroom (capped at 4 replicas — the
cluster autoscaler is off, so scaling past what one node holds only produces
Pending pods).

Argo CD is deliberately trimmed to fit: dex and the notifications controller are
disabled, and the ApplicationSet controller runs at `replicas: 0`.

> **Chart gotcha:** `applicationSet.enabled` does **not** exist in argo-cd chart
> 7.x. Unlike `dex` and `notifications`, that Deployment template carries no
> conditional, so setting `enabled: false` is silently ignored and the
> controller runs anyway. `replicas: 0` is the only thing that works.

## Things that will bite

**`Schedule` sync fails with "no matches for kind Schedule."**
The Velero CRDs are not registered yet. `velero` is at sync-wave `-1` and
`backup-schedules` at `0` for this reason, but CRD establishment is
asynchronous, so the retry policy (5 attempts) is what actually covers it.

**`content-hub` is permanently OutOfSync on `/spec/replicas`.**
Expected, and already handled by the `ignoreDifferences` block — the HPA owns
that field. If you remove that block, `selfHeal` will scale the app back down on
every reconcile, under exactly the load that made it scale up.

**A values change applied to one cluster only.**
`ingress-nginx-values.yaml` and `ingress-nginx-values-dr.yaml` are separate
files, as are the two Velero values files. Helm values cannot be kustomize-
patched, so there is no shared base to inherit from — they drift unless you
change both. The `backup-schedules` tree *is* kustomize, and does use a base.

**Chart versions must match across regions.**
Especially Velero: a backup written by one Kopia repository format is not
guaranteed readable by a different one, and the DR cluster exists to read the
primary's backups.
