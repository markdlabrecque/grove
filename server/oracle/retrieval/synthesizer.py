"""RAG synthesis — compose a natural-language answer over retrieved memories.

Public API:
    synthesize(query, sources, *, api_key, model, synthesis_version) -> SynthesisResult

The function takes a query string and a list of SourceItem dicts, calls
OpenRouter to compose an answer with inline [#memory_id] citations, and
returns the answer text alongside per-call telemetry.

Errors:
    Any httpx exception propagates unchanged. The caller is responsible for
    graceful degradation (answer=None) when synthesis fails.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import structlog

from oracle.llm.openrouter import chat_completion
from oracle.llm.prompts import SynthesisBundle, load_synthesis_prompts

logger = structlog.get_logger(__name__)

# Truncate each memory excerpt fed to the synthesis prompt.
# Long memories slow the model and inflate cost; the key signal is the snippet.
_EXCERPT_MAX_CHARS = 500

_DEFAULT_SYNTHESIS_VERSION = 1


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
    bundle: SynthesisBundle,
) -> list[dict[str, str]]:
    memories_block = _build_memories_block(sources)
    user_content = bundle.user_prompt_template.format(
        query=query,
        memories_block=memories_block,
    )
    return [
        {"role": "system", "content": bundle.system_prompt},
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
    synthesis_version: int = _DEFAULT_SYNTHESIS_VERSION,
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
        synthesis_version: Prompt version to load (defaults to 1).  Pass a
            different integer to load an alternate synthesize.v<N>.yaml file.

    Returns:
        SynthesisResult with the composed answer and telemetry.

    Raises:
        httpx.HTTPStatusError: 4xx/5xx from OpenRouter.
        httpx.RequestError: Network-level failures.
    """
    if model is None:
        from oracle.core.config import settings

        model = settings.synthesis_model

    bundle = load_synthesis_prompts(synthesis_version)
    messages = _build_messages(query, sources, bundle)

    log = logger.bind(model=model, source_count=len(sources))
    log.info("synthesis.request.start")

    completion = await chat_completion(
        api_key=api_key,
        model=model,
        messages=messages,
        timeout=60.0,
    )

    log.info(
        "synthesis.request.ok",
        prompt_tokens=completion.prompt_tokens,
        completion_tokens=completion.completion_tokens,
        cost_usd=completion.cost_usd,
    )

    return SynthesisResult(
        answer=completion.content,
        prompt_tokens=completion.prompt_tokens,
        completion_tokens=completion.completion_tokens,
        cost_usd=completion.cost_usd,
    )
