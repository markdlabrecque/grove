"""Intent router — classify query intent and run specialised-table retrieval.

Public API:
    classify_intent(query, *, api_key, model, intent_version) -> IntentResult
    parse_intent_response(raw_content) -> list[str]
    query_decisions(session, query_text) -> list[uuid.UUID]
    query_people(session, query_text) -> list[uuid.UUID]
    query_tasks(session, query_text) -> list[uuid.UUID]
    query_appointments(session, query_text, forward_looking) -> list[uuid.UUID]
    run_specialised_queries(session, intents, query_text) -> SpecialisedQueryResult
    route_and_merge(session, query_text, vector_hits, *, api_key, model) -> HybridResult

Flow:
    1. classify_intent — one cheap OpenRouter call to classify query intent.
    2. run_specialised_queries — for each non-general intent, check whether the
       target table has rows (empty-table optimisation); if it does, run the
       structured WHERE query and collect matching memory_ids.
    3. route_and_merge — merge specialised hits into the vector-hit candidate set,
       deduping by memory_id and applying intent_match_score_boost to specialised
       matches, then return the enriched candidate list and a tables_searched dict.

Errors:
    Any httpx exception from the OpenRouter classify call propagates. The caller
    (post_query) catches it and falls through to vector-only results.
    Specialised-table query failures propagate (they are DB errors, not recoverable
    by degrading gracefully — let the outer handler surface them).
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field
from typing import Any

import structlog
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from oracle.llm.openrouter import chat_completion
from oracle.llm.prompts import load_intent_prompts
from oracle.models.appointment import Appointment
from oracle.models.decision import Decision
from oracle.models.people_interaction import PeopleInteraction
from oracle.models.task import Task

logger = structlog.get_logger(__name__)

_DEFAULT_INTENT_VERSION = 1

_VALID_INTENTS = frozenset(["decisions", "people_interactions", "tasks", "appointments", "general"])

# Number of words from the query to use in ILIKE matching.
# The full query string is used — splitting is done by the DB pattern.
_ILIKE_PATTERN_LIMIT = 5


# ---------------------------------------------------------------------------
# Public result types
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class IntentResult:
    """Output of classify_intent — parsed intents plus per-call telemetry."""

    intents: list[str]
    prompt_tokens: int
    completion_tokens: int
    cost_usd: float | None
    model: str


@dataclass
class SpecialisedQueryResult:
    """Collected memory_ids from specialised table queries, plus tables_searched metadata."""

    hits: list[uuid.UUID] = field(default_factory=list)
    # Outcome per table: "matched" | "empty" | "skipped"
    tables_searched: dict[str, str | bool] = field(default_factory=dict)


@dataclass(frozen=True)
class HybridResult:
    """Merged candidate set after combining vector hits with specialised hits."""

    candidates: list[dict[str, Any]]
    tables_searched: dict[str, str | bool]


# ---------------------------------------------------------------------------
# Intent classification
# ---------------------------------------------------------------------------


def parse_intent_response(raw_content: str) -> list[str]:
    """Parse the model's JSON response into a validated list of intent strings.

    Falls back to ["general"] on any parse or validation error so the query
    path degrades gracefully to vector-only retrieval rather than failing.
    """
    try:
        payload = json.loads(raw_content)
    except (json.JSONDecodeError, ValueError):
        logger.warning("intent_router.parse.malformed_json", raw=raw_content[:200])
        return ["general"]

    if not isinstance(payload, dict):
        logger.warning("intent_router.parse.not_dict", raw=raw_content[:200])
        return ["general"]

    raw_intents = payload.get("intents")
    if not isinstance(raw_intents, list):
        logger.warning("intent_router.parse.missing_intents_key", raw=raw_content[:200])
        return ["general"]

    # Filter to valid values only.
    valid = [v for v in raw_intents if isinstance(v, str) and v in _VALID_INTENTS]

    if not valid:
        logger.info("intent_router.parse.no_valid_intents_fallback_general")
        return ["general"]

    return valid


async def classify_intent(
    query: str,
    *,
    api_key: str,
    model: str | None = None,
    intent_version: int = _DEFAULT_INTENT_VERSION,
) -> IntentResult:
    """Classify the user query into one or more intent categories via OpenRouter.

    Args:
        query: The user's original query string.
        api_key: OpenRouter API key.
        model: OpenRouter model identifier; falls back to settings.intent_router_model.
        intent_version: Prompt version to load (defaults to 1).  Pass a
            different integer to load an alternate intent.v<N>.yaml file.

    Returns:
        IntentResult with validated intents and per-call telemetry.

    Raises:
        httpx.HTTPStatusError: 4xx/5xx from OpenRouter.
        httpx.RequestError: Network-level failures.
    """
    if model is None:
        from oracle.core.config import settings

        model = settings.intent_router_model

    bundle = load_intent_prompts(intent_version)
    user_content = bundle.user_prompt_template.format(query=query)
    messages = [
        {"role": "system", "content": bundle.system_prompt},
        {"role": "user", "content": user_content},
    ]

    log = logger.bind(model=model)
    log.info("intent_router.classify.start")

    completion = await chat_completion(
        api_key=api_key,
        model=model,
        messages=messages,
        response_format={"type": "json_object"},
        timeout=30.0,
    )

    intents = parse_intent_response(completion.content)

    log.info(
        "intent_router.classify.ok",
        intents=intents,
        prompt_tokens=completion.prompt_tokens,
        completion_tokens=completion.completion_tokens,
        cost_usd=completion.cost_usd,
    )

    return IntentResult(
        intents=intents,
        prompt_tokens=completion.prompt_tokens,
        completion_tokens=completion.completion_tokens,
        cost_usd=completion.cost_usd,
        model=model,
    )


# ---------------------------------------------------------------------------
# Empty-table check
# ---------------------------------------------------------------------------


async def _table_has_rows(session: AsyncSession, table_name: str) -> bool:
    """Return True when the named table contains at least one row.

    Uses EXISTS rather than COUNT(*) to short-circuit on the first row.
    The table name is embedded as a literal string — callers must only pass
    known, validated table names (not user input).
    """
    result = await session.execute(
        text(f"SELECT EXISTS (SELECT 1 FROM {table_name} LIMIT 1)")  # noqa: S608
    )
    return bool(result.scalar())


# ---------------------------------------------------------------------------
# Specialised-table query helpers
# ---------------------------------------------------------------------------


def _word_patterns(query_text: str) -> list[str]:
    """Split query into individual word ILIKE patterns.

    Returns a list of patterns like ['%OAuth2%', '%decision%'] from the first
    few significant words (stop words stripped). At personal-corpus scale,
    matching any single term broadly is the right trade-off — precision is
    provided by the vector path; the specialised path is for recall.
    """
    # Simple word split; take first N non-trivial words.
    stop_words = {"a", "an", "the", "is", "are", "was", "were", "and", "or", "of", "in", "for"}
    words = [
        w.strip(".,?!") for w in query_text.split() if w.strip(".,?!").lower() not in stop_words
    ]
    # Return patterns for the first 5 meaningful words.
    return [f"%{w}%" for w in words[:5]] if words else [f"%{query_text}%"]


async def query_decisions(session: AsyncSession, query_text: str) -> list[uuid.UUID]:
    """Return distinct memory_ids from decisions matching query terms.

    Matches against context OR chosen_option via ILIKE on any query word.
    """
    from sqlalchemy import or_

    patterns = _word_patterns(query_text)
    # Build OR clause: any column matches any word pattern.
    conditions = [Decision.context.ilike(p) | Decision.chosen_option.ilike(p) for p in patterns]
    stmt = select(Decision.memory_id).where(or_(*conditions)).distinct()
    result = await session.execute(stmt)
    return list(result.scalars().all())


async def query_people(session: AsyncSession, query_text: str) -> list[uuid.UUID]:
    """Return distinct memory_ids from people_interactions matching query terms.

    Matches against person_name via ILIKE on any query word.
    """
    from sqlalchemy import or_

    patterns = _word_patterns(query_text)
    conditions = [PeopleInteraction.person_name.ilike(p) for p in patterns]
    stmt = select(PeopleInteraction.memory_id).where(or_(*conditions)).distinct()
    result = await session.execute(stmt)
    return list(result.scalars().all())


async def query_tasks(session: AsyncSession, query_text: str) -> list[uuid.UUID]:
    """Return distinct memory_ids from tasks matching query terms.

    Filters to open tasks (status = 'open') that are current or recent
    (due_date IS NULL OR due_date >= now() - 7 days), combined with a
    text match on description.
    """
    from sqlalchemy import or_

    patterns = _word_patterns(query_text)
    description_match = or_(*[Task.description.ilike(p) for p in patterns])
    seven_days_ago = text("now() - interval '7 days'")
    stmt = (
        select(Task.memory_id)
        .where(
            Task.status == "open",
            or_(Task.due_date.is_(None), Task.due_date >= seven_days_ago),
            description_match,
        )
        .distinct()
    )
    result = await session.execute(stmt)
    return list(result.scalars().all())


async def query_appointments(
    session: AsyncSession,
    query_text: str,
    *,
    forward_looking: bool = True,
) -> list[uuid.UUID]:
    """Return distinct memory_ids from appointments.

    forward_looking=True: starts_at >= now() (upcoming events).
    forward_looking=False: starts_at < now() (retrospective).
    Also includes appointments with NULL starts_at (no time anchor) since
    those are partially structured and may still be relevant.
    """
    from sqlalchemy import or_

    now_expr = text("now()")
    if forward_looking:
        time_filter = or_(
            Appointment.starts_at.is_(None),
            Appointment.starts_at >= now_expr,
        )
    else:
        time_filter = or_(
            Appointment.starts_at.is_(None),
            Appointment.starts_at < now_expr,
        )

    stmt = select(Appointment.memory_id).where(time_filter).distinct()
    result = await session.execute(stmt)
    return list(result.scalars().all())


# ---------------------------------------------------------------------------
# Orchestrator: run all relevant specialised queries
# ---------------------------------------------------------------------------

# Canonical table names for the four specialised tables.
_SPECIALISED_TABLES: dict[str, str] = {
    "decisions": "decisions",
    "people_interactions": "people_interactions",
    "tasks": "tasks",
    "appointments": "appointments",
}


async def run_specialised_queries(
    session: AsyncSession,
    intents: list[str],
    query_text: str,
) -> SpecialisedQueryResult:
    """Run specialised-table queries for each intent that is not 'general'.

    For each intent:
    - If the target table is empty → log "empty", skip the query.
    - Otherwise → run the structured WHERE query, log "matched" or "empty".

    Returns a SpecialisedQueryResult with all matching memory_ids and a
    tables_searched dict recording the outcome per table.
    """
    result = SpecialisedQueryResult()

    for intent_name in _SPECIALISED_TABLES:
        if intent_name not in intents:
            result.tables_searched[intent_name] = "skipped"
            continue

        table_name = _SPECIALISED_TABLES[intent_name]
        has_rows = await _table_has_rows(session, table_name)
        if not has_rows:
            logger.info("intent_router.specialised_query.empty", table=table_name)
            result.tables_searched[intent_name] = "empty"
            continue

        # Run the appropriate structured query.
        hits: list[uuid.UUID]
        if intent_name == "decisions":
            hits = await query_decisions(session, query_text)
        elif intent_name == "people_interactions":
            hits = await query_people(session, query_text)
        elif intent_name == "tasks":
            hits = await query_tasks(session, query_text)
        elif intent_name == "appointments":
            # V1 scope: only surface upcoming appointments. Past-tense queries
            # ("what appointments did I miss?") fall through to semantic search
            # rather than getting a structured-table answer. Revisit once intent
            # classification surfaces a tense / temporal-direction signal.
            hits = await query_appointments(session, query_text, forward_looking=True)
        else:
            hits = []

        # "empty" here means "queried but no rows matched the query".  This is
        # distinct from "skipped" (intent classifier did not select this table) and
        # consistent with the "table has zero rows" branch above — both are flavours
        # of "we asked, nothing came back" from the operator's telemetry standpoint.
        result.tables_searched[intent_name] = "matched" if hits else "empty"
        result.hits.extend(hits)

        logger.info(
            "intent_router.specialised_query.done",
            table=table_name,
            hit_count=len(hits),
        )

    return result


# ---------------------------------------------------------------------------
# Merge: combine specialised hits with vector candidates
# ---------------------------------------------------------------------------


def merge_with_specialised(
    vector_hits: list[dict[str, Any]],
    specialised_memory_ids: list[uuid.UUID],
    score_boost: float,
) -> list[dict[str, Any]]:
    """Merge specialised-table hits into the vector candidate list.

    Rules:
    - For each specialised memory_id already in vector_hits: boost its score
      by score_boost.
    - For each specialised memory_id NOT yet in vector_hits: synthesise a
      candidate hit dict with score = score_boost (it has no cosine score,
      so the boost becomes its entire score).
    - Dedup by memory_id, keeping higher score.
    - Does not sort — the caller (_merge_hits in queries.py) handles final ranking.
    """
    # Build a mutable working set keyed by memory_id.
    candidates: dict[uuid.UUID, dict[str, Any]] = {}
    for hit in vector_hits:
        mid = hit["memory_id"]
        if mid not in candidates or hit["score"] > candidates[mid]["score"]:
            candidates[mid] = dict(hit)

    boosted_ids = set(specialised_memory_ids)

    # Apply boost to existing vector hits.
    for mid in list(candidates):
        if mid in boosted_ids:
            candidates[mid] = {**candidates[mid], "score": candidates[mid]["score"] + score_boost}

    # Add specialised-only hits (no vector score — use boost as their score).
    for mid in boosted_ids:
        if mid not in candidates:
            candidates[mid] = {
                "memory_id": mid,
                "score": score_boost,
                "matched_via": "specialised",
                "matched_chunk_index": None,
                "snippet": "",  # no excerpt until memory content is loaded
            }

    return list(candidates.values())
