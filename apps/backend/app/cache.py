"""A tiny in-process TTL cache.

Deliberately not Redis: another pod does not fit in the 2 vCPU user pool, and a
per-replica cache is the right default for read-only catalog data. The cost is
that two replicas can briefly disagree — acceptable for a catalog, not for
anything transactional.
"""

from __future__ import annotations

import time
from typing import Any


class TTLCache:
    def __init__(self, ttl_seconds: float) -> None:
        self._ttl = ttl_seconds
        self._store: dict[str, tuple[float, Any]] = {}
        self.hits = 0
        self.misses = 0

    def get(self, key: str) -> Any | None:
        entry = self._store.get(key)
        if entry is None:
            self.misses += 1
            return None

        expires_at, value = entry
        if time.monotonic() >= expires_at:
            del self._store[key]
            self.misses += 1
            return None

        self.hits += 1
        return value

    def set(self, key: str, value: Any) -> None:
        self._store[key] = (time.monotonic() + self._ttl, value)

    def clear(self) -> None:
        self._store.clear()

    @property
    def size(self) -> int:
        return len(self._store)

    def stats(self) -> dict[str, int]:
        return {"entries": self.size, "hits": self.hits, "misses": self.misses}
