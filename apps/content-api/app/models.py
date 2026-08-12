"""Response/domain models for the content API.

Kept deliberately small: this service owns the canonical shape of a content
item. The BFF (backend) enriches these for presentation but never changes the
field names, so a schema change here is a versioned API change (/api/v1).
"""

from __future__ import annotations

from datetime import date

from pydantic import BaseModel, Field


class ContentItem(BaseModel):
    id: str = Field(..., description="Stable slug — safe to use in URLs.")
    title: str
    summary: str
    category: str
    tags: list[str] = []
    author: str
    published_on: date
    reading_minutes: int = Field(..., ge=1)
    rating: float = Field(..., ge=0, le=5)
    url: str


class Category(BaseModel):
    name: str
    item_count: int


class ItemPage(BaseModel):
    """A slice of the catalog plus enough metadata for a client to paginate."""

    items: list[ContentItem]
    total: int = Field(..., description="Total matching the filter, ignoring paging.")
    limit: int
    offset: int


class Health(BaseModel):
    status: str
    service: str
    version: str
    instance: str
