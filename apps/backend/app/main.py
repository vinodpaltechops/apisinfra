"""backend — the backend-for-frontend.

Sits between the browser and content-api. Everything the frontend calls goes
through here under /api/v1, which is also the path the ingress routes to this
service. It never serves static assets; the frontend pod does that.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query, Response

from .cache import TTLCache
from .client import ContentApiClient, ContentApiError
from .config import settings
from .enrich import build_stats, to_catalog_items
from .models import (
    CatalogItem,
    CatalogResponse,
    CategoryStat,
    Health,
    MetaResponse,
    ServiceInfo,
)

logging.basicConfig(
    level=settings.log_level,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","svc":"backend","msg":"%(message)s"}',
)
log = logging.getLogger("backend")

cache = TTLCache(settings.cache_ttl_seconds)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """One shared httpx client for the process — a per-request client would open
    a new TCP connection every time and exhaust SNAT ports under load."""
    app.state.content_api = ContentApiClient()
    log.info("backend %s starting, content-api=%s", settings.version, settings.content_api_url)
    yield
    await app.state.content_api.aclose()


app = FastAPI(
    title="Catalog BFF",
    version=settings.version,
    description="Aggregates and enriches content-api for the web frontend.",
    lifespan=lifespan,
)


def _cache_key(prefix: str, **parts) -> str:
    return prefix + "|" + "|".join(f"{k}={v}" for k, v in sorted(parts.items()) if v is not None)


# ── Health ────────────────────────────────────────────────────────────────────
@app.get("/healthz", response_model=Health, tags=["health"])
def healthz() -> Health:
    """Liveness: is this process able to serve? Does NOT touch content-api —
    a downstream outage must not restart every backend pod."""
    return Health(
        status="ok",
        service=settings.service_name,
        version=settings.version,
        instance=settings.instance,
    )


@app.get("/readyz", response_model=Health, tags=["health"])
async def readyz(response: Response) -> Health:
    """Readiness: can this pod serve *useful* traffic? It cannot without
    content-api, so a dependency failure pulls the pod out of the Service
    endpoints without killing it."""
    try:
        upstream = await app.state.content_api.health()
    except ContentApiError as exc:
        log.warning("readiness failed: %s", exc)
        response.status_code = 503
        return Health(
            status="degraded",
            service=settings.service_name,
            version=settings.version,
            instance=settings.instance,
            dependencies={"content-api": "unreachable"},
        )

    return Health(
        status="ready",
        service=settings.service_name,
        version=settings.version,
        instance=settings.instance,
        dependencies={"content-api": f"ok ({upstream.get('instance', 'unknown')})"},
    )


# ── Catalog ───────────────────────────────────────────────────────────────────
@app.get("/api/v1/catalog", response_model=CatalogResponse, tags=["catalog"])
async def get_catalog(
    category: str | None = Query(None),
    tag: str | None = Query(None),
    q: str | None = Query(None, description="Free-text search."),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> CatalogResponse:
    key = _cache_key("catalog", category=category, tag=tag, q=q, limit=limit, offset=offset)

    cached = cache.get(key)
    if cached is not None:
        return cached.model_copy(update={"cache_hit": True, "served_by": settings.instance})

    try:
        page = await app.state.content_api.list_items(
            category=category, tag=tag, q=q, limit=limit, offset=offset
        )
    except ContentApiError as exc:
        log.error("catalog fetch failed: %s", exc)
        raise HTTPException(status_code=503, detail="Content service is unavailable") from exc

    items = to_catalog_items(page["items"])
    result = CatalogResponse(
        items=items,
        stats=build_stats(items, page["total"]),
        limit=page["limit"],
        offset=page["offset"],
        served_by=settings.instance,
        cache_hit=False,
    )

    cache.set(key, result)
    log.info("catalog category=%s q=%s -> %d items", category, q, len(items))
    return result


@app.get("/api/v1/catalog/{item_id}", response_model=CatalogItem, tags=["catalog"])
async def get_catalog_item(item_id: str) -> CatalogItem:
    key = _cache_key("item", id=item_id)

    cached = cache.get(key)
    if cached is not None:
        return cached

    try:
        raw = await app.state.content_api.get_item(item_id)
    except ContentApiError as exc:
        raise HTTPException(status_code=503, detail="Content service is unavailable") from exc

    if raw is None:
        raise HTTPException(status_code=404, detail=f"No content item with id '{item_id}'")

    item = to_catalog_items([raw])[0]
    cache.set(key, item)
    return item


@app.get("/api/v1/meta", response_model=MetaResponse, tags=["meta"])
async def get_meta() -> MetaResponse:
    """Service chain + categories in one call, so the UI can render its filter
    bar and its 'served by' footer without a second round trip."""
    upstream_status = "unreachable"
    upstream_version = "unknown"
    upstream_instance = "unknown"
    categories: list[CategoryStat] = []

    try:
        health = await app.state.content_api.health()
        upstream_status = "ok"
        upstream_version = health.get("version", "unknown")
        upstream_instance = health.get("instance", "unknown")
        categories = [CategoryStat(**c) for c in await app.state.content_api.list_categories()]
    except ContentApiError as exc:
        # Degrade rather than fail: the shell of the UI is still useful.
        log.warning("meta: content-api unavailable: %s", exc)

    return MetaResponse(
        services=[
            ServiceInfo(
                name="backend",
                version=settings.version,
                instance=settings.instance,
                status="ok",
            ),
            ServiceInfo(
                name="content-api",
                version=upstream_version,
                instance=upstream_instance,
                status=upstream_status,
            ),
        ],
        categories=categories,
        cache=cache.stats(),
    )
