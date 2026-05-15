"""OpenRouter monthly spend cap enforcement.

Public API:
    SpendCapExceededError — raised when 100% of the monthly cap is consumed.
    MonthlySpend — aggregated spend breakdown for the current calendar month.
    get_current_month_spend(session_factory) -> MonthlySpend
        Query the DB for current-month costs from both sources:
          - query_logs (synthesis_cost + intent_router_cost)
          - enrichment_state.notes.total_cost_usd
    check_spend_cap(session_factory, override_settings=None) -> None
        Evaluate current spend against the cap:
          - Below 80%: no-op.
          - 80%–100%: log a structured warning (fires on every call, not once).
          - >= 100%: raise SpendCapExceededError.

Callers
-------
oracle.api.queries.post_query — checks before calling synthesize() and
    classify_intent(). On SpendCapExceededError the endpoint returns answer=None
    (ranked-snippets-only degradation).

oracle.enrichment.orchestrator.classify_and_write — checks before calling the
    LLM. On SpendCapExceededError the orchestrator skips the memory, sets
    enrichment_error="spend_cap_exceeded", and the next monthly-reset will retry.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import TYPE_CHECKING

import structlog
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import async_sessionmaker

from oracle.models.query_log import QueryLog

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

    from oracle.core.config import Settings

logger = structlog.get_logger(__name__)

_WARN_THRESHOLD = 0.80


class SpendCapExceededError(Exception):
    """Raised when current-month OpenRouter spend reaches 100% of the cap.

    Attributes:
        spend_usd: The actual spend value that tripped the cap.
        cap_usd: The configured cap that was breached.
    """

    def __init__(self, spend_usd: float, cap_usd: float) -> None:
        self.spend_usd = spend_usd
        self.cap_usd = cap_usd
        super().__init__(
            f"OpenRouter monthly spend cap exceeded: ${spend_usd:.4f} >= ${cap_usd:.2f}"
        )


@dataclass(frozen=True)
class MonthlySpend:
    """Current-month cost breakdown by source."""

    query_logs_cost_usd: float
    enrichment_cost_usd: float

    # Per-source token totals (for /v1/admin/usage).
    synthesis_tokens_in: int
    synthesis_tokens_out: int
    synthesis_cost_usd: float

    intent_router_tokens_in: int
    intent_router_tokens_out: int
    intent_router_cost_usd: float

    enrichment_tokens_in: int
    enrichment_tokens_out: int

    @property
    def total_cost_usd(self) -> float:
        return self.query_logs_cost_usd + self.enrichment_cost_usd


def _month_start() -> datetime:
    """Return the first instant of the current calendar month (UTC)."""
    now = datetime.now(UTC)
    return now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


async def get_current_month_spend(
    session_factory: async_sessionmaker[AsyncSession],
) -> MonthlySpend:
    """Sum all costs incurred in the current calendar month from both sources.

    Sources:
      1. query_logs — synthesis_cost + intent_router_cost columns (NULL → 0).
      2. enrichment_state.notes — JSONB field total_cost_usd (absent → 0).

    Returns a MonthlySpend dataclass with per-source breakdowns.
    """
    start = _month_start()

    async with session_factory() as session:
        # --- Query logs aggregates ---
        ql_stmt = select(
            func.coalesce(func.sum(QueryLog.synthesis_cost), 0).label("synthesis_cost"),
            func.coalesce(func.sum(QueryLog.synthesis_input_tokens), 0).label(
                "synthesis_tokens_in"
            ),
            func.coalesce(func.sum(QueryLog.synthesis_output_tokens), 0).label(
                "synthesis_tokens_out"
            ),
            func.coalesce(func.sum(QueryLog.intent_router_cost), 0).label("intent_router_cost"),
            func.coalesce(func.sum(QueryLog.intent_router_input_tokens), 0).label(
                "intent_router_tokens_in"
            ),
            func.coalesce(func.sum(QueryLog.intent_router_output_tokens), 0).label(
                "intent_router_tokens_out"
            ),
        ).where(QueryLog.created_at >= start)

        ql_row = (await session.execute(ql_stmt)).one()

        synthesis_cost = float(ql_row.synthesis_cost)
        synthesis_tokens_in = int(ql_row.synthesis_tokens_in)
        synthesis_tokens_out = int(ql_row.synthesis_tokens_out)
        intent_router_cost = float(ql_row.intent_router_cost)
        intent_router_tokens_in = int(ql_row.intent_router_tokens_in)
        intent_router_tokens_out = int(ql_row.intent_router_tokens_out)

        # --- Enrichment state aggregates ---
        # JSONB cast: (notes->>'total_cost_usd')::float, defaulting NULL to 0.
        enr_cost_sql = text(
            """
            SELECT
                COALESCE(SUM((notes->>'total_cost_usd')::float), 0)    AS enrichment_cost,
                COALESCE(SUM((notes->>'total_input_tokens')::int), 0)   AS enrichment_tokens_in,
                COALESCE(SUM((notes->>'total_output_tokens')::int), 0)  AS enrichment_tokens_out
            FROM enrichment_state
            WHERE run_started_at >= :start
              AND notes IS NOT NULL
            """
        )
        enr_row = (await session.execute(enr_cost_sql, {"start": start})).one()
        enrichment_cost = float(enr_row.enrichment_cost)
        enrichment_tokens_in = int(enr_row.enrichment_tokens_in)
        enrichment_tokens_out = int(enr_row.enrichment_tokens_out)

    query_logs_cost = synthesis_cost + intent_router_cost

    return MonthlySpend(
        query_logs_cost_usd=query_logs_cost,
        enrichment_cost_usd=enrichment_cost,
        synthesis_tokens_in=synthesis_tokens_in,
        synthesis_tokens_out=synthesis_tokens_out,
        synthesis_cost_usd=synthesis_cost,
        intent_router_tokens_in=intent_router_tokens_in,
        intent_router_tokens_out=intent_router_tokens_out,
        intent_router_cost_usd=intent_router_cost,
        enrichment_tokens_in=enrichment_tokens_in,
        enrichment_tokens_out=enrichment_tokens_out,
    )


async def check_spend_cap(
    session_factory: async_sessionmaker[AsyncSession],
    override_settings: Settings | None = None,
) -> None:
    """Check current-month spend against the configured cap.

    - Below 80%: no-op.
    - [80%, 100%): log a ``warning`` on every call (not a one-shot sentinel).
    - >= 100%: raise SpendCapExceededError.

    Args:
        session_factory: Async session factory — used to call get_current_month_spend.
        override_settings: Inject a custom Settings instance (tests / CLI). Falls
            back to the process-level settings singleton when None.
    """
    if override_settings is None:
        from oracle.core.config import settings as _settings

        cap = _settings.openrouter_monthly_cap_usd
    else:
        cap = override_settings.openrouter_monthly_cap_usd

    spend = await get_current_month_spend(session_factory)
    total = spend.total_cost_usd

    if cap <= 0:
        # Cap of zero means unlimited — skip enforcement.
        return

    pct = total / cap

    if pct >= 1.0:
        logger.warning(
            "spend_cap.exceeded",
            spend_usd=round(total, 6),
            cap_usd=cap,
            cap_pct_used=round(pct, 4),
        )
        raise SpendCapExceededError(spend_usd=total, cap_usd=cap)

    if pct >= _WARN_THRESHOLD:
        logger.warning(
            "spend_cap.approaching",
            spend_usd=round(total, 6),
            cap_usd=cap,
            cap_pct_used=round(pct, 4),
        )
