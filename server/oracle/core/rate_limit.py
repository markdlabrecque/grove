"""Per-token token-bucket rate limiter for the bearer-auth middleware.

Design
------
Token bucket algorithm: each (token, route_class) pair gets its own bucket
that starts full at ``burst_multiplier × rate_per_min`` tokens. Tokens refill
continuously at ``rate_per_min / 60`` per second. A request consumes one token;
if the bucket is empty the request is refused.

Route classes
-------------
  capture  → path starts with /v1/captures
  query    → path starts with /v1/queries
  default  → everything else

Bucket storage
--------------
Buckets are kept in the module-level ``_buckets`` dict (in-process memory).
This is correct and sufficient for V1, which runs as a single process.

IMPORTANT — multi-process caveat: if The Oracle is ever scaled to more than one
worker process (e.g. ``uvicorn --workers N`` or multiple container replicas),
each process will maintain its own independent bucket dict. A client can then
exceed the nominal rate by routing requests across processes. When that happens,
replace this module's storage with a Redis-backed implementation (e.g. using
redis-py async + a Lua script for atomic check-and-decrement).

Usage
-----
Rate limiting is wired into the FastAPI dependency graph via ``check_rate_limit``
(see ``oracle.core.auth``). The dependency runs AFTER authentication resolves the
token, so the bucket key is always the validated bearer token — never a raw
header value. Unauthenticated requests (rejected by auth before this runs) would
use the sentinel ``"<anonymous>"`` if they somehow reached this code, which keeps
the limiter from crashing on a missing token.
"""

from __future__ import annotations

import math
import time
from enum import Enum, auto
from typing import TYPE_CHECKING

import structlog

if TYPE_CHECKING:
    from oracle.core.config import Settings

logger = structlog.get_logger()


class RouteClass(Enum):
    CAPTURE = auto()
    QUERY = auto()
    DEFAULT = auto()


def classify_route(path: str) -> RouteClass:
    """Map a request path to one of the three rate-limit buckets.

    Matching is intentionally explicit to avoid clever regex surprises.
    """
    if path == "/v1/captures" or path.startswith("/v1/captures/"):
        return RouteClass.CAPTURE
    if path == "/v1/queries" or path.startswith("/v1/queries/"):
        return RouteClass.QUERY
    return RouteClass.DEFAULT


class TokenBucket:
    """Thread-safe-enough token bucket for a single asyncio event loop.

    asyncio is single-threaded; no locking is needed. If this code is
    ever called from a thread pool (sync endpoint), revisit.
    """

    def __init__(self, rate_per_min: int, burst_multiplier: int) -> None:
        self._rate_per_sec: float = rate_per_min / 60.0
        self._capacity: float = rate_per_min * burst_multiplier
        self._tokens: float = self._capacity
        self._last_refill: float = time.monotonic()

    def _refill(self) -> None:
        now = time.monotonic()
        elapsed = now - self._last_refill
        self._tokens = min(self._capacity, self._tokens + elapsed * self._rate_per_sec)
        self._last_refill = now

    def consume(self) -> tuple[bool, int]:
        """Attempt to consume one token.

        Returns (allowed, retry_after_seconds).
        retry_after_seconds is 0 when allowed=True, and a positive ceiling
        value when allowed=False (seconds until at least one token refills).
        """
        self._refill()
        if self._tokens >= 1.0:
            self._tokens -= 1.0
            return True, 0
        # Compute how long until the bucket has 1 token again.
        deficit = 1.0 - self._tokens
        secs = deficit / self._rate_per_sec
        return False, math.ceil(secs)


# Module-level bucket registry: (token, RouteClass) → TokenBucket
_buckets: dict[tuple[str, RouteClass], TokenBucket] = {}

# Indirection so tests can patch settings without reloading the module.
# Production code reads from the real settings singleton; test overrides
# replace this reference via unittest.mock.patch.
#
# WARNING (#267): treat _current_settings as a unittest.mock.patch seam ONLY.
# It must never be assigned from non-test code — a stray write in production
# would silently swap every subsequent rate-limit-config read. If you need a
# different Settings object outside a patch context, pass it explicitly via
# the `override_settings` parameter on `consume_for_request` /
# `get_rate_limit_config` instead.
_current_settings: Settings | None = None


def _get_settings() -> Settings:
    if _current_settings is not None:
        return _current_settings
    from oracle.core.config import settings

    return settings


def get_rate_limit_config(
    route_class: RouteClass, override_settings: Settings | None = None
) -> dict:
    """Return rate_per_min and burst_multiplier for the given route class."""
    s = override_settings if override_settings is not None else _get_settings()
    burst = s.rate_limit_burst_multiplier
    if route_class == RouteClass.CAPTURE:
        return {"rate_per_min": s.rate_limit_capture_per_min, "burst_multiplier": burst}
    if route_class == RouteClass.QUERY:
        return {"rate_per_min": s.rate_limit_query_per_min, "burst_multiplier": burst}
    return {"rate_per_min": s.rate_limit_default_per_min, "burst_multiplier": burst}


def consume_for_request(
    token: str,
    route_class: RouteClass,
    override_settings: Settings | None = None,
) -> tuple[bool, int]:
    """Consume one request from the (token, route_class) bucket.

    Creates the bucket on first use. Returns (allowed, retry_after_seconds).
    """
    key = (token, route_class)
    if key not in _buckets:
        cfg = get_rate_limit_config(route_class, override_settings)
        _buckets[key] = TokenBucket(**cfg)
    return _buckets[key].consume()
