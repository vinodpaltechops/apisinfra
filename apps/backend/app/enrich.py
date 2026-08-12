"""Presentation logic — the value the BFF adds over a plain proxy."""

from __future__ import annotations

from datetime import date, timedelta

from .models import CatalogItem, CatalogStats, CategoryStat

# "New" is measured against the freshest item in the catalog rather than against
# today, so the badge keeps working long after the seed data stops being recent.
NEW_WINDOW = timedelta(days=90)


def _reading_time_label(minutes: int) -> str:
    if minutes < 1:
        return "quick read"
    return f"{minutes} min read"


def _parse(published_on: str) -> date:
    return date.fromisoformat(published_on)


def to_catalog_items(raw_items: list[dict]) -> list[CatalogItem]:
    if not raw_items:
        return []

    newest = max(_parse(item["published_on"]) for item in raw_items)
    cutoff = newest - NEW_WINDOW

    return [
        CatalogItem(
            id=item["id"],
            title=item["title"],
            summary=item["summary"],
            category=item["category"],
            tags=item.get("tags", []),
            author=item["author"],
            published_on=item["published_on"],
            rating=item["rating"],
            url=item["url"],
            reading_minutes=item["reading_minutes"],
            reading_time_label=_reading_time_label(item["reading_minutes"]),
            is_new=_parse(item["published_on"]) >= cutoff,
        )
        for item in raw_items
    ]


def build_stats(items: list[CatalogItem], total_matching: int) -> CatalogStats:
    """Aggregates over the returned page, except `total_items`, which is the
    full match count reported by content-api."""
    if not items:
        return CatalogStats(
            total_items=total_matching,
            returned=0,
            average_rating=0.0,
            total_reading_minutes=0,
            categories=[],
        )

    counts: dict[str, int] = {}
    for item in items:
        counts[item.category] = counts.get(item.category, 0) + 1

    return CatalogStats(
        total_items=total_matching,
        returned=len(items),
        average_rating=round(sum(i.rating for i in items) / len(items), 2),
        total_reading_minutes=sum(i.reading_minutes for i in items),
        categories=[CategoryStat(name=name, item_count=counts[name]) for name in sorted(counts)],
    )
