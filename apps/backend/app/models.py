"""View models the frontend consumes.

These are the BFF's contract. They intentionally differ from content-api's
models: presentation fields (`reading_time_label`, `is_new`) are computed here
so the frontend stays dumb and content-api stays free of display concerns.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class CatalogItem(BaseModel):
    id: str
    title: str
    summary: str
    category: str
    tags: list[str] = []
    author: str
    published_on: str
    rating: float
    url: str

    # ── Computed by the BFF ────────────────────────────────────────────────────
    reading_minutes: int
    reading_time_label: str = Field(..., description="e.g. '9 min read'")
    is_new: bool = Field(..., description="Published within 90 days of the newest item.")


class CategoryStat(BaseModel):
    name: str
    item_count: int


class CatalogStats(BaseModel):
    total_items: int = Field(..., description="Total matching the filter, across all pages.")
    returned: int
    average_rating: float
    total_reading_minutes: int
    categories: list[CategoryStat]


class CatalogResponse(BaseModel):
    items: list[CatalogItem]
    stats: CatalogStats
    limit: int
    offset: int
    served_by: str = Field(..., description="Pod that assembled this response.")
    cache_hit: bool


class ServiceInfo(BaseModel):
    name: str
    version: str
    instance: str
    status: str


class MetaResponse(BaseModel):
    """Lets the UI show the live service chain — the point of a microservices demo."""

    services: list[ServiceInfo]
    categories: list[CategoryStat]
    cache: dict[str, int]


class Health(BaseModel):
    status: str
    service: str
    version: str
    instance: str
    dependencies: dict[str, str] = {}
