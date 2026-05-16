"""Tests for the OpenRouter monthly spend cap (ticket #190).

TDD red commit: all tests here are expected to fail until the spend-cap
module is implemented and wired into the query and enrichment paths.

Coverage:
1. Spend computation — sums correctly from BOTH sources:
   a. query_logs (synthesis_cost + intent_router_cost)
   b. enrichment_state.notes.total_cost_usd
2. 80% warning fires on every subsequent call after threshold (not once total).
3. 100% raises SpendCapExceededError.
4. GET /v1/admin/usage returns correct per-source aggregates against a seeded DB.
5. Endpoint returns sensible zero aggregates when no data exists.
6. Graceful degradation: retrieval skips synthesis when cap is exceeded.
7. Graceful degradation: enrichment check_spend_cap raises SpendCapExceededError
   which the caller (orchestrator) can catch to no-op for the rest of the month.
8. spend_pct computed at 80% boundary: warn fires, not raises.
9. spend_pct at exactly 100%: raises, not just warns.
10. Spend computed across current calendar month only (prior-month rows excluded).
11. month_cap_usd and cap_pct_used are returned correctly in /v1/admin/usage.

Requires a real Postgres+pgvector instance (DATABASE_URL from conftest / env).
HTTP boundary (OpenRouter) is mocked throughout.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any
from unittest.mock import patch

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import Settings, settings
from grove.models.enrichment_state import EnrichmentState
from grove.models.query_log import QueryLog

_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_Session = async_sessionmaker(_engine, expire_on_commit=False)


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _Session() as session:
        yield session


@pytest.fixture(autouse=True)
async def clean_tables(db_session: AsyncSession) -> AsyncIterator[None]:
    """Remove test rows before and after each test."""
    yield
    # Teardown — delete rows inserted by this test.
    rows = await db_session.execute(select(QueryLog))
    for row in rows.scalars().all():
        await db_session.delete(row)
    rows2 = await db_session.execute(select(EnrichmentState))
    for row in rows2.scalars().all():
        await db_session.delete(row)
    await db_session.commit()


def _make_query_log(
    *,
    synthesis_cost: float | None = None,
    intent_router_cost: float | None = None,
    synthesis_input_tokens: int | None = None,
    synthesis_output_tokens: int | None = None,
    intent_router_input_tokens: int | None = None,
    intent_router_output_tokens: int | None = None,
    created_at: datetime | None = None,
) -> QueryLog:
    return QueryLog(
        id=uuid.uuid4(),
        query_text="test query",
        tables_searched={"vector": True},
        result_count=0,
        synthesis_cost=Decimal(str(synthesis_cost)) if synthesis_cost is not None else None,
        intent_router_cost=(
            Decimal(str(intent_router_cost)) if intent_router_cost is not None else None
        ),
        synthesis_input_tokens=synthesis_input_tokens,
        synthesis_output_tokens=synthesis_output_tokens,
        intent_router_input_tokens=intent_router_input_tokens,
        intent_router_output_tokens=intent_router_output_tokens,
        created_at=created_at or datetime.now(UTC),
    )


def _make_enrichment_state(
    *,
    notes: dict[str, Any] | None = None,
    run_started_at: datetime | None = None,
) -> EnrichmentState:
    return EnrichmentState(
        id=uuid.uuid4(),
        run_started_at=run_started_at or datetime.now(UTC),
        pipeline_version=1,
        memories_processed=0,
        classifications_created=0,
        errors=0,
        notes=notes,
    )


# ---------------------------------------------------------------------------
# 1. Spend computation from query_logs
# ---------------------------------------------------------------------------


async def test_spend_from_query_logs_synthesis_and_intent(db_session: AsyncSession) -> None:
    """Spend sums synthesis_cost + intent_router_cost from query_logs for current month."""
    from grove.admin.spend import get_current_month_spend

    row = _make_query_log(synthesis_cost=0.005, intent_router_cost=0.002)
    db_session.add(row)
    await db_session.commit()

    spend = await get_current_month_spend(_Session)
    assert abs(spend.query_logs_cost_usd - 0.007) < 1e-9


async def test_spend_from_enrichment_state_notes(db_session: AsyncSession) -> None:
    """Spend sums total_cost_usd from enrichment_state.notes for current month."""
    from grove.admin.spend import get_current_month_spend

    row = _make_enrichment_state(notes={"total_cost_usd": 0.003})
    db_session.add(row)
    await db_session.commit()

    spend = await get_current_month_spend(_Session)
    assert abs(spend.enrichment_cost_usd - 0.003) < 1e-9


async def test_spend_aggregates_both_sources(db_session: AsyncSession) -> None:
    """Total spend is the sum of query_logs costs + enrichment costs."""
    from grove.admin.spend import get_current_month_spend

    ql1 = _make_query_log(synthesis_cost=0.010, intent_router_cost=0.001)
    ql2 = _make_query_log(synthesis_cost=0.005, intent_router_cost=None)
    es1 = _make_enrichment_state(notes={"total_cost_usd": 0.004})
    db_session.add_all([ql1, ql2, es1])
    await db_session.commit()

    spend = await get_current_month_spend(_Session)
    # query_logs: 0.010 + 0.001 + 0.005 = 0.016
    assert abs(spend.query_logs_cost_usd - 0.016) < 1e-9
    # enrichment: 0.004
    assert abs(spend.enrichment_cost_usd - 0.004) < 1e-9
    # total: 0.020
    assert abs(spend.total_cost_usd - 0.020) < 1e-9


async def test_spend_excludes_prior_month_rows(db_session: AsyncSession) -> None:
    """Rows from a prior calendar month are NOT included in the current-month spend."""
    from grove.admin.spend import get_current_month_spend

    now = datetime.now(UTC)
    # Row from previous month
    last_month = (now.replace(day=1) - timedelta(days=1)).replace(
        hour=12, minute=0, second=0, microsecond=0
    )
    old_ql = _make_query_log(synthesis_cost=1.00, created_at=last_month)
    current_ql = _make_query_log(synthesis_cost=0.01)
    db_session.add_all([old_ql, current_ql])
    await db_session.commit()

    spend = await get_current_month_spend(_Session)
    # Only current_ql should be summed
    assert abs(spend.query_logs_cost_usd - 0.01) < 1e-9


async def test_spend_null_costs_treated_as_zero(db_session: AsyncSession) -> None:
    """NULL cost columns are treated as 0 (not excluded from the sum)."""
    from grove.admin.spend import get_current_month_spend

    row = _make_query_log(synthesis_cost=None, intent_router_cost=None)
    db_session.add(row)
    await db_session.commit()

    spend = await get_current_month_spend(_Session)
    assert spend.query_logs_cost_usd == 0.0
    assert spend.total_cost_usd == 0.0


# ---------------------------------------------------------------------------
# 2. 80% threshold: warn on every subsequent call after threshold
# ---------------------------------------------------------------------------


async def test_warn_fires_at_80_pct(db_session: AsyncSession) -> None:
    """When spend reaches 80% of cap, check_spend_cap logs a warning (does not raise)."""
    from grove.admin.spend import check_spend_cap

    cap = 10.0
    # 8.0 / 10.0 = 80% exactly — should warn, not raise
    ql = _make_query_log(synthesis_cost=8.0)
    db_session.add(ql)
    await db_session.commit()

    fake_settings = Settings(
        bearer_token="x",
        database_url=settings.database_url,
        openrouter_monthly_cap_usd=cap,
    )

    from structlog.testing import capture_logs

    with capture_logs() as cap_logs:
        await check_spend_cap(_Session, fake_settings)  # must not raise

    warn_events = [e for e in cap_logs if e.get("log_level") == "warning"]
    assert any("spend_cap" in e.get("event", "") for e in warn_events), (
        f"Expected spend_cap warning event, got: {cap_logs}"
    )


async def test_warn_fires_on_every_call_after_80_pct(db_session: AsyncSession) -> None:
    """80% warn fires on EVERY subsequent call, not just the first time."""
    from grove.admin.spend import check_spend_cap

    cap = 10.0
    ql = _make_query_log(synthesis_cost=8.5)  # 85% of cap
    db_session.add(ql)
    await db_session.commit()

    fake_settings = Settings(
        bearer_token="x",
        database_url=settings.database_url,
        openrouter_monthly_cap_usd=cap,
    )

    from structlog.testing import capture_logs

    # Call three times — each should produce a warning
    for call_num in range(3):
        with capture_logs() as cap_logs:
            await check_spend_cap(_Session, fake_settings)  # must not raise
        warn_events = [e for e in cap_logs if e.get("log_level") == "warning"]
        assert any("spend_cap" in e.get("event", "") for e in warn_events), (
            f"Call {call_num + 1}: expected warning, got: {cap_logs}"
        )


# ---------------------------------------------------------------------------
# 3. 100% threshold: raises SpendCapExceededError
# ---------------------------------------------------------------------------


async def test_raises_at_100_pct(db_session: AsyncSession) -> None:
    """When spend reaches 100% of cap, check_spend_cap raises SpendCapExceededError."""
    from grove.admin.spend import SpendCapExceededError, check_spend_cap

    cap = 5.0
    ql = _make_query_log(synthesis_cost=5.0)  # exactly 100%
    db_session.add(ql)
    await db_session.commit()

    fake_settings = Settings(
        bearer_token="x",
        database_url=settings.database_url,
        openrouter_monthly_cap_usd=cap,
    )

    with pytest.raises(SpendCapExceededError) as exc_info:
        await check_spend_cap(_Session, fake_settings)

    assert exc_info.value.spend_usd >= cap
    assert exc_info.value.cap_usd == cap


async def test_raises_above_100_pct(db_session: AsyncSession) -> None:
    """Spend exceeding cap also raises SpendCapExceededError."""
    from grove.admin.spend import SpendCapExceededError, check_spend_cap

    cap = 5.0
    ql = _make_query_log(synthesis_cost=6.0)  # 120%
    db_session.add(ql)
    await db_session.commit()

    fake_settings = Settings(
        bearer_token="x",
        database_url=settings.database_url,
        openrouter_monthly_cap_usd=cap,
    )

    with pytest.raises(SpendCapExceededError):
        await check_spend_cap(_Session, fake_settings)


async def test_no_raise_below_80_pct(db_session: AsyncSession) -> None:
    """Below 80% cap: check_spend_cap neither raises nor warns."""
    from grove.admin.spend import check_spend_cap

    cap = 20.0
    ql = _make_query_log(synthesis_cost=1.0)  # 5%
    db_session.add(ql)
    await db_session.commit()

    fake_settings = Settings(
        bearer_token="x",
        database_url=settings.database_url,
        openrouter_monthly_cap_usd=cap,
    )

    from structlog.testing import capture_logs

    with capture_logs() as cap_logs:
        await check_spend_cap(_Session, fake_settings)

    warn_events = [e for e in cap_logs if e.get("log_level") == "warning"]
    spend_cap_warns = [e for e in warn_events if "spend_cap" in e.get("event", "")]
    assert spend_cap_warns == [], f"Expected no spend_cap warnings, got: {spend_cap_warns}"


# ---------------------------------------------------------------------------
# 4. GET /v1/admin/usage endpoint — correct aggregates
# ---------------------------------------------------------------------------


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _Session() as session:
        yield session


def _override_get_log_session_factory() -> async_sessionmaker[AsyncSession]:
    return _Session


@pytest.fixture
async def admin_client() -> AsyncIterator[AsyncClient]:
    """ASGI test client with DB overrides so all DB calls go through _Session."""
    from grove.api.admin import get_log_session_factory as admin_log_factory
    from grove.api.queries import get_log_session_factory as query_log_factory
    from grove.core.db import get_session
    from grove.main import app

    app.dependency_overrides[get_session] = _override_get_session
    app.dependency_overrides[admin_log_factory] = _override_get_log_session_factory
    app.dependency_overrides[query_log_factory] = _override_get_log_session_factory

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac

    app.dependency_overrides.pop(get_session, None)
    app.dependency_overrides.pop(admin_log_factory, None)
    app.dependency_overrides.pop(query_log_factory, None)


async def test_admin_usage_aggregates(db_session: AsyncSession, admin_client: AsyncClient) -> None:
    """GET /v1/admin/usage returns correct per-source aggregates from seeded DB."""
    # Seed: 2 query logs with synthesis + intent_router, 1 enrichment state
    ql1 = _make_query_log(
        synthesis_cost=0.010,
        synthesis_input_tokens=100,
        synthesis_output_tokens=50,
        intent_router_cost=0.001,
        intent_router_input_tokens=20,
        intent_router_output_tokens=10,
    )
    ql2 = _make_query_log(
        synthesis_cost=0.005,
        synthesis_input_tokens=80,
        synthesis_output_tokens=30,
        intent_router_cost=None,
        intent_router_input_tokens=None,
        intent_router_output_tokens=None,
    )
    es1 = _make_enrichment_state(
        notes={"total_cost_usd": 0.004, "total_input_tokens": 200, "total_output_tokens": 100}
    )
    db_session.add_all([ql1, ql2, es1])
    await db_session.commit()

    auth = {"Authorization": f"Bearer {settings.bearer_token}"}
    r = await admin_client.get("/v1/admin/usage", headers=auth)
    assert r.status_code == 200

    data = r.json()

    # synthesis totals: cost 0.015, tokens_in 180, tokens_out 80
    assert abs(data["synthesis"]["cost_usd"] - 0.015) < 1e-6
    assert data["synthesis"]["tokens_in"] == 180
    assert data["synthesis"]["tokens_out"] == 80

    # intent_router totals: cost 0.001, tokens 20 in, 10 out
    assert abs(data["intent_router"]["cost_usd"] - 0.001) < 1e-6
    assert data["intent_router"]["tokens_in"] == 20
    assert data["intent_router"]["tokens_out"] == 10

    # enrichment totals: cost 0.004, tokens from notes
    assert abs(data["enrichment"]["cost_usd"] - 0.004) < 1e-6
    assert data["enrichment"]["tokens_in"] == 200
    assert data["enrichment"]["tokens_out"] == 100

    # cap fields
    assert data["month_cap_usd"] == settings.openrouter_monthly_cap_usd
    # total spend: 0.015 + 0.001 + 0.004 = 0.020
    expected_pct = 0.020 / settings.openrouter_monthly_cap_usd
    assert abs(data["cap_pct_used"] - expected_pct) < 1e-6


async def test_admin_usage_empty_db(admin_client: AsyncClient) -> None:
    """GET /v1/admin/usage returns zero aggregates when no data exists."""
    auth = {"Authorization": f"Bearer {settings.bearer_token}"}
    r = await admin_client.get("/v1/admin/usage", headers=auth)
    assert r.status_code == 200

    data = r.json()
    assert data["synthesis"]["cost_usd"] == 0.0
    assert data["synthesis"]["tokens_in"] == 0
    assert data["synthesis"]["tokens_out"] == 0
    assert data["intent_router"]["cost_usd"] == 0.0
    assert data["enrichment"]["cost_usd"] == 0.0
    assert data["cap_pct_used"] == 0.0


async def test_admin_usage_requires_auth(admin_client: AsyncClient) -> None:
    """GET /v1/admin/usage returns 401 without a valid bearer token."""
    r = await admin_client.get("/v1/admin/usage")
    assert r.status_code == 401


# ---------------------------------------------------------------------------
# 6. Graceful degradation: retrieval skips synthesis when cap exceeded
# ---------------------------------------------------------------------------


async def test_retrieval_degrades_gracefully_when_cap_exceeded() -> None:
    """When SpendCapExceededError is raised, post_query skips synthesis and
    returns answer=None with sources still populated.

    check_spend_cap is patched at the grove.api.queries module level so that
    the mock takes effect regardless of how the import is resolved.
    DB calls are routed through _Session via dependency_overrides.
    Embedding is skipped by patching get_embedding_provider.
    """
    from unittest.mock import AsyncMock, MagicMock

    from grove.admin.spend import SpendCapExceededError
    from grove.api.queries import get_log_session_factory
    from grove.core.db import get_session
    from grove.embeddings import EMBEDDING_DIM
    from grove.main import app

    raise_exc = SpendCapExceededError(spend_usd=25.0, cap_usd=20.0)

    # Fake embedding provider so the query path doesn't hit OpenAI.
    fake_vec = [1.0] + [0.0] * (EMBEDDING_DIM - 1)
    mock_provider = MagicMock()
    mock_provider.embed_batch = AsyncMock(return_value=[fake_vec])

    app.dependency_overrides[get_session] = _override_get_session
    app.dependency_overrides[get_log_session_factory] = _override_get_log_session_factory

    try:
        with (
            patch("grove.api.queries.check_spend_cap", side_effect=raise_exc),
            patch("grove.api.queries.get_embedding_provider", return_value=mock_provider),
        ):
            async with AsyncClient(
                transport=ASGITransport(app=app), base_url="http://test"
            ) as client:
                auth = {"Authorization": f"Bearer {settings.bearer_token}"}
                r = await client.post(
                    "/v1/queries",
                    json={"query": "what did I decide about the API design?"},
                    headers=auth,
                )
    finally:
        app.dependency_overrides.pop(get_session, None)
        app.dependency_overrides.pop(get_log_session_factory, None)

    # Route must succeed (200), not 500
    assert r.status_code == 200
    data = r.json()
    # Synthesis is skipped — answer must be null
    assert data["answer"] is None


# ---------------------------------------------------------------------------
# 7. Graceful degradation: enrichment no-ops when cap exceeded
# ---------------------------------------------------------------------------


async def test_enrichment_check_raises_spend_cap_exceeded_error(
    db_session: AsyncSession,
) -> None:
    """check_spend_cap raises SpendCapExceededError when cap is reached.

    The enrichment orchestrator is responsible for catching this and no-opping
    for the rest of the month. This test verifies the error is structured
    correctly so the caller can catch it specifically.
    """
    from grove.admin.spend import SpendCapExceededError, check_spend_cap

    cap = 1.0
    ql = _make_query_log(synthesis_cost=2.0)  # 200% — clearly over
    db_session.add(ql)
    await db_session.commit()

    fake_settings = Settings(
        bearer_token="x",
        database_url=settings.database_url,
        openrouter_monthly_cap_usd=cap,
    )

    with pytest.raises(SpendCapExceededError) as exc_info:
        await check_spend_cap(_Session, fake_settings)

    # Verify it's catchable by the specific exception class (not just Exception)
    assert isinstance(exc_info.value, SpendCapExceededError)
    assert exc_info.value.cap_usd == cap


# ---------------------------------------------------------------------------
# 7b. classify_and_write no-ops when spend cap is exceeded
# ---------------------------------------------------------------------------


async def test_classify_and_write_no_ops_when_spend_cap_exceeded(
    db_session: AsyncSession,
) -> None:
    """classify_and_write skips the LLM call and sets enrichment_error when
    the spend cap is exceeded.

    Patches grove.enrichment.orchestrator.check_spend_cap to raise
    SpendCapExceededError, then verifies:
      - classify_memory was NOT called (LLM skipped entirely)
      - memory.enrichment_error is set to "spend_cap_exceeded"
      - memory.enriched remains False
    """
    import uuid
    from datetime import UTC, datetime
    from unittest.mock import AsyncMock, patch

    from grove.admin.spend import SpendCapExceededError
    from grove.enrichment.orchestrator import classify_and_write
    from grove.models import Memory

    memory = Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="Budget review discussion.",
        token_count=10,
        enriched=False,
        created_at=datetime.now(tz=UTC),
    )
    db_session.add(memory)
    await db_session.commit()

    mock_classify = AsyncMock()
    exc = SpendCapExceededError(spend_usd=15.0, cap_usd=10.0)

    try:
        with (
            patch(
                "grove.enrichment.orchestrator.check_spend_cap",
                new_callable=AsyncMock,
                side_effect=exc,
            ),
            patch(
                "grove.enrichment.orchestrator.classify_memory",
                mock_classify,
            ),
        ):
            async with _Session() as session:
                mem = await session.get(Memory, memory.id)
                assert mem is not None
                await classify_and_write(mem, session)

        await db_session.refresh(memory)
        assert memory.enriched is False, "Memory must remain unenriched when cap is exceeded"
        assert memory.enrichment_error == "spend_cap_exceeded", (
            f"Expected enrichment_error='spend_cap_exceeded', got {memory.enrichment_error!r}"
        )
        assert mock_classify.call_count == 0, (
            f"classify_memory must not be called when cap is exceeded, "
            f"got call_count={mock_classify.call_count}"
        )
    finally:
        obj = await db_session.get(Memory, memory.id)
        if obj:
            await db_session.delete(obj)
        await db_session.commit()
