import pytest

from app.main import cache

# content-api's default base URL (app.config.Settings) — what respx intercepts.
CONTENT_API = "http://localhost:8000"

ITEM_A = {
    "id": "private-aks-dns",
    "title": "Private AKS Clusters and the BYO DNS Zone Trap",
    "summary": "Bring your own zone and link it to the hub.",
    "category": "Kubernetes",
    "tags": ["aks", "dns"],
    "author": "Marcus Oyelaran",
    "published_on": "2026-02-03",
    "reading_minutes": 9,
    "rating": 4.9,
    "url": "https://example.invalid/a",
}

ITEM_B = {
    "id": "hub-spoke-landing-zone",
    "title": "Designing a Hub-Spoke Landing Zone on Azure",
    "summary": "How the CAF splits connectivity from workloads.",
    "category": "Architecture",
    "tags": ["azure", "caf"],
    "author": "Priya Raghavan",
    "published_on": "2025-01-14",  # far older than ITEM_A -> not "new"
    "reading_minutes": 12,
    "rating": 4.7,
    "url": "https://example.invalid/b",
}


@pytest.fixture(autouse=True)
def clear_cache():
    """The BFF cache is process-global; leaking entries between tests would make
    assertions on cache_hit order-dependent."""
    cache.clear()
    yield
    cache.clear()
