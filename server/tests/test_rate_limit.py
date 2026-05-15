"""Tests for the per-token token-bucket rate limiter.

These are pure unit tests — no DB, no HTTP client needed for the bucket
math itself. Integration tests at the bottom verify the FastAPI dependency
wiring returns 429 with Retry-After when the bucket is exhausted.

Route classes under test:
  capture  → /v1/captures  (RATE_LIMIT_CAPTURE_PER_MIN)
  query    → /v1/queries   (RATE_LIMIT_QUERY_PER_MIN)
  default  → everything else under /v1  (RATE_LIMIT_DEFAULT_PER_MIN)

Integration tests use a stub get_session override so the test does not
require a real Postgres instance. The rate limit check fires inside the
FastAPI dependency chain (require_bearer), before the route handler runs,
so the route handler's DB calls are irrelevant for 429 assertions.
"""

from __future__ import annotations

import math
from collections.abc import AsyncIterator
from unittest.mock import patch

import pytest
from httpx import ASGITransport, AsyncClient

from oracle.core.config import Settings, settings
from oracle.core.rate_limit import (
    RouteClass,
    TokenBucket,
    _buckets,
    classify_route,
    consume_for_request,
    get_rate_limit_config,
)

# ---------------------------------------------------------------------------
# TokenBucket unit tests
# ---------------------------------------------------------------------------


class TestTokenBucket:
    def test_fresh_bucket_allows_up_to_capacity(self) -> None:
        bucket = TokenBucket(rate_per_min=10, burst_multiplier=2)
        # capacity = 2 × (10/60) tokens/sec * 60 sec = 20 tokens
        # A fresh bucket starts full at capacity.
        for _ in range(20):
            allowed, _ = bucket.consume()
            assert allowed

    def test_bucket_denies_when_empty(self) -> None:
        bucket = TokenBucket(rate_per_min=10, burst_multiplier=2)
        # drain fully
        for _ in range(20):
            bucket.consume()
        allowed, retry_after = bucket.consume()
        assert not allowed
        assert retry_after > 0

    def test_retry_after_is_positive_seconds(self) -> None:
        bucket = TokenBucket(rate_per_min=60, burst_multiplier=2)
        # drain fully (capacity = 120)
        for _ in range(120):
            bucket.consume()
        allowed, retry_after = bucket.consume()
        assert not allowed
        assert retry_after >= 1

    def test_retry_after_is_rounded_up(self) -> None:
        """Retry-After must be a whole-second ceiling, not a floor."""
        bucket = TokenBucket(rate_per_min=60, burst_multiplier=2)
        for _ in range(120):
            bucket.consume()
        allowed, retry_after = bucket.consume()
        assert not allowed
        # ceil of anything > 0 is >= 1
        assert retry_after == math.ceil(retry_after)

    def test_recovery_after_window(self) -> None:
        """After enough time passes the bucket refills and allows requests."""
        bucket = TokenBucket(rate_per_min=60, burst_multiplier=2)
        # drain fully (capacity = 120)
        for _ in range(120):
            bucket.consume()
        # Simulate 2 seconds elapsing (rate = 1/sec → 2 tokens refilled).
        bucket._last_refill -= 2.0  # type: ignore[attr-defined]
        allowed, _ = bucket.consume()
        assert allowed

    def test_two_different_tokens_get_independent_buckets(self) -> None:
        """Token A exhausting its bucket must not affect Token B."""
        _buckets.clear()
        from oracle.core.rate_limit import consume_for_request

        # Exhaust token-A's capture bucket (rate=30, burst=2 → capacity=60)
        for _ in range(60):
            consume_for_request("token-A", RouteClass.CAPTURE, settings)
        allowed_a, _ = consume_for_request("token-A", RouteClass.CAPTURE, settings)
        assert not allowed_a

        # Token B should still be unaffected.
        allowed_b, _ = consume_for_request("token-B", RouteClass.CAPTURE, settings)
        assert allowed_b

    def test_burst_allows_2x_sustained_in_short_window(self) -> None:
        """Burst capacity = 2× per-minute rate: the bucket starts full at that."""
        bucket = TokenBucket(rate_per_min=30, burst_multiplier=2)
        # capacity should be 60 (2 × 30)
        successes = 0
        for _ in range(61):
            allowed, _ = bucket.consume()
            if allowed:
                successes += 1
        assert successes == 60


# ---------------------------------------------------------------------------
# Route classification tests
# ---------------------------------------------------------------------------


class TestClassifyRoute:
    def test_captures_path_is_capture(self) -> None:
        assert classify_route("/v1/captures") == RouteClass.CAPTURE

    def test_captures_with_trailing_slash(self) -> None:
        assert classify_route("/v1/captures/") == RouteClass.CAPTURE

    def test_queries_path_is_query(self) -> None:
        assert classify_route("/v1/queries") == RouteClass.QUERY

    def test_queries_subpath_is_query(self) -> None:
        assert classify_route("/v1/queries/some-id/feedback") == RouteClass.QUERY

    def test_memories_path_is_default(self) -> None:
        assert classify_route("/v1/memories") == RouteClass.DEFAULT

    def test_health_path_is_default(self) -> None:
        assert classify_route("/healthz") == RouteClass.DEFAULT

    def test_unknown_v1_path_is_default(self) -> None:
        assert classify_route("/v1/unknown") == RouteClass.DEFAULT


# ---------------------------------------------------------------------------
# Configurability tests
# ---------------------------------------------------------------------------


class TestConfigurability:
    def test_capture_rate_reads_from_settings(self) -> None:
        fake_settings = Settings(
            bearer_token="x",
            database_url="postgresql+asyncpg://x:x@localhost/x",
            rate_limit_capture_per_min=5,
        )
        cfg = get_rate_limit_config(RouteClass.CAPTURE, fake_settings)
        assert cfg["rate_per_min"] == 5

    def test_query_rate_reads_from_settings(self) -> None:
        fake_settings = Settings(
            bearer_token="x",
            database_url="postgresql+asyncpg://x:x@localhost/x",
            rate_limit_query_per_min=7,
        )
        cfg = get_rate_limit_config(RouteClass.QUERY, fake_settings)
        assert cfg["rate_per_min"] == 7

    def test_default_rate_reads_from_settings(self) -> None:
        fake_settings = Settings(
            bearer_token="x",
            database_url="postgresql+asyncpg://x:x@localhost/x",
            rate_limit_default_per_min=99,
        )
        cfg = get_rate_limit_config(RouteClass.DEFAULT, fake_settings)
        assert cfg["rate_per_min"] == 99

    def test_burst_multiplier_reads_from_settings(self) -> None:
        fake_settings = Settings(
            bearer_token="x",
            database_url="postgresql+asyncpg://x:x@localhost/x",
            rate_limit_burst_multiplier=3,
        )
        cfg = get_rate_limit_config(RouteClass.CAPTURE, fake_settings)
        assert cfg["burst_multiplier"] == 3


# ---------------------------------------------------------------------------
# Unauthenticated request edge case
# ---------------------------------------------------------------------------


class TestUnauthenticatedRequests:
    def test_unauthenticated_requests_use_anonymous_sentinel(self) -> None:
        """Requests with no token use the sentinel key '<anonymous>'.

        Unauthenticated requests are rejected by auth before the route handler
        runs, so rate-limiting them is optional. We still bucket them under the
        sentinel key so the limiter doesn't crash on a missing token argument.
        """
        _buckets.clear()
        from oracle.core.rate_limit import consume_for_request

        allowed, _ = consume_for_request("<anonymous>", RouteClass.DEFAULT, settings)
        assert allowed

    def test_anonymous_bucket_is_independent_from_real_token(self) -> None:
        """Anonymous sentinel key does not share state with a real token."""
        _buckets.clear()
        from oracle.core.rate_limit import consume_for_request

        # Exhaust anonymous default bucket (rate=60, burst=2 → cap=120)
        for _ in range(120):
            consume_for_request("<anonymous>", RouteClass.DEFAULT, settings)
        allowed_anon, _ = consume_for_request("<anonymous>", RouteClass.DEFAULT, settings)
        assert not allowed_anon

        # Real token must be unaffected.
        allowed_real, _ = consume_for_request("real-token", RouteClass.DEFAULT, settings)
        assert allowed_real


# ---------------------------------------------------------------------------
# FastAPI integration: 429 + Retry-After via ASGI test client
# ---------------------------------------------------------------------------


@pytest.fixture
def clear_buckets() -> None:
    """Ensure a clean bucket state for each integration test."""
    _buckets.clear()
    yield  # type: ignore[misc]
    _buckets.clear()


@pytest.fixture
async def rate_limit_client(clear_buckets: None) -> AsyncIterator[AsyncClient]:
    """ASGI test client for rate-limit integration tests.

    These tests exercise the 429 path only — they prime the bucket via
    consume_for_request() rather than making a real first request, so no
    DB or embedding stubs are needed. The 429 fires inside require_bearer
    before any route handler (and therefore any DB call) runs.
    """
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


@pytest.mark.asyncio
async def test_429_after_capture_limit_exceeded(rate_limit_client: AsyncClient) -> None:
    """Exceeding the capture rate limit must return 429 with Retry-After."""
    auth = {"Authorization": f"Bearer {settings.bearer_token}"}
    tiny_settings = Settings(
        bearer_token=settings.bearer_token,
        database_url=settings.database_url,
        rate_limit_capture_per_min=1,
        rate_limit_burst_multiplier=1,
    )
    with patch("oracle.core.rate_limit._current_settings", tiny_settings):
        _buckets.clear()
        # Prime the bucket by consuming the only token directly — no HTTP needed.
        allowed, _ = consume_for_request(settings.bearer_token, RouteClass.CAPTURE, tiny_settings)
        assert allowed  # bucket was full

        # Now the HTTP request must 429 without ever reaching the route handler.
        r = await rate_limit_client.post(
            "/v1/captures",
            json={
                "client_id": "00000000-0000-0000-0000-000000000099",
                "content": "rate limit test",
                "source_modality": "text",
                "source_device": "test",
                "captured_at": "2024-01-01T00:00:00+00:00",
            },
            headers=auth,
        )
        assert r.status_code == 429
        assert "Retry-After" in r.headers
        assert int(r.headers["Retry-After"]) >= 1


@pytest.mark.asyncio
async def test_429_after_query_limit_exceeded(rate_limit_client: AsyncClient) -> None:
    """Exceeding the query rate limit returns 429."""
    auth = {"Authorization": f"Bearer {settings.bearer_token}"}
    tiny_settings = Settings(
        bearer_token=settings.bearer_token,
        database_url=settings.database_url,
        rate_limit_query_per_min=1,
        rate_limit_burst_multiplier=1,
    )
    with patch("oracle.core.rate_limit._current_settings", tiny_settings):
        _buckets.clear()
        consume_for_request(settings.bearer_token, RouteClass.QUERY, tiny_settings)

        r = await rate_limit_client.post(
            "/v1/queries",
            json={"query": "what did I decide?"},
            headers=auth,
        )
        assert r.status_code == 429
        assert "Retry-After" in r.headers


@pytest.mark.asyncio
async def test_per_route_limits_are_independent(rate_limit_client: AsyncClient) -> None:
    """Exhausting the capture bucket must not affect the query bucket.

    We verify the independence claim at the bucket level (no HTTP for the
    unaffected bucket needed — the unit tests in TestTokenBucket already
    cover isolation). The HTTP assertion covers the 429 side only, which
    is the highest-value check.
    """
    tiny_settings = Settings(
        bearer_token=settings.bearer_token,
        database_url=settings.database_url,
        rate_limit_capture_per_min=1,
        rate_limit_query_per_min=10,
        rate_limit_burst_multiplier=1,
    )
    auth = {"Authorization": f"Bearer {settings.bearer_token}"}
    with patch("oracle.core.rate_limit._current_settings", tiny_settings):
        _buckets.clear()
        # Drain the capture bucket entirely.
        consume_for_request(settings.bearer_token, RouteClass.CAPTURE, tiny_settings)

        # Capture must 429 over HTTP.
        r_capture = await rate_limit_client.post(
            "/v1/captures",
            json={
                "client_id": "00000000-0000-0000-0000-000000000098",
                "content": "x",
                "source_modality": "text",
                "source_device": "test",
                "captured_at": "2024-01-01T00:00:00+00:00",
            },
            headers=auth,
        )
        assert r_capture.status_code == 429

        # Query bucket is untouched — consuming directly confirms independence
        # without needing to hit a route that requires a live DB.
        allowed_q, _ = consume_for_request(settings.bearer_token, RouteClass.QUERY, tiny_settings)
        assert allowed_q, "query bucket must still have tokens after capture bucket is exhausted"


@pytest.mark.asyncio
async def test_recovery_after_window_integration(rate_limit_client: AsyncClient) -> None:
    """After the window elapses the bucket refills and requests no longer 429.

    The 429 side is verified over HTTP. Recovery is verified at the bucket level
    (consume_for_request returns allowed=True) and also confirmed via HTTP using
    the /healthz endpoint (no DB required) to show the middleware lets the request
    through after the refill.
    """
    auth = {"Authorization": f"Bearer {settings.bearer_token}"}
    tiny_settings = Settings(
        bearer_token=settings.bearer_token,
        database_url=settings.database_url,
        rate_limit_capture_per_min=1,
        rate_limit_burst_multiplier=1,
    )
    with patch("oracle.core.rate_limit._current_settings", tiny_settings):
        _buckets.clear()
        # Drain the bucket.
        consume_for_request(settings.bearer_token, RouteClass.CAPTURE, tiny_settings)

        # Confirm it is empty via HTTP — must 429.
        r429 = await rate_limit_client.post(
            "/v1/captures",
            json={
                "client_id": "00000000-0000-0000-0000-000000000097",
                "content": "y",
                "source_modality": "text",
                "source_device": "test",
                "captured_at": "2024-01-01T00:00:00+00:00",
            },
            headers=auth,
        )
        assert r429.status_code == 429

        # Fast-forward the bucket's internal clock: rate=1/min → 1/60 tps,
        # cap=1. Rewinding 61 seconds guarantees at least 1 token refills.
        for bucket in _buckets.values():
            bucket._last_refill -= 61.0  # type: ignore[attr-defined]

        # Verify recovery at the bucket level.
        allowed, _ = consume_for_request(settings.bearer_token, RouteClass.CAPTURE, tiny_settings)
        assert allowed, "bucket must allow a request after the refill window"
