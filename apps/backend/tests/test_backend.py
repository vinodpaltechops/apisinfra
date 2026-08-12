import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app.main import app

from .conftest import CONTENT_API, ITEM_A, ITEM_B


def _items_page(items, total=None):
    return {"items": items, "total": total if total is not None else len(items), "limit": 20, "offset": 0}


@respx.mock
def test_catalog_enriches_and_aggregates():
    respx.get(f"{CONTENT_API}/api/v1/items").mock(
        return_value=httpx.Response(200, json=_items_page([ITEM_A, ITEM_B], total=18))
    )

    with TestClient(app) as client:
        body = client.get("/api/v1/catalog").json()

    assert [i["id"] for i in body["items"]] == ["private-aks-dns", "hub-spoke-landing-zone"]

    newest, oldest = body["items"]
    assert newest["reading_time_label"] == "9 min read"
    assert newest["is_new"] is True
    # >90 days behind the freshest item in the page.
    assert oldest["is_new"] is False

    stats = body["stats"]
    assert stats["total_items"] == 18  # full match count, not the page size
    assert stats["returned"] == 2
    assert stats["average_rating"] == 4.8
    assert stats["total_reading_minutes"] == 21
    assert stats["categories"] == [
        {"name": "Architecture", "item_count": 1},
        {"name": "Kubernetes", "item_count": 1},
    ]
    assert body["cache_hit"] is False
    assert body["served_by"]


@respx.mock
def test_filters_are_forwarded_to_content_api():
    route = respx.get(f"{CONTENT_API}/api/v1/items").mock(
        return_value=httpx.Response(200, json=_items_page([ITEM_A]))
    )

    with TestClient(app) as client:
        client.get("/api/v1/catalog?category=Kubernetes&q=dns&tag=aks&limit=5&offset=10")

    params = route.calls.last.request.url.params
    assert params["category"] == "Kubernetes"
    assert params["q"] == "dns"
    assert params["tag"] == "aks"
    assert params["limit"] == "5"
    assert params["offset"] == "10"


@respx.mock
def test_second_identical_request_is_served_from_cache():
    route = respx.get(f"{CONTENT_API}/api/v1/items").mock(
        return_value=httpx.Response(200, json=_items_page([ITEM_A]))
    )

    with TestClient(app) as client:
        first = client.get("/api/v1/catalog").json()
        second = client.get("/api/v1/catalog").json()

    assert route.call_count == 1
    assert first["cache_hit"] is False
    assert second["cache_hit"] is True
    assert first["items"] == second["items"]


@respx.mock
def test_different_filters_do_not_share_a_cache_entry():
    route = respx.get(f"{CONTENT_API}/api/v1/items").mock(
        return_value=httpx.Response(200, json=_items_page([ITEM_A]))
    )

    with TestClient(app) as client:
        client.get("/api/v1/catalog?category=Kubernetes")
        client.get("/api/v1/catalog?category=Security")

    assert route.call_count == 2


@respx.mock
def test_transient_5xx_is_retried_then_succeeds():
    route = respx.get(f"{CONTENT_API}/api/v1/items").mock(
        side_effect=[
            httpx.Response(503),
            httpx.Response(200, json=_items_page([ITEM_A])),
        ]
    )

    with TestClient(app) as client:
        response = client.get("/api/v1/catalog")

    assert response.status_code == 200
    assert route.call_count == 2


@respx.mock
def test_unreachable_content_api_surfaces_as_503_not_500():
    respx.get(f"{CONTENT_API}/api/v1/items").mock(side_effect=httpx.ConnectError("refused"))

    with TestClient(app) as client:
        response = client.get("/api/v1/catalog")

    assert response.status_code == 503
    assert "unavailable" in response.json()["detail"].lower()


@respx.mock
def test_missing_item_is_404_not_503():
    respx.get(f"{CONTENT_API}/api/v1/items/nope").mock(return_value=httpx.Response(404))

    with TestClient(app) as client:
        assert client.get("/api/v1/catalog/nope").status_code == 404


@respx.mock
def test_liveness_ignores_downstream_but_readiness_does_not():
    respx.get(f"{CONTENT_API}/healthz").mock(side_effect=httpx.ConnectError("refused"))

    with TestClient(app) as client:
        assert client.get("/healthz").status_code == 200

        ready = client.get("/readyz")
        assert ready.status_code == 503
        assert ready.json()["dependencies"]["content-api"] == "unreachable"


@respx.mock
def test_readiness_reports_the_upstream_instance_when_healthy():
    respx.get(f"{CONTENT_API}/healthz").mock(
        return_value=httpx.Response(
            200,
            json={"status": "ok", "service": "content-api", "version": "0.1.0", "instance": "pod-xyz"},
        )
    )

    with TestClient(app) as client:
        body = client.get("/readyz").json()

    assert body["status"] == "ready"
    assert "pod-xyz" in body["dependencies"]["content-api"]


@respx.mock
def test_meta_degrades_when_content_api_is_down():
    respx.get(f"{CONTENT_API}/healthz").mock(side_effect=httpx.ConnectError("refused"))

    with TestClient(app) as client:
        body = client.get("/api/v1/meta").json()

    statuses = {s["name"]: s["status"] for s in body["services"]}
    assert statuses == {"backend": "ok", "content-api": "unreachable"}
    assert body["categories"] == []


@respx.mock
def test_meta_returns_the_service_chain_and_categories():
    respx.get(f"{CONTENT_API}/healthz").mock(
        return_value=httpx.Response(
            200,
            json={"status": "ok", "service": "content-api", "version": "1.2.3", "instance": "pod-abc"},
        )
    )
    respx.get(f"{CONTENT_API}/api/v1/categories").mock(
        return_value=httpx.Response(200, json=[{"name": "Kubernetes", "item_count": 5}])
    )

    with TestClient(app) as client:
        body = client.get("/api/v1/meta").json()

    assert body["services"][1] == {
        "name": "content-api",
        "version": "1.2.3",
        "instance": "pod-abc",
        "status": "ok",
    }
    assert body["categories"] == [{"name": "Kubernetes", "item_count": 5}]


@pytest.mark.parametrize("query", ["limit=0", "limit=1000", "offset=-1"])
@respx.mock
def test_paging_params_are_validated(query):
    respx.get(f"{CONTENT_API}/api/v1/items").mock(
        return_value=httpx.Response(200, json=_items_page([ITEM_A]))
    )

    with TestClient(app) as client:
        assert client.get(f"/api/v1/catalog?{query}").status_code == 422
