"""RAG synthesis — compose a natural-language answer over retrieved memories.

Public API:
    synthesize(query, sources, prompt_path, *, api_key, model) -> SynthesisResult

The function takes a query string and a list of SourceItem dicts, calls
OpenRouter to compose an answer with inline [#memory_id] citations, and
returns the answer text alongside per-call telemetry.

Errors:
    Any httpx exception propagates unchanged. The caller is responsible for
    graceful degradation (answer=None) when synthesis fails.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import structlog
import yaml

logger = structlog.get_logger(__name__)

_OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
# Truncate each memory excerpt fed to the synthesis prompt.
# Long memories slow the model and inflate cost; the key signal is the snippet.
_EXCERPT_MAX_CHARS = 500

_DEFAULT_PROMPT_PATH = Path(__file__).parent.parent.parent / "prompts" / "synthesize.v1.yaml"


# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class SynthesisResult:
    """Composed answer plus per-call telemetry."""

    answer: str
    prompt_tokens: int
    completion_tokens: int
    # None when the x-openrouter-cost header is absent (some models omit it).
    cost_usd: float | None


# ---------------------------------------------------------------------------
# Prompt loading (cached per process — YAML files do not change at runtime)
# ---------------------------------------------------------------------------


_prompt_cache: dict[Path, dict[str, Any]] = {}


def _load_prompt(path: Path) -> dict[str, Any]:
    if path not in _prompt_cache:
        with path.open() as f:
            _prompt_cache[path] = yaml.safe_load(f)
    return _prompt_cache[path]


# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------


def _build_memories_block(sources: list[dict[str, Any]]) -> str:
    """Format the sources list into the memories block for the user prompt."""
    lines: list[str] = []
    for src in sources:
        mid = src["memory_id"]
        excerpt = src["excerpt"][:_EXCERPT_MAX_CHARS]
        lines.append(f"[#{mid}] {excerpt}")
    return "\n\n".join(lines)


def _build_messages(
    query: str,
    sources: list[dict[str, Any]],
    bundle: dict[str, Any],
) -> list[dict[str, str]]:
    memories_block = _build_memories_block(sources)
    user_content = bundle["user_prompt_template"].format(
        query=query,
        memories_block=memories_block,
    )
    return [
        {"role": "system", "content": bundle["system_prompt"]},
        {"role": "user", "content": user_content},
    ]


# ---------------------------------------------------------------------------
# Synthesizer
# ---------------------------------------------------------------------------


async def synthesize(
    query: str,
    sources: list[dict[str, Any]],
    *,
    api_key: str,
    model: str | None = None,
    prompt_path: Path | None = None,
) -> SynthesisResult:
    """Compose a natural-language answer over *sources* using OpenRouter.

    Args:
        query: The user's original query string.
        sources: List of source dicts — each must have at minimum ``memory_id``
            and ``excerpt`` keys. Additional keys (score, matched_via, etc.)
            are ignored.
        api_key: OpenRouter API key.
        model: OpenRouter model identifier; falls back to
            ``settings.synthesis_model``.
        prompt_path: Path to the synthesis prompt YAML; defaults to
            ``prompts/synthesize.v1.yaml``.

    Returns:
        SynthesisResult with the composed answer and telemetry.

    Raises:
        httpx.HTTPStatusError: 4xx/5xx from OpenRouter.
        httpx.RequestError: Network-level failures.
    """
    if model is None:
        from oracle.core.config import settings

        model = settings.synthesis_model

    if prompt_path is None:
        prompt_path = _DEFAULT_PROMPT_PATH

    bundle = _load_prompt(prompt_path)
    messages = _build_messages(query, sources, bundle)

    log = logger.bind(model=model, source_count=len(sources))
    log.info("synthesis.request.start")

    async with httpx.AsyncClient() as client:
        response = await client.post(
            _OPENROUTER_URL,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/markdlabrecque/the-oracle",
                "X-Title": "The Oracle",
            },
            json={
                "model": model,
                "messages": messages,
            },
            timeout=60.0,
        )
        response.raise_for_status()

    body: dict[str, Any] = response.json()

    usage = body.get("usage", {})
    prompt_tokens: int = usage.get("prompt_tokens", 0)
    completion_tokens: int = usage.get("completion_tokens", 0)

    cost_usd: float | None = None
    raw_cost = response.headers.get("x-openrouter-cost")
    if raw_cost is not None:
        try:
            cost_usd = float(raw_cost)
        except ValueError:
            pass  # malformed header — treat as absent

    answer: str = body["choices"][0]["message"]["content"]

    log.info(
        "synthesis.request.ok",
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        cost_usd=cost_usd,
    )

    return SynthesisResult(
        answer=answer,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        cost_usd=cost_usd,
    )
