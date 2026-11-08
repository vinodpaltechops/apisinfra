# Workloads — applications deployed on demand

Nothing in this directory is read by a root Application, so `argocd-bootstrap`
never deploys it. The platform comes up without any application; which apps run
on top is a separate choice, made when you want them. (Platform pieces such as
AGC, nginx and Velero are the same idea — see [components/](../components/).)

```
workloads/dev/
  content-hub-agc.yaml     Content Hub through the shared AGC Gateway
  content-hub-nginx.yaml   Content Hub through the internal ingress-nginx
```

Content Hub is one app with two entrances, so it is two workloads. Pick ONE: both
create the same Deployments and Services, and the workflow refuses to deploy one
while the other is in the run or running.

## Choosing what runs

Actions → **gitops-deploy** → Run workflow:

| Input | Meaning |
| --- | --- |
| `names` | Comma-separated: `content-hub-agc`, or `agc,content-hub-agc`, or `nginx,content-hub-nginx` |
| `action` | `deploy` applies the Application; `remove` deletes it and everything it created |

Runs are independent: deploying one name never touches another. Only
files that exist under `components/dev/` or `workloads/dev/` are accepted, so the
workflow cannot be used to delete anything else.

Each variant declares what it needs (`gitops.vinorg/requires`) and what it cannot
coexist with (`gitops.vinorg/conflicts-with`):

| Workload | Requires | Why | Conflicts with |
| --- | --- | --- | --- |
| `content-hub-agc` | `agc` | its HTTPRoute needs the CRDs the ALB controller installs | `content-hub-nginx` |
| `content-hub-nginx` | `nginx` | the Ingress is validated by the controller's admission webhook | `content-hub-agc` |

Typed in any order, components go first on deploy and last on remove. To switch
entrance, remove one then deploy the other: the app restarts and is briefly down,
because nothing carries over between the two Applications.

`deploy` only applies the Application — Argo CD does the rollout, so the run goes
green before the pods are Ready. For Content Hub, run `app-deploy` first: a
rebuilt registry is empty and the pods sit in `ImagePullBackOff` until a tag lands.

## An app that does not use Argo CD

It needs nothing in this directory. It deploys by its own method and follows the
contract of the entrance it chose. The full text of each is next to the component
it describes; this is the short version.

| | AGC (public) | nginx (private LB, public only via the App Gateway) |
| --- | --- | --- |
| Contract | `platform/agc-gateway/values.yaml` | `k8s/platform/ingress-nginx-values.yaml` |
| Declare | `HTTPRoute`, `parentRefs: shared` in `platform-gateway` | `Ingress`, `ingressClassName: nginx-internal` |
| Reachable from | the internet, via Traffic Manager and DNS | inside the VNet (`10.1.2.250`); from the internet only through the App Gateway, for `app.sometestdemo.in` alone |
| Hostnames | claim your own, never empty | claim your own `host:`; at most one hostless catch-all |
| Namespace | label `gateway-access=shared`, set by the platform | none, and nothing gates who may publish |
| Pod access | NetworkPolicy from the AGC subnet (`10.1.5.0/24`) | NetworkPolicy from the `ingress-nginx` namespace |
| TLS | not yet (AGC cannot read Key Vault) | not set up |

Worked examples, neither of which the platform knows about:
`overlays/dev-agc/` (route, health policies, NetworkPolicy door) and
`overlays/dev-nginx/` (the Ingress that the base already carries).

## Adding an Argo CD app here

1. Put an `Application` manifest in `workloads/dev/<name>.yaml`.
2. Run **gitops-deploy** with that name.

## Known leftovers

- **DR still deploys Content Hub automatically** (`apps/dr/content-hub.yaml`).
  That is what keeps a DR cluster a warm standby; whether it should follow this
  model is a decision for when DR returns.
- **`platform/backup-schedules` still has an hourly schedule for the `content-hub`
  namespace.** With the app not deployed it protects nothing; whether Velero
  reports that as a clean empty backup or a failed one is unverified here.
