"""Thin async wrapper around the OpenRouter chat-completion endpoint.

Public API:
    chat_completion(**kwargs) -> ChatCompletionResult

All three OpenRouter call-sites (classifier, synthesizer, intent_router) shared
identical HTTP boilerplate: the URL constant, the four request headers,
raise_for_status(), and the x-openrouter-cost header parse.  This module
consolidates that boilerplate into a single function and is the only place in
the codebase that constructs an httpx.AsyncClient for OpenRouter.

Error semantics are unchanged from the original call-sites:
    httpx.HTTPStatusError   — 4xx/5xx from OpenRouter; propagates unchanged.
    httpx.RequestError      — network-level failures; propagates unchanged.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx
import structlog

logger = structlog.get_logger(__name__)

_OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
_HTTP_REFERER = "https://github.com/markdlabrecque/grove"
_X_TITLE = "Grove"


@dataclass(frozen=True)
class ChatCompletionResult:
    """Parsed OpenRouter chat-completion response plus per-call telemetry.

    Fields:
        content         — assistant message content string.
        cost_usd        — parsed from x-openrouter-cost response header;
                          None when the header is absent or malformed.
        prompt_tokens   — usage.prompt_tokens from the response body (0 if absent).
        completion_tokens — usage.completion_tokens from the response body (0 if absent).
        total_tokens    — usage.total_tokens; falls back to prompt+completion when absent.
        raw             — full parsed JSON response dict (for callers that need
                          fields beyond the normalised ones above).
    """

    content: str
    cost_usd: float | None
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    raw: dict[str, Any]


async def chat_completion(
    *,
    api_key: str,
    model: str,
    messages: list[dict[str, str]],
    response_format: dict[str, Any] | None = None,
    timeout: float = 60.0,
) -> ChatCompletionResult:
    """Send a chat-completion request to OpenRouter and return a typed result.

    Args:
        api_key:         OpenRouter API key (plain string; caller unwraps SecretStr).
        model:           OpenRouter model identifier (e.g. "openai/gpt-4o-mini").
        messages:        List of {"role": ..., "content": ...} message dicts.
        response_format: Optional response_format dict (e.g. {"type": "json_object"}).
                         Omitted from the request body when None.
        timeout:         Request timeout in seconds.  Each call-site passes its
                         own value so the default is not silently wrong for slow
                         calls.  Classifier and synthesizer use 60.0;
                         intent_router uses 30.0.

    Returns:
        ChatCompletionResult with normalised telemetry fields and the full
        raw response dict.

    Raises:
        httpx.HTTPStatusError: 4xx/5xx from OpenRouter.
        httpx.RequestError: Network-level failures.
    """
    payload: dict[str, Any] = {"model": model, "messages": messages}
    if response_format is not None:
        payload["response_format"] = response_format

    async with httpx.AsyncClient() as client:
        response = await client.post(
            _OPENROUTER_URL,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "HTTP-Referer": _HTTP_REFERER,
                "X-Title": _X_TITLE,
            },
            json=payload,
            timeout=timeout,
        )
        response.raise_for_status()

    body: dict[str, Any] = response.json()

    usage = body.get("usage", {})
    prompt_tokens: int = usage.get("prompt_tokens", 0)
    completion_tokens: int = usage.get("completion_tokens", 0)
    total_tokens: int = usage.get("total_tokens", prompt_tokens + completion_tokens)

    cost_usd: float | None = None
    raw_cost = response.headers.get("x-openrouter-cost")
    if raw_cost is not None:
        try:
            cost_usd = float(raw_cost)
        except ValueError:
            # Malformed header — treat as absent (matches prior call-site behaviour).
            pass

    content: str = body["choices"][0]["message"]["content"]

    return ChatCompletionResult(
        content=content,
        cost_usd=cost_usd,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=total_tokens,
        raw=body,
    )
