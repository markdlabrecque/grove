"""OpenRouter-backed memory classifier.

Public API:
    classify_memory(memory, prompt_bundle, *, api_key, model)
        -> ClassificationResult | SkippedReason

The function is a pure async unit: it takes a Memory-like object and a
PromptBundle, makes one chat-completion call to OpenRouter configured for
structured JSON output, validates the response against the Classification
Pydantic schema, and returns telemetry alongside the parsed result.

Errors:
    SkippedReason.TOO_LARGE — returned (not raised) when token_count > 8000.
        No HTTP call is made in this case.
    ClassificationError — raised when the model response cannot be parsed
        or validated against Classification.  Caller should record
        enrichment_error and leave enriched=False for retry.
    Any httpx exception — propagates unchanged.  Caller decides retry policy.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

import structlog
from pydantic import ValidationError

from oracle.embeddings.tokenizer import count_tokens
from oracle.enrichment.schemas import Classification, PromptBundle
from oracle.llm.openrouter import chat_completion

logger = structlog.get_logger(__name__)

_TOKEN_CAP = 8000


# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------


class SkippedReason(StrEnum):
    TOO_LARGE = "too_large"


class ClassificationError(Exception):
    """Raised when the model response cannot be parsed as a Classification."""


@dataclass(frozen=True)
class ClassificationResult:
    """Parsed classification plus per-call telemetry."""

    classification: Classification
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    # None when the x-openrouter-cost header is absent (e.g. some models).
    cost_usd: float | None


# ---------------------------------------------------------------------------
# Memory protocol — avoids importing the SQLAlchemy model here
# ---------------------------------------------------------------------------


class MemoryLike(Protocol):
    content: str
    token_count: int | None


# ---------------------------------------------------------------------------
# Classifier
# ---------------------------------------------------------------------------


async def classify_memory(
    memory: MemoryLike,
    prompt_bundle: PromptBundle,
    *,
    api_key: str,
    model: str | None = None,
) -> ClassificationResult | SkippedReason:
    """Classify *memory* using OpenRouter and return a ClassificationResult.

    Args:
        memory: Any object exposing ``content: str`` and
            ``token_count: int | None``.  When ``token_count`` is None the
            token count is recomputed via tiktoken.
        prompt_bundle: Loaded YAML prompt bundle (system prompt + type defs).
        api_key: OpenRouter API key.
        model: OpenRouter model string; falls back to ``settings.enrichment_model``.

    Returns:
        ClassificationResult on success, SkippedReason.TOO_LARGE when the
        memory exceeds the token cap.

    Raises:
        ClassificationError: Response is not valid JSON or fails Pydantic
            validation.
        httpx.HTTPStatusError: 4xx/5xx from OpenRouter.
    """
    # --- Lazy import to avoid circular settings import in tests ---
    if model is None:
        from oracle.core.config import settings

        model = settings.enrichment_model

    # --- Token cap pre-check (no HTTP call for oversize memories) ---
    token_count = memory.token_count
    if token_count is None:
        token_count = count_tokens(memory.content)

    if token_count > _TOKEN_CAP:
        logger.info(
            "classifier.skipped.too_large",
            token_count=token_count,
            cap=_TOKEN_CAP,
        )
        return SkippedReason.TOO_LARGE

    # --- Build messages ---
    messages = _build_messages(memory.content, prompt_bundle)

    # --- OpenRouter call ---
    log = logger.bind(model=model, token_count=token_count)
    log.info("classifier.request.start")

    # Structured JSON output — tells the model to respond with syntactically
    # valid JSON only.
    completion = await chat_completion(
        api_key=api_key,
        model=model,
        messages=messages,
        response_format={"type": "json_object"},
        timeout=60.0,
    )

    prompt_tokens = completion.prompt_tokens
    completion_tokens = completion.completion_tokens
    total_tokens = completion.total_tokens
    cost_usd = completion.cost_usd

    log.info(
        "classifier.request.ok",
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        cost_usd=cost_usd,
    )

    # --- Parse and validate ---
    raw_content: str = completion.content

    try:
        payload = json.loads(raw_content)
    except json.JSONDecodeError as exc:
        raise ClassificationError(
            f"Model returned non-JSON content: {raw_content[:200]!r}"
        ) from exc

    try:
        classification = Classification.model_validate(payload)
    except ValidationError as exc:
        raise ClassificationError(f"Classification schema validation failed: {exc}") from exc

    return ClassificationResult(
        classification=classification,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=total_tokens,
        cost_usd=cost_usd,
    )


# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------


def _build_messages(content: str, bundle: PromptBundle) -> list[dict[str, str]]:
    """Assemble the system + user messages for the classification call."""
    return [
        {"role": "system", "content": bundle.system_prompt},
        {"role": "user", "content": content},
    ]
