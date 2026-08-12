"""Seed catalog.

An in-memory dataset keeps the service dependency-free, which matters here:
the AKS user node pool is a single 2 vCPU / 8 GiB node, so there is no room for
a database pod. Swapping this module for a real repository (Postgres via Azure
Database for PostgreSQL Flexible Server behind a private endpoint) is the only
change needed later — the query helpers below already isolate the callers from
the storage shape.
"""

from __future__ import annotations

from datetime import date

from .models import ContentItem

_SEED: list[dict] = [
    {
        "id": "hub-spoke-landing-zone",
        "title": "Designing a Hub-Spoke Landing Zone on Azure",
        "summary": (
            "How the Cloud Adoption Framework splits connectivity, governance and "
            "workload subscriptions, and why the hub owns DNS and egress."
        ),
        "category": "Architecture",
        "tags": ["azure", "caf", "networking"],
        "author": "Priya Raghavan",
        "published_on": date(2026, 1, 14),
        "reading_minutes": 12,
        "rating": 4.8,
        "url": "https://learn.microsoft.com/azure/cloud-adoption-framework/",
    },
    {
        "id": "private-aks-dns",
        "title": "Private AKS Clusters and the BYO DNS Zone Trap",
        "summary": (
            "A private API server needs its privatelink zone resolvable at node "
            "bootstrap. Bring your own zone and link it to the hub to avoid the "
            "chicken-and-egg deadlock."
        ),
        "category": "Kubernetes",
        "tags": ["aks", "dns", "private-link"],
        "author": "Marcus Oyelaran",
        "published_on": date(2026, 2, 3),
        "reading_minutes": 9,
        "rating": 4.9,
        "url": "https://learn.microsoft.com/azure/aks/private-clusters",
    },
    {
        "id": "cni-overlay-ip-planning",
        "title": "Azure CNI Overlay: Stop Burning VNet Address Space",
        "summary": (
            "Overlay pod CIDRs are not routable in the VNet, so a /16 of pods "
            "costs you nothing in spoke addressing. The trade-offs, measured."
        ),
        "category": "Kubernetes",
        "tags": ["aks", "cni", "networking"],
        "author": "Elena Vasquez",
        "published_on": date(2025, 11, 22),
        "reading_minutes": 7,
        "rating": 4.5,
        "url": "https://learn.microsoft.com/azure/aks/azure-cni-overlay",
    },
    {
        "id": "workload-identity-migration",
        "title": "Migrating from Pod Identity to Workload Identity",
        "summary": (
            "Federated credentials replace the aad-pod-identity DaemonSet. A "
            "step-by-step migration with the OIDC issuer wiring explained."
        ),
        "category": "Security",
        "tags": ["aks", "identity", "oidc"],
        "author": "Marcus Oyelaran",
        "published_on": date(2026, 3, 8),
        "reading_minutes": 11,
        "rating": 4.7,
        "url": "https://learn.microsoft.com/azure/aks/workload-identity-overview",
    },
    {
        "id": "terraform-state-blast-radius",
        "title": "One State File Per Layer: Blast Radius as a Design Input",
        "summary": (
            "Why a mistake in a spoke should never be able to touch the hub, and "
            "how to wire layers together with remote state outputs instead."
        ),
        "category": "Infrastructure as Code",
        "tags": ["terraform", "state", "governance"],
        "author": "Sam Whitfield",
        "published_on": date(2025, 12, 5),
        "reading_minutes": 8,
        "rating": 4.6,
        "url": "https://developer.hashicorp.com/terraform/language/state/remote",
    },
    {
        "id": "oidc-github-actions-azure",
        "title": "Kill Your Cloud Secrets: OIDC from GitHub Actions to Azure",
        "summary": (
            "Federated credentials let a workflow mint short-lived Azure tokens. "
            "No client secret in the repo, no rotation to forget."
        ),
        "category": "DevOps",
        "tags": ["github-actions", "oidc", "azure"],
        "author": "Priya Raghavan",
        "published_on": date(2026, 1, 30),
        "reading_minutes": 6,
        "rating": 4.9,
        "url": "https://docs.github.com/actions/deployment/security-hardening-your-deployments",
    },
    {
        "id": "internal-ingress-patterns",
        "title": "Internal Ingress: Serving Apps That Should Never Be Public",
        "summary": (
            "An internal Azure load balancer in front of ingress-nginx keeps the "
            "front door on a private IP while preserving real HTTP routing."
        ),
        "category": "Kubernetes",
        "tags": ["ingress", "load-balancer", "aks"],
        "author": "Dana Kirchner",
        "published_on": date(2026, 2, 19),
        "reading_minutes": 10,
        "rating": 4.4,
        "url": "https://learn.microsoft.com/azure/aks/internal-lb",
    },
    {
        "id": "bff-pattern",
        "title": "The Backend-for-Frontend Pattern, Honestly Assessed",
        "summary": (
            "A BFF trades an extra hop for a stable client contract and one place "
            "to fan out. When that trade is worth it, and when it is not."
        ),
        "category": "Architecture",
        "tags": ["microservices", "api", "patterns"],
        "author": "Elena Vasquez",
        "published_on": date(2025, 10, 11),
        "reading_minutes": 9,
        "rating": 4.3,
        "url": "https://samnewman.io/patterns/architectural/bff/",
    },
    {
        "id": "acr-pull-identity",
        "title": "AcrPull Without Image Pull Secrets",
        "summary": (
            "Grant the kubelet's managed identity AcrPull and delete every "
            "imagePullSecret in your cluster. Includes the RBAC propagation gotcha."
        ),
        "category": "Security",
        "tags": ["acr", "rbac", "aks"],
        "author": "Sam Whitfield",
        "published_on": date(2026, 3, 21),
        "reading_minutes": 5,
        "rating": 4.6,
        "url": "https://learn.microsoft.com/azure/aks/cluster-container-registry-integration",
    },
    {
        "id": "resource-requests-single-node",
        "title": "Right-Sizing Requests on a One-Node Cluster",
        "summary": (
            "Requests are a scheduling contract, not a usage forecast. How to set "
            "them when your whole user pool is 2 vCPU."
        ),
        "category": "Kubernetes",
        "tags": ["scheduling", "resources", "cost"],
        "author": "Dana Kirchner",
        "published_on": date(2026, 4, 2),
        "reading_minutes": 7,
        "rating": 4.2,
        "url": "https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/",
    },
    {
        "id": "nat-gateway-egress",
        "title": "NAT Gateway vs Load Balancer Egress: Pick One, Deliberately",
        "summary": (
            "SNAT port exhaustion is the failure nobody plans for. A comparison "
            "of the three Azure egress options under real connection churn."
        ),
        "category": "Networking",
        "tags": ["azure", "nat", "egress"],
        "author": "Marcus Oyelaran",
        "published_on": date(2025, 9, 28),
        "reading_minutes": 8,
        "rating": 4.5,
        "url": "https://learn.microsoft.com/azure/nat-gateway/nat-overview",
    },
    {
        "id": "policy-as-guardrails",
        "title": "Azure Policy as Guardrails, Not Paperwork",
        "summary": (
            "Deny effects at the management group scope catch mistakes before "
            "they cost money. Start with tags, locations and public exposure."
        ),
        "category": "Governance",
        "tags": ["azure-policy", "compliance", "caf"],
        "author": "Priya Raghavan",
        "published_on": date(2026, 1, 6),
        "reading_minutes": 6,
        "rating": 4.1,
        "url": "https://learn.microsoft.com/azure/governance/policy/overview",
    },
    {
        "id": "keyvault-csi-driver",
        "title": "Mounting Key Vault Secrets with the CSI Driver",
        "summary": (
            "SecretProviderClass, rotation intervals and the sync-to-Kubernetes-"
            "Secret escape hatch — with the failure modes of each."
        ),
        "category": "Security",
        "tags": ["key-vault", "csi", "secrets"],
        "author": "Dana Kirchner",
        "published_on": date(2026, 2, 27),
        "reading_minutes": 10,
        "rating": 4.7,
        "url": "https://learn.microsoft.com/azure/aks/csi-secrets-store-driver",
    },
    {
        "id": "health-probes-done-right",
        "title": "Liveness, Readiness, Startup: Three Probes, Three Jobs",
        "summary": (
            "Pointing liveness at a dependency check is how one slow database "
            "restarts your entire fleet. A rule of thumb for each probe."
        ),
        "category": "Kubernetes",
        "tags": ["probes", "reliability", "kubernetes"],
        "author": "Elena Vasquez",
        "published_on": date(2025, 11, 3),
        "reading_minutes": 6,
        "rating": 4.8,
        "url": "https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/",
    },
    {
        "id": "distroless-python",
        "title": "Small Python Images Without Breaking Your Wheels",
        "summary": (
            "Multi-stage builds, wheel caching and why slim beats alpine for "
            "anything that compiles C extensions."
        ),
        "category": "DevOps",
        "tags": ["docker", "python", "images"],
        "author": "Sam Whitfield",
        "published_on": date(2026, 3, 14),
        "reading_minutes": 7,
        "rating": 4.4,
        "url": "https://docs.docker.com/build/building/multi-stage/",
    },
    {
        "id": "observability-oms-agent",
        "title": "Container Insights Without the Bill Shock",
        "summary": (
            "The OMS agent ships everything by default. Which streams actually "
            "earn their ingestion cost, and how to switch the rest off."
        ),
        "category": "Observability",
        "tags": ["monitoring", "log-analytics", "cost"],
        "author": "Priya Raghavan",
        "published_on": date(2026, 4, 11),
        "reading_minutes": 9,
        "rating": 4.3,
        "url": "https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview",
    },
    {
        "id": "peering-is-not-transitive",
        "title": "VNet Peering Is Not Transitive (And What It Costs You)",
        "summary": (
            "Jump-to-hub plus spoke-to-hub does not give you jump-to-spoke. The "
            "three ways out, ranked by operational burden."
        ),
        "category": "Networking",
        "tags": ["peering", "routing", "azure"],
        "author": "Marcus Oyelaran",
        "published_on": date(2025, 12, 18),
        "reading_minutes": 5,
        "rating": 4.6,
        "url": "https://learn.microsoft.com/azure/virtual-network/virtual-network-peering-overview",
    },
    {
        "id": "gitops-vs-pipeline-deploy",
        "title": "Pipeline Push vs GitOps Pull for Private Clusters",
        "summary": (
            "A private API server means your runner needs a route in. Compare a "
            "self-hosted runner against an in-cluster reconciler."
        ),
        "category": "DevOps",
        "tags": ["gitops", "ci-cd", "aks"],
        "author": "Elena Vasquez",
        "published_on": date(2026, 4, 25),
        "reading_minutes": 11,
        "rating": 4.5,
        "url": "https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-gitops-flux2",
    },
]

CATALOG: list[ContentItem] = [ContentItem(**row) for row in _SEED]


def all_categories() -> list[str]:
    return sorted({item.category for item in CATALOG})


def query(
    *,
    category: str | None = None,
    search: str | None = None,
    tag: str | None = None,
) -> list[ContentItem]:
    """Filter the catalog. All filters are ANDed; matching is case-insensitive.

    Returns newest-first so a client that ignores paging still sees fresh items.
    """
    results = CATALOG

    if category:
        needle = category.casefold()
        results = [i for i in results if i.category.casefold() == needle]

    if tag:
        needle = tag.casefold()
        results = [i for i in results if any(t.casefold() == needle for t in i.tags)]

    if search:
        needle = search.casefold()
        results = [
            i
            for i in results
            if needle in i.title.casefold()
            or needle in i.summary.casefold()
            or needle in i.author.casefold()
            or any(needle in t.casefold() for t in i.tags)
        ]

    return sorted(results, key=lambda i: i.published_on, reverse=True)


def get(item_id: str) -> ContentItem | None:
    return next((i for i in CATALOG if i.id == item_id), None)
