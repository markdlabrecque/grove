"""GET /v1/admin/usage — current-month OpenRouter cost summary.

Returns per-source aggregates (synthesis, intent_router, enrichment) plus
cap metadata so the operator can gauge cost consumption without querying
the DB directly.
"""

from __future__ import annotations

from typing import Annotated

import structlog
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from oracle.admin.spend import get_current_month_spend
from oracle.core.db import SessionLocal, get_session

logger = structlog.get_logger(__name__)

router = APIRouter()


# ---------------------------------------------------------------------------
# Response schema
# ---------------------------------------------------------------------------


class SourceStats(BaseModel):
    tokens_in: int
    tokens_out: int
    cost_usd: float


class UsageResponse(BaseModel):
    synthesis: SourceStats
    intent_router: SourceStats
    enrichment: SourceStats
    month_cap_usd: float
    cap_pct_used: float


# ---------------------------------------------------------------------------
# Dependency
# ---------------------------------------------------------------------------


def get_log_session_factory() -> async_sessionmaker[AsyncSession]:
    return SessionLocal


# ---------------------------------------------------------------------------
# Route
# ---------------------------------------------------------------------------


@router.get(
    "/admin/usage",
    response_model=UsageResponse,
)
async def get_usage(
    _session: Annotated[AsyncSession, Depends(get_session)],
    log_factory: Annotated[async_sessionmaker[AsyncSession], Depends(get_log_session_factory)],
) -> UsageResponse:
    """Return current-month OpenRouter cost aggregates by source."""
    from oracle.core.config import settings

    spend = await get_current_month_spend(log_factory)

    cap = settings.openrouter_monthly_cap_usd
    cap_pct = spend.total_cost_usd / cap if cap > 0 else 0.0

    logger.info(
        "admin.usage.fetched",
        total_cost_usd=round(spend.total_cost_usd, 6),
        cap_pct_used=round(cap_pct, 4),
    )

    return UsageResponse(
        synthesis=SourceStats(
            tokens_in=spend.synthesis_tokens_in,
            tokens_out=spend.synthesis_tokens_out,
            cost_usd=spend.synthesis_cost_usd,
        ),
        intent_router=SourceStats(
            tokens_in=spend.intent_router_tokens_in,
            tokens_out=spend.intent_router_tokens_out,
            cost_usd=spend.intent_router_cost_usd,
        ),
        enrichment=SourceStats(
            tokens_in=spend.enrichment_tokens_in,
            tokens_out=spend.enrichment_tokens_out,
            cost_usd=spend.enrichment_cost_usd,
        ),
        month_cap_usd=cap,
        cap_pct_used=round(cap_pct, 6),
    )
