# Components — platform pieces deployed on demand

Nothing in this directory is read by a root Application, so `argocd-bootstrap`
never deploys it. On the dev cluster bootstrap installs Argo CD and stops; each
piece below is a separate choice, deployed or removed on its own.

```
components/dev/
  agc.yaml           wrapper Application "component-agc"    -> children/agc/
  velero.yaml        wrapper Application "component-velero" -> children/velero/
  nginx.yaml         Application "ingress-nginx" (single, no wrapper)
  children/
    agc/             repo-mcr (-2), alb-controller (-1), agc-gateway (0)
    velero/          velero (-1), backup-schedules (0)
```

| Name | Deploys | Needs |
| --- | --- | --- |
| `agc` | ALB controller, the shared Gateway, the platform health route and responder | the `agc` Terraform layer applied |
| `velero` | Velero and its backup schedules | the `velero` Terraform layer applied |
| `nginx` | ingress-nginx (internal load balancer) | nothing |

They are independent: deploying `nginx` does not touch `agc`.

## Choosing what runs

Actions → **gitops-deploy** → Run workflow, with `names` (comma-separated) and
`action` (`deploy` or `remove`). The name is the file name.

For `agc` and `velero` the workflow first reads that Terraform layer's outputs and
writes them onto the cluster's Argo CD secret, then applies the component. The
ApplicationSets inside fill their Helm values from those annotations, so no Azure
identifier is typed into Git. If the layer is not applied, it stops and says so.

## Why a wrapper, not the files applied one by one

The children depend on each other's sync waves (the controller installs the CRDs
that the Gateway needs; Velero installs the CRDs that the schedules need). Waves
only order resources inside a single Argo CD sync, so applying the files
separately would create them all at once and leave the order to retries. The
wrapper Application is that single sync.

`nginx` is one Application, so it needs none.

## Removing

`remove` deletes the wrapper and Argo CD's finalizers cascade to everything below
it. The run uses `--wait` and fails on a timeout, so a stuck cascade is visible.
If it stalls on `agc`, look for a PodDisruptionBudget holding a node drain — the
ALB controller ships one — before assuming Argo CD is at fault.

## Adding a component

Put an `Application` in `components/dev/<name>.yaml`. If it has parts that depend
on each other, make it a wrapper over a `children/<name>/` directory. If it needs
Terraform outputs, add a case for it in `gitops-deploy.yml`. If it needs another
component first, annotate it `gitops.vinorg/requires: <name>`.
