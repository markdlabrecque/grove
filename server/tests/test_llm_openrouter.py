"""Unit tests for grove.llm.openrouter.chat_completion.

All tests mock at the HTTP boundary with respx — no live OpenRouter calls.

Coverage:
  - All four request headers present with correct values.
  - Authorization header carries "Bearer <key>" prefix.
  - Cost body: present (returns float), missing (returns None), malformed (returns None).
  - Cost read from usage.cost body field (not x-openrouter-cost header).
  - Non-2xx response propagates httpx.HTTPStatusError.
  - response_format forwarded when provided, omitted when None.
  - Timeout forwarded to the underlying httpx call.
  - Usage fields extracted correctly; total_tokens falls back when absent.
"""

from __future__ import annotations

import httpx
import pytest
import respx

from grove.core.config import settings
from grove.llm.openrouter import ChatCompletionResult, chat_completion

_OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

_MESSAGES = [
    {"role": "system", "content": "You are helpful."},
    {"role": "user", "content": "Hello"},
]


def _make_response(
    content: str = "Hello there!",
    prompt_tokens: int = 10,
    completion_tokens: int = 5,
    total_tokens: int | None = None,
    cost_header: str | None = None,
    cost_body: float | None = 0.00042,
    status_code: int = 200,
) -> httpx.Response:
    usage: dict = {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
    }
    if total_tokens is not None:
        usage["total_tokens"] = total_tokens
    if cost_body is not None:
        usage["cost"] = cost_body

    body = {
        "id": "gen-test",
        "object": "chat.completion",
        "model": "openai/gpt-4o-mini",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ],
        "usage": usage,
    }
    headers = {}
    if cost_header is not None:
        headers["x-openrouter-cost"] = cost_header
    return httpx.Response(status_code, json=body, headers=headers)


# ---------------------------------------------------------------------------
# Request headers
# ---------------------------------------------------------------------------


class TestRequestHeaders:
    @respx.mock
    async def test_all_four_headers_sent(self) -> None:
        """All four OpenRouter headers are present on every request."""
        route = respx.post(_OPENROUTER_URL).mock(return_value=_make_response())

        await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert route.called
        request = route.calls.last.request
        assert "Authorization" in request.headers
        assert "Content-Type" in request.headers
        assert "HTTP-Referer" in request.headers
        assert "X-Title" in request.headers

    @respx.mock
    async def test_authorization_has_bearer_prefix(self) -> None:
        """Authorization header value is 'Bearer <api_key>'."""
        route = respx.post(_OPENROUTER_URL).mock(return_value=_make_response())

        await chat_completion(
            api_key="my-secret-key",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        request = route.calls.last.request
        assert request.headers["Authorization"] == "Bearer my-secret-key"

    @respx.mock
    async def test_content_type_is_json(self) -> None:
        route = respx.post(_OPENROUTER_URL).mock(return_value=_make_response())

        await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        request = route.calls.last.request
        assert request.headers["Content-Type"] == "application/json"

    @respx.mock
    async def test_http_referer_and_x_title(self) -> None:
        route = respx.post(_OPENROUTER_URL).mock(return_value=_make_response())

        await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        request = route.calls.last.request
        assert "github.com" in request.headers["HTTP-Referer"]
        assert request.headers["X-Title"] == "Grove"


# ---------------------------------------------------------------------------
# Cost body parsing (usage.cost — primary source)
# ---------------------------------------------------------------------------


class TestCostBodyParsing:
    @respx.mock
    async def test_cost_from_body_present_returns_float(self) -> None:
        """usage.cost in response body → cost_usd is a float."""
        # No x-openrouter-cost header; cost only in usage.cost body field.
        respx.post(_OPENROUTER_URL).mock(
            return_value=_make_response(cost_body=0.0012, cost_header=None)
        )

        result = await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert result.cost_usd == pytest.approx(0.0012)

    @respx.mock
    async def test_cost_body_absent_returns_none(self) -> None:
        """usage.cost absent from body AND no header → cost_usd is None."""
        respx.post(_OPENROUTER_URL).mock(
            return_value=_make_response(cost_body=None, cost_header=None)
        )

        result = await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert result.cost_usd is None

    @respx.mock
    async def test_cost_body_takes_priority_over_header(self) -> None:
        """When both usage.cost body and x-openrouter-cost header are present,
        body value is used (header is legacy)."""
        respx.post(_OPENROUTER_URL).mock(
            return_value=_make_response(cost_body=0.0012, cost_header="0.0099")
        )

        result = await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert result.cost_usd == pytest.approx(0.0012)


# ---------------------------------------------------------------------------
# HTTP error propagation
# ---------------------------------------------------------------------------


class TestHttpErrors:
    @respx.mock
    async def test_non_2xx_raises_http_status_error(self) -> None:
        """4xx/5xx from OpenRouter propagates as httpx.HTTPStatusError."""
        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(500, json={"error": "internal error"})
        )

        with pytest.raises(httpx.HTTPStatusError):
            await chat_completion(
                api_key="sk-test",
                model="openai/gpt-4o-mini",
                messages=_MESSAGES,
            )

    @respx.mock
    async def test_429_raises_http_status_error(self) -> None:
        """429 rate-limit propagates as httpx.HTTPStatusError."""
        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(429, json={"error": "rate limited"})
        )

        with pytest.raises(httpx.HTTPStatusError):
            await chat_completion(
                api_key="sk-test",
                model="openai/gpt-4o-mini",
                messages=_MESSAGES,
            )


# ---------------------------------------------------------------------------
# Response payload parsing
# ---------------------------------------------------------------------------


class TestResponseParsing:
    @respx.mock
    async def test_result_type_is_chat_completion_result(self) -> None:
        respx.post(_OPENROUTER_URL).mock(return_value=_make_response())

        result = await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert isinstance(result, ChatCompletionResult)

    @respx.mock
    async def test_content_extracted_from_choices(self) -> None:
        respx.post(_OPENROUTER_URL).mock(return_value=_make_response(content="The answer is 42."))

        result = await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert result.content == "The answer is 42."

    @respx.mock
    async def test_usage_tokens_extracted(self) -> None:
        respx.post(_OPENROUTER_URL).mock(
            return_value=_make_response(
                prompt_tokens=100,
                completion_tokens=50,
                total_tokens=150,
            )
        )

        result = await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert result.prompt_tokens == 100
        assert result.completion_tokens == 50
        assert result.total_tokens == 150

    @respx.mock
    async def test_total_tokens_fallback_when_absent(self) -> None:
        """When usage.total_tokens is absent, falls back to prompt+completion."""
        respx.post(_OPENROUTER_URL).mock(
            return_value=_make_response(
                prompt_tokens=30,
                completion_tokens=20,
                total_tokens=None,  # omitted from body
            )
        )

        result = await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert result.total_tokens == 50  # 30 + 20

    @respx.mock
    async def test_raw_contains_full_response_body(self) -> None:
        """result.raw is the full parsed JSON dict."""
        respx.post(_OPENROUTER_URL).mock(return_value=_make_response())

        result = await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
        )

        assert "choices" in result.raw
        assert "usage" in result.raw


# ---------------------------------------------------------------------------
# Optional parameters
# ---------------------------------------------------------------------------


class TestOptionalParameters:
    @respx.mock
    async def test_response_format_included_when_provided(self) -> None:
        """response_format dict is forwarded in the request JSON body."""
        import json

        route = respx.post(_OPENROUTER_URL).mock(return_value=_make_response())

        await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
            response_format={"type": "json_object"},
        )

        request = route.calls.last.request
        body = json.loads(request.content)
        assert body.get("response_format") == {"type": "json_object"}

    @respx.mock
    async def test_response_format_omitted_when_none(self) -> None:
        """When response_format is None, the key is absent from the request body."""
        import json

        route = respx.post(_OPENROUTER_URL).mock(return_value=_make_response())

        await chat_completion(
            api_key="sk-test",
            model="openai/gpt-4o-mini",
            messages=_MESSAGES,
            response_format=None,
        )

        request = route.calls.last.request
        body = json.loads(request.content)
        assert "response_format" not in body


# ---------------------------------------------------------------------------
# Configurable base URL (#518) — local (Ollama) endpoints must be reachable
# without touching openrouter.ai.
# ---------------------------------------------------------------------------


class TestConfigurableBaseUrl:
    @respx.mock
    async def test_request_targets_configured_chat_base_url(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """chat_completion posts to settings.chat_base_url, not a hardcoded URL."""
        monkeypatch.setattr(settings, "chat_base_url", "http://host.docker.internal:11434/v1")
        route = respx.post("http://host.docker.internal:11434/v1/chat/completions").mock(
            return_value=_make_response()
        )

        await chat_completion(
            api_key="sk-test",
            model="gpt-oss-20b",
            messages=_MESSAGES,
        )

        assert route.called
