"""Runtime configuration, all from the environment (12-factor).

In the cluster these come from the `backend-config` ConfigMap. Defaults here
match docker-compose so `docker compose up` needs no extra wiring.
"""

from __future__ import annotations

import os
import socket
from dataclasses import dataclass


def _int_env(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _float_env(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return float(raw)
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    service_name: str = "backend"
    version: str = os.getenv("APP_VERSION", "0.1.0")
    instance: str = os.getenv("HOSTNAME", socket.gethostname())

    # In-cluster this is the content-api ClusterIP service DNS name.
    content_api_url: str = os.getenv("CONTENT_API_URL", "http://localhost:8000").rstrip("/")

    # Per-request budget against content-api. Kept well under the frontend's own
    # patience so a slow upstream surfaces as a 503 here, not a browser hang.
    request_timeout_seconds: float = _float_env("CONTENT_API_TIMEOUT_SECONDS", 3.0)
    max_retries: int = _int_env("CONTENT_API_MAX_RETRIES", 2)

    # Short TTL: the catalog is effectively static, but a stale window this small
    # keeps the demo honest about cache invalidation.
    cache_ttl_seconds: float = _float_env("CACHE_TTL_SECONDS", 30.0)

    log_level: str = os.getenv("LOG_LEVEL", "INFO").upper()


settings = Settings()
