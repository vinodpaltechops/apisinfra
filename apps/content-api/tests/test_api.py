from fastapi.testclient import TestClient

from app.data import CATALOG
from app.main import app

client = TestClient(app)


def test_healthz_and_readyz_report_the_service():
    for path in ("/healthz", "/readyz"):
        body = client.get(path).json()
        assert body["service"] == "content-api"
        assert body["instance"]


def test_list_items_defaults_to_first_page_newest_first():
    body = client.get("/api/v1/items").json()

    assert body["total"] == len(CATALOG)
    assert body["offset"] == 0
    assert len(body["items"]) == min(20, len(CATALOG))

    published = [item["published_on"] for item in body["items"]]
    assert published == sorted(published, reverse=True)


def test_paging_slices_without_overlap():
    first = client.get("/api/v1/items?limit=5&offset=0").json()
    second = client.get("/api/v1/items?limit=5&offset=5").json()

    assert len(first["items"]) == 5
    assert {i["id"] for i in first["items"]}.isdisjoint({i["id"] for i in second["items"]})


def test_category_filter_is_case_insensitive():
    body = client.get("/api/v1/items?category=kubernetes").json()

    assert body["total"] > 0
    assert {i["category"] for i in body["items"]} == {"Kubernetes"}


def test_search_matches_tags_and_titles():
    by_tag = client.get("/api/v1/items?q=oidc").json()
    assert by_tag["total"] >= 2

    by_title = client.get("/api/v1/items?q=Peering Is Not Transitive").json()
    assert by_title["total"] == 1
    assert by_title["items"][0]["id"] == "peering-is-not-transitive"


def test_filters_combine_as_and():
    body = client.get("/api/v1/items?category=Security&q=identity").json()
    assert body["total"] >= 1
    assert all(i["category"] == "Security" for i in body["items"])


def test_categories_counts_sum_to_catalog_size():
    cats = client.get("/api/v1/categories").json()
    assert sum(c["item_count"] for c in cats) == len(CATALOG)
    assert [c["name"] for c in cats] == sorted(c["name"] for c in cats)


def test_get_item_by_id_and_404():
    ok = client.get("/api/v1/items/private-aks-dns")
    assert ok.status_code == 200
    assert ok.json()["title"].startswith("Private AKS Clusters")

    missing = client.get("/api/v1/items/does-not-exist")
    assert missing.status_code == 404


def test_limit_is_bounded():
    assert client.get("/api/v1/items?limit=0").status_code == 422
    assert client.get("/api/v1/items?limit=500").status_code == 422
