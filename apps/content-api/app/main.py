"""content-api — the system of record for catalog content.

The innermost of the three services. It has no downstream dependencies, so its
readiness probe is a pure self-check: if the process is up, it can serve.
Only the BFF talks to it; it is never exposed through the ingress.
"""

from __future__ import annotations

import logging
import os
import socket

from fastapi import FastAPI, HTTPException, Query, Response

from . import data
from .models import Category, ContentItem, Health, ItemPage

SERVICE_NAME = "content-api"
VERSION = os.getenv("APP_VERSION", "0.1.0")
# HOSTNAME is the pod name under Kubernetes — surfacing it makes it obvious in
# the UI which replica answered, which is the whole point of the demo.
INSTANCE = os.getenv("HOSTNAME", socket.gethostname())

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","svc":"' + SERVICE_NAME + '","msg":"%(message)s"}',
)
log = logging.getLogger(SERVICE_NAME)

app = FastAPI(
    title="Content API",
    version=VERSION,
    description="Owns the content catalog. Consumed by the backend BFF only.",
    docs_url="/docs",
    openapi_url="/openapi.json",
)


@app.get("/healthz", response_model=Health, tags=["health"])
def healthz() -> Health:
    """Liveness. Deliberately checks nothing external — see the probe rules in
    the README: a liveness probe that fails on a dependency outage turns a
    partial outage into a restart storm."""
    return Health(status="ok", service=SERVICE_NAME, version=VERSION, instance=INSTANCE)


@app.get("/readyz", response_model=Health, tags=["health"])
def readyz() -> Health:
    """Readiness. No downstream dependencies, so it mirrors liveness."""
    return Health(status="ready", service=SERVICE_NAME, version=VERSION, instance=INSTANCE)


@app.get("/api/v1/categories", response_model=list[Category], tags=["catalog"])
def list_categories() -> list[Category]:
    counts: dict[str, int] = {}
    for item in data.CATALOG:
        counts[item.category] = counts.get(item.category, 0) + 1
    return [Category(name=name, item_count=counts[name]) for name in data.all_categories()]


@app.get("/api/v1/items", response_model=ItemPage, tags=["catalog"])
def list_items(
    response: Response,
    category: str | None = Query(None, description="Exact category match, case-insensitive."),
    tag: str | None = Query(None, description="Exact tag match, case-insensitive."),
    q: str | None = Query(None, description="Free-text search over title, summary, author and tags."),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> ItemPage:
    matched = data.query(category=category, search=q, tag=tag)
    page = matched[offset : offset + limit]

    log.info("items query category=%s tag=%s q=%s -> %d/%d", category, tag, q, len(page), len(matched))
    response.headers["X-Served-By"] = INSTANCE

    return ItemPage(items=page, total=len(matched), limit=limit, offset=offset)


@app.get("/api/v1/items/{item_id}", response_model=ContentItem, tags=["catalog"])
def get_item(item_id: str, response: Response) -> ContentItem:
    item = data.get(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail=f"No content item with id '{item_id}'")
    response.headers["X-Served-By"] = INSTANCE
    return item
