"""HTTP client for content-api.

Wraps httpx with a bounded retry so a single rescheduled content-api pod does
not surface as a user-visible error. Retries only on connect/timeout/5xx — a
404 or 422 is an answer, not a failure, and retrying it just burns budget.
"""

from __future__ import annotations

import asyncio
import logging

import httpx

from .config import settings

log = logging.getLogger("backend.client")


class ContentApiError(Exception):
    """content-api could not be reached or returned a server error."""

    def __init__(self, message: str, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


class ContentApiClient:
    def __init__(self, base_url: str | None = None) -> None:
        self._base_url = (base_url or settings.content_api_url).rstrip("/")
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            timeout=httpx.Timeout(settings.request_timeout_seconds),
            headers={"User-Agent": f"backend-bff/{settings.version}"},
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _get(self, path: str, params: dict | None = None) -> httpx.Response:
        last_error: Exception | None = None

        for attempt in range(settings.max_retries + 1):
            try:
                response = await self._client.get(path, params=params)
            except (httpx.ConnectError, httpx.TimeoutException) as exc:
                last_error = exc
                log.warning("content-api %s attempt %d failed: %s", path, attempt + 1, exc)
            else:
                if response.status_code < 500:
                    return response
                last_error = ContentApiError(
                    f"content-api returned {response.status_code}", response.status_code
                )
                log.warning("content-api %s attempt %d -> %d", path, attempt + 1, response.status_code)

            if attempt < settings.max_retries:
                # Linear backoff — with a 3s budget and 2 retries, exponential
                # would blow past the client's patience.
                await asyncio.sleep(0.15 * (attempt + 1))

        raise ContentApiError(f"content-api unreachable at {self._base_url}{path}: {last_error}")

    async def list_items(
        self,
        *,
        category: str | None = None,
        tag: str | None = None,
        q: str | None = None,
        limit: int = 20,
        offset: int = 0,
    ) -> dict:
        params: dict[str, str | int] = {"limit": limit, "offset": offset}
        if category:
            params["category"] = category
        if tag:
            params["tag"] = tag
        if q:
            params["q"] = q

        response = await self._get("/api/v1/items", params)
        response.raise_for_status()
        return response.json()

    async def get_item(self, item_id: str) -> dict | None:
        response = await self._get(f"/api/v1/items/{item_id}")
        if response.status_code == 404:
            return None
        response.raise_for_status()
        return response.json()

    async def list_categories(self) -> list[dict]:
        response = await self._get("/api/v1/categories")
        response.raise_for_status()
        return response.json()

    async def health(self) -> dict:
        """Used by /readyz. Raises ContentApiError if the dependency is down."""
        response = await self._get("/healthz")
        response.raise_for_status()
        return response.json()
