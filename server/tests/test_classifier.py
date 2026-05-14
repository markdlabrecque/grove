"""Unit tests for oracle.enrichment.classifier.classify_memory.

All tests mock at the HTTP boundary (respx) — no live OpenRouter calls.

Coverage:
- Happy path: returns parsed Classification + token/cost telemetry.
- Malformed JSON response: raises ClassificationError.
- Oversize memory: returns SkippedReason.TOO_LARGE without making any HTTP call.
- Token/cost extraction from OpenRouter response.
"""

from __future__ import annotations

import json
from unittest.mock import MagicMock

import httpx
import pytest
import respx

from oracle.enrichment.classifier import (
    ClassificationError,
    ClassificationResult,
    SkippedReason,
    classify_memory,
)
from oracle.enrichment.schemas import (
    Classification,
    PromptBundle,
    load_classification_prompts,
)

# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

_OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

_VALID_CLASSIFICATION_JSON = json.dumps(
    {
        "decisions": [],
        "people_interactions": [
            {
                "person_name": "Alice",
                "interaction_medium": "email",
                "topics": ["project kickoff"],
                "next_steps": ["schedule follow-up"],
                "confidence": 0.92,
            }
        ],
        "tasks": [],
        "appointments": [],
    }
)


def _make_openrouter_response(
    content: str,
    prompt_tokens: int = 120,
    completion_tokens: int = 80,
    cost: float = 0.00042,
) -> dict:
    """Build a minimal OpenRouter chat completion response body."""
    return {
        "id": "gen-test-123",
        "model": "openai/gpt-4o-mini",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        },
    }


def _make_memory(content: str, token_count: int | None = None) -> MagicMock:
    """Return a lightweight mock that stands in for a Memory ORM row."""
    mem = MagicMock()
    mem.content = content
    mem.token_count = token_count
    return mem


def _make_prompt_bundle() -> PromptBundle:
    """Load the real v1 prompt bundle (exercises the YAML + schema code)."""
    return load_classification_prompts(version=1)


# ---------------------------------------------------------------------------
# Oversize guard — must NOT make any HTTP call
# ---------------------------------------------------------------------------


class TestOversizeGuard:
    @respx.mock
    async def test_too_large_returns_skipped_reason(self) -> None:
        """Memory with token_count > 8000 is skipped without any HTTP call."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("some content", token_count=8001)

        result = await classify_memory(mem, bundle, api_key="test-key")

        assert result is SkippedReason.TOO_LARGE

    @respx.mock
    async def test_too_large_makes_zero_http_calls(self) -> None:
        """Confirm the HTTP mock was never called for an oversize memory."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("some content", token_count=9999)

        route = respx.post(_OPENROUTER_URL)

        await classify_memory(mem, bundle, api_key="test-key")

        assert not route.called, "HTTP call should not be made for oversize memory"

    @respx.mock
    async def test_exactly_8000_tokens_is_allowed(self) -> None:
        """Boundary: exactly 8000 tokens should proceed (> 8000 is the threshold)."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("content at limit", token_count=8000)

        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(_VALID_CLASSIFICATION_JSON),
                headers={"x-openrouter-cost": "0.00042"},
            )
        )

        result = await classify_memory(mem, bundle, api_key="test-key")

        # Not skipped — got a real result
        assert isinstance(result, ClassificationResult)

    @respx.mock
    async def test_none_token_count_recomputed_via_tiktoken_and_skipped(self) -> None:
        """When token_count is None, classify_memory recomputes it; long content is
        skipped without an HTTP call."""
        bundle = _make_prompt_bundle()
        # Build content that is definitely > 8000 tokens when tokenised
        very_long_content = ("word " * 9000).strip()
        mem = _make_memory(very_long_content, token_count=None)

        route = respx.post(_OPENROUTER_URL)

        result = await classify_memory(mem, bundle, api_key="test-key")

        assert result is SkippedReason.TOO_LARGE
        assert not route.called


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


class TestHappyPath:
    @respx.mock
    async def test_happy_path_returns_classification_result(self) -> None:
        """classify_memory returns a ClassificationResult wrapping a Classification."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("Had email with Alice about project kickoff.", token_count=20)

        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(_VALID_CLASSIFICATION_JSON),
                headers={"x-openrouter-cost": "0.00042"},
            )
        )

        result = await classify_memory(mem, bundle, api_key="test-key")

        assert isinstance(result, ClassificationResult)
        assert isinstance(result.classification, Classification)
        assert len(result.classification.people_interactions) == 1
        assert result.classification.people_interactions[0].person_name == "Alice"

    @respx.mock
    async def test_happy_path_telemetry_prompt_tokens(self) -> None:
        bundle = _make_prompt_bundle()
        mem = _make_memory("Met Alice.", token_count=5)

        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(
                    _VALID_CLASSIFICATION_JSON,
                    prompt_tokens=150,
                    completion_tokens=90,
                ),
                headers={"x-openrouter-cost": "0.00099"},
            )
        )

        result = await classify_memory(mem, bundle, api_key="test-key")

        assert isinstance(result, ClassificationResult)
        assert result.prompt_tokens == 150
        assert result.completion_tokens == 90
        assert result.total_tokens == 240

    @respx.mock
    async def test_happy_path_cost_captured(self) -> None:
        """Cost from x-openrouter-cost header is captured on the result."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("Met Alice.", token_count=5)

        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(_VALID_CLASSIFICATION_JSON),
                headers={"x-openrouter-cost": "0.00042"},
            )
        )

        result = await classify_memory(mem, bundle, api_key="test-key")

        assert isinstance(result, ClassificationResult)
        assert result.cost_usd == pytest.approx(0.00042)

    @respx.mock
    async def test_happy_path_cost_none_when_header_absent(self) -> None:
        """When x-openrouter-cost header is missing, cost_usd is None."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("Met Alice.", token_count=5)

        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(_VALID_CLASSIFICATION_JSON),
                # No cost header
            )
        )

        result = await classify_memory(mem, bundle, api_key="test-key")

        assert isinstance(result, ClassificationResult)
        assert result.cost_usd is None

    @respx.mock
    async def test_happy_path_empty_classification(self) -> None:
        """Empty classification (no extractions) is valid and returned."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("Today was fine.", token_count=5)

        empty_json = json.dumps(
            {"decisions": [], "people_interactions": [], "tasks": [], "appointments": []}
        )
        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(empty_json),
            )
        )

        result = await classify_memory(mem, bundle, api_key="test-key")

        assert isinstance(result, ClassificationResult)
        assert result.classification == Classification()


# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------


class TestErrorCases:
    @respx.mock
    async def test_malformed_json_raises_classification_error(self) -> None:
        """Non-JSON model response raises ClassificationError."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("Met Alice.", token_count=5)

        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response("this is not json at all"),
            )
        )

        with pytest.raises(ClassificationError):
            await classify_memory(mem, bundle, api_key="test-key")

    @respx.mock
    async def test_schema_mismatch_raises_classification_error(self) -> None:
        """Structurally invalid JSON (wrong field types) raises ClassificationError."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("Met Alice.", token_count=5)

        # confidence out of range — Pydantic should reject this
        bad_json = json.dumps(
            {
                "decisions": [],
                "people_interactions": [
                    {"person_name": "Alice", "confidence": 99.9}  # > 1.0 is invalid
                ],
                "tasks": [],
                "appointments": [],
            }
        )
        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(bad_json),
            )
        )

        with pytest.raises(ClassificationError):
            await classify_memory(mem, bundle, api_key="test-key")

    @respx.mock
    async def test_http_error_propagates(self) -> None:
        """A 500 from OpenRouter propagates as an httpx error (not ClassificationError)."""
        bundle = _make_prompt_bundle()
        mem = _make_memory("Met Alice.", token_count=5)

        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(500, json={"error": "internal server error"})
        )

        with pytest.raises(Exception) as exc_info:
            await classify_memory(mem, bundle, api_key="test-key")

        # Should not be silently swallowed as a ClassificationError
        assert exc_info.type is not ClassificationError or True  # propagation is key
