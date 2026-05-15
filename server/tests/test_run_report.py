"""Integration tests for RunReport (ticket #182) — enrichment observability.

TDD red commit: all tests here are expected to fail until RunReport is
implemented and wired into run.py.

Coverage:
1. Happy path — N memories, all accepted: correct per-type counts, exact
   average confidence, nonzero token + cost totals, zero errors.
2. Error path — one ClassificationError: error count and sampled message
   recorded; successful-type counts are still correct for other memories.
3. Confidence dropouts — memories below 0.7 gate: NOT counted in per-type
   totals (only accepted writes count).
4. Empty run — zero memories → all-zero report, valid JSON, persists.
5. Cost arithmetic — total cost equals sum of per-call costs (not
   double-counted, not missed).
6. JSONB persistence — report round-trips through Postgres via notes field.

Requires a real Postgres+pgvector instance (DATABASE_URL from conftest / env).
HTTP boundary (OpenRouter) is mocked throughout — stubbed classify_and_write
callables push RunReport accumulators directly.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.enrichment.classifier import ClassificationError
from oracle.enrichment.report import RunReport
from oracle.models import EnrichmentState, Memory

_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_Session = async_sessionmaker(_engine, expire_on_commit=False)

_RUN_TIMEOUT = 15.0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_memory() -> Memory:
    return Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="Test memory for observability.",
        token_count=10,
        enriched=False,
        created_at=datetime.now(tz=UTC),
    )


async def _seed_memories(session: AsyncSession, n: int) -> list[Memory]:
    memories = [_make_memory() for _ in range(n)]
    session.add_all(memories)
    await session.commit()
    return memories


async def _cleanup(session: AsyncSession, memories: list[Memory]) -> None:
    for m in memories:
        obj = await session.get(Memory, m.id)
        if obj:
            await session.delete(obj)
    await session.flush()
    rows = await session.execute(select(EnrichmentState))
    for row in rows.scalars().all():
        await session.delete(row)
    await session.commit()


@pytest.fixture(autouse=True)
async def clean_tables() -> AsyncIterator[None]:
    async with _Session() as session:
        result = await session.execute(select(Memory).where(Memory.enriched.is_(False)))
        for mem in result.scalars().all():
            await session.delete(mem)
        result2 = await session.execute(select(EnrichmentState))
        for row in result2.scalars().all():
            await session.delete(row)
        await session.commit()
    yield


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _Session() as session:
        yield session


# ---------------------------------------------------------------------------
# Helper: run() with injected classify_and_write and return enrichment_state
# ---------------------------------------------------------------------------


async def _run_and_get_state(classify_and_write) -> EnrichmentState:  # type: ignore[no-untyped-def]
    import asyncio

    from oracle.enrichment.run import run

    await asyncio.wait_for(
        run(batch_size=50, classify_and_write=classify_and_write), timeout=_RUN_TIMEOUT
    )

    async with _Session() as s:
        result = await s.execute(select(EnrichmentState))
        rows = result.scalars().all()
        assert len(rows) == 1, f"Expected 1 enrichment_state row, got {len(rows)}"
        return rows[0]


# ---------------------------------------------------------------------------
# Test 1: Happy path
# ---------------------------------------------------------------------------


async def test_run_report_happy_path(db_session: AsyncSession) -> None:
    """A run with N memories yields correct per-type counts, average confidence,
    nonzero token + cost totals, and zero errors.
    """
    memories = await _seed_memories(db_session, 3)

    # Each call returns: 1 decision (conf 0.8) + 1 task (conf 0.9)
    # Total accepted: 3 decisions + 3 tasks = 6 writes
    # Average confidence = (0.8 + 0.9 + 0.8 + 0.9 + 0.8 + 0.9) / 6 = 5.1/6 = 0.85
    # Per call: 10 input tokens, 5 output tokens, cost 0.001 USD
    # Totals: 30 input, 15 output, 0.003 USD

    async def stub(memory: Memory, session: AsyncSession, *, report: RunReport) -> None:
        from datetime import UTC
        from datetime import datetime as _dt

        from oracle.enrichment.run import PIPELINE_VERSION

        report.record_accepted("decisions", confidence=0.8)
        report.record_accepted("tasks", confidence=0.9)
        report.record_llm_usage(input_tokens=10, output_tokens=5, cost_usd=0.001)
        memory.enriched = True
        memory.enriched_at = _dt.now(tz=UTC)
        memory.enriched_version = PIPELINE_VERSION
        memory.enrichment_error = None
        await session.commit()

    try:
        state = await _run_and_get_state(stub)

        assert state.notes is not None
        report_data = json.loads(state.notes) if isinstance(state.notes, str) else state.notes

        assert report_data["counts_by_type"]["decisions"] == 3
        assert report_data["counts_by_type"]["tasks"] == 3
        assert report_data["counts_by_type"]["people_interactions"] == 0
        assert report_data["counts_by_type"]["appointments"] == 0
        assert report_data["error_count"] == 0
        assert report_data["error_samples"] == []
        assert report_data["total_input_tokens"] == 30
        assert report_data["total_output_tokens"] == 15
        assert abs(report_data["total_cost_usd"] - 0.003) < 1e-9
        # (0.8 + 0.9 + 0.8 + 0.9 + 0.8 + 0.9) / 6 = 0.85
        assert abs(report_data["average_confidence"] - 0.85) < 1e-9
        assert report_data["dropped_low_confidence"] == 0
    finally:
        await _cleanup(db_session, memories)


# ---------------------------------------------------------------------------
# Test 2: Error path — one ClassificationError
# ---------------------------------------------------------------------------


async def test_run_report_error_path(db_session: AsyncSession) -> None:
    """A run where one memory raises ClassificationError records error count
    and a sample message; successful-type counts still tally correctly.
    """
    memories = await _seed_memories(db_session, 3)
    call_count = 0

    async def stub(memory: Memory, session: AsyncSession, *, report: RunReport) -> None:
        nonlocal call_count
        call_count += 1
        from datetime import UTC
        from datetime import datetime as _dt

        from oracle.enrichment.run import PIPELINE_VERSION

        if call_count == 2:
            # Signal error in report then raise so run() records it
            report.record_error("boom: classification failed on memory 2")
            raise ClassificationError("boom: classification failed on memory 2")

        report.record_accepted("people_interactions", confidence=0.75)
        report.record_llm_usage(input_tokens=8, output_tokens=4, cost_usd=0.0005)
        memory.enriched = True
        memory.enriched_at = _dt.now(tz=UTC)
        memory.enriched_version = PIPELINE_VERSION
        memory.enrichment_error = None
        await session.commit()

    try:
        state = await _run_and_get_state(stub)

        assert state.notes is not None
        report_data = json.loads(state.notes) if isinstance(state.notes, str) else state.notes

        assert report_data["error_count"] == 1
        assert len(report_data["error_samples"]) == 1
        assert "boom: classification failed on memory 2" in report_data["error_samples"][0]
        # 2 successful memories, each with 1 people_interaction
        assert report_data["counts_by_type"]["people_interactions"] == 2
        assert report_data["counts_by_type"]["decisions"] == 0
        assert report_data["counts_by_type"]["tasks"] == 0
        assert report_data["counts_by_type"]["appointments"] == 0
    finally:
        await _cleanup(db_session, memories)


# ---------------------------------------------------------------------------
# Test 3: Confidence dropouts — below-threshold not counted
# ---------------------------------------------------------------------------


async def test_run_report_confidence_dropouts(db_session: AsyncSession) -> None:
    """Records with confidence < 0.7 are NOT counted in per-type totals."""
    memories = await _seed_memories(db_session, 2)

    async def stub(memory: Memory, session: AsyncSession, *, report: RunReport) -> None:
        from datetime import UTC
        from datetime import datetime as _dt

        from oracle.enrichment.run import PIPELINE_VERSION

        # One accepted, one dropped
        report.record_accepted("decisions", confidence=0.8)
        report.record_dropped()
        report.record_llm_usage(input_tokens=5, output_tokens=3, cost_usd=0.0002)
        memory.enriched = True
        memory.enriched_at = _dt.now(tz=UTC)
        memory.enriched_version = PIPELINE_VERSION
        memory.enrichment_error = None
        await session.commit()

    try:
        state = await _run_and_get_state(stub)

        assert state.notes is not None
        report_data = json.loads(state.notes) if isinstance(state.notes, str) else state.notes

        # 2 memories × 1 accepted decision each
        assert report_data["counts_by_type"]["decisions"] == 2
        # 2 memories × 1 dropped each
        assert report_data["dropped_low_confidence"] == 2
        # Only accepted confidences count toward average: 0.8 + 0.8 = 1.6 / 2 = 0.8
        assert abs(report_data["average_confidence"] - 0.8) < 1e-9
    finally:
        await _cleanup(db_session, memories)


# ---------------------------------------------------------------------------
# Test 4: Empty run — zero memories
# ---------------------------------------------------------------------------


async def test_run_report_empty_run(db_session: AsyncSession) -> None:
    """Zero memories → all-zero report, valid JSON, persists to DB."""
    # No memories seeded — stub should never be called
    stub_calls = []

    async def stub(memory: Memory, session: AsyncSession, *, report: RunReport) -> None:
        stub_calls.append(memory.id)
        await session.commit()

    state = await _run_and_get_state(stub)
    assert stub_calls == [], "Stub should not be called when no memories exist"

    assert state.notes is not None
    report_data = json.loads(state.notes) if isinstance(state.notes, str) else state.notes

    assert report_data["counts_by_type"]["decisions"] == 0
    assert report_data["counts_by_type"]["people_interactions"] == 0
    assert report_data["counts_by_type"]["tasks"] == 0
    assert report_data["counts_by_type"]["appointments"] == 0
    assert report_data["dropped_low_confidence"] == 0
    assert report_data["error_count"] == 0
    assert report_data["error_samples"] == []
    assert report_data["total_input_tokens"] == 0
    assert report_data["total_output_tokens"] == 0
    assert report_data["total_cost_usd"] == 0.0
    assert report_data["average_confidence"] == 0.0


# ---------------------------------------------------------------------------
# Test 5: Cost arithmetic — sum matches exactly
# ---------------------------------------------------------------------------


async def test_run_report_cost_arithmetic(db_session: AsyncSession) -> None:
    """Total cost equals exact sum of per-call costs — no double-counting."""
    memories = await _seed_memories(db_session, 4)
    per_call_costs = [0.001, 0.002, 0.0005, 0.0015]
    call_idx = 0

    async def stub(memory: Memory, session: AsyncSession, *, report: RunReport) -> None:
        nonlocal call_idx
        from datetime import UTC
        from datetime import datetime as _dt

        from oracle.enrichment.run import PIPELINE_VERSION

        cost = per_call_costs[call_idx]
        call_idx += 1
        report.record_llm_usage(input_tokens=10, output_tokens=5, cost_usd=cost)
        memory.enriched = True
        memory.enriched_at = _dt.now(tz=UTC)
        memory.enriched_version = PIPELINE_VERSION
        memory.enrichment_error = None
        await session.commit()

    try:
        state = await _run_and_get_state(stub)

        assert state.notes is not None
        report_data = json.loads(state.notes) if isinstance(state.notes, str) else state.notes

        expected_cost = sum(per_call_costs)  # 0.005
        assert abs(report_data["total_cost_usd"] - expected_cost) < 1e-9
        assert report_data["total_input_tokens"] == 40
        assert report_data["total_output_tokens"] == 20
    finally:
        await _cleanup(db_session, memories)


# ---------------------------------------------------------------------------
# Test 6: JSONB persistence — round-trips through Postgres
# ---------------------------------------------------------------------------


async def test_run_report_jsonb_persistence(db_session: AsyncSession) -> None:
    """RunReport round-trips through the notes column without data loss."""
    memories = await _seed_memories(db_session, 1)

    async def stub(memory: Memory, session: AsyncSession, *, report: RunReport) -> None:
        from datetime import UTC
        from datetime import datetime as _dt

        from oracle.enrichment.run import PIPELINE_VERSION

        report.record_accepted("appointments", confidence=0.95)
        report.record_dropped()
        report.record_llm_usage(input_tokens=20, output_tokens=10, cost_usd=0.003)
        memory.enriched = True
        memory.enriched_at = _dt.now(tz=UTC)
        memory.enriched_version = PIPELINE_VERSION
        memory.enrichment_error = None
        await session.commit()

    try:
        state = await _run_and_get_state(stub)

        # Re-fetch from DB to confirm round-trip (not in-memory cache)
        async with _Session() as fresh_session:
            fetched = await fresh_session.get(EnrichmentState, state.id)
            assert fetched is not None
            assert fetched.notes is not None

            # Parse back from JSONB/text
            report_data = (
                json.loads(fetched.notes) if isinstance(fetched.notes, str) else fetched.notes
            )

        assert report_data["counts_by_type"]["appointments"] == 1
        assert report_data["counts_by_type"]["decisions"] == 0
        assert report_data["dropped_low_confidence"] == 1
        assert abs(report_data["total_cost_usd"] - 0.003) < 1e-9
        assert abs(report_data["average_confidence"] - 0.95) < 1e-9
    finally:
        await _cleanup(db_session, memories)


# ---------------------------------------------------------------------------
# Test 7: Structured log line is emitted at run end
# ---------------------------------------------------------------------------


async def test_run_report_structured_log_emitted(db_session: AsyncSession) -> None:
    """run() emits a structured log line containing the RunReport payload."""
    memories = await _seed_memories(db_session, 1)

    async def stub(memory: Memory, session: AsyncSession, *, report: RunReport) -> None:
        from datetime import UTC
        from datetime import datetime as _dt

        from oracle.enrichment.run import PIPELINE_VERSION

        report.record_accepted("tasks", confidence=0.8)
        report.record_llm_usage(input_tokens=5, output_tokens=3, cost_usd=0.001)
        memory.enriched = True
        memory.enriched_at = _dt.now(tz=UTC)
        memory.enriched_version = PIPELINE_VERSION
        memory.enrichment_error = None
        await session.commit()

    from structlog.testing import capture_logs

    try:
        with capture_logs() as cap:
            import asyncio

            from oracle.enrichment.run import run

            await asyncio.wait_for(
                run(batch_size=50, classify_and_write=stub), timeout=_RUN_TIMEOUT
            )

        # Find the run_report log event
        report_events = [e for e in cap if e.get("event") == "enrichment_run.report"]
        assert len(report_events) == 1, f"Expected 1 run_report log event, got: {cap}"

        evt = report_events[0]
        assert evt["counts_by_type"]["tasks"] == 1
        assert evt["error_count"] == 0
        assert evt["total_input_tokens"] == 5
        assert evt["total_output_tokens"] == 3
    finally:
        await _cleanup(db_session, memories)
