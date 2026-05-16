"""RunReport — per-run enrichment telemetry accumulator (ticket #182).

Each worker invocation creates one RunReport, passes it into every
classify_and_write call as a keyword argument, and serialises it to
enrichment_state.notes (JSONB) at run end.

Usage
-----
    report = RunReport()

    # Inside classify_and_write stub or real orchestrator:
    report.record_accepted("decisions", confidence=0.85)
    report.record_dropped()
    report.record_error("boom: …")
    report.record_llm_usage(input_tokens=50, output_tokens=20, cost_usd=0.002)

    # At run end:
    data = report.to_dict()   # dict suitable for JSONB storage
"""

from __future__ import annotations

_ERROR_SAMPLE_CAP = 5
_VALID_TYPES = frozenset({"decisions", "people_interactions", "tasks", "appointments"})


class RunReport:
    """Mutable accumulator for a single enrichment worker run.

    Thread-safety note: asyncio is single-threaded; no locking needed.
    """

    def __init__(self) -> None:
        self._counts: dict[str, int] = {
            "decisions": 0,
            "people_interactions": 0,
            "tasks": 0,
            "appointments": 0,
        }
        self._dropped: int = 0
        self._error_count: int = 0
        self._error_samples: list[str] = []
        self._total_input_tokens: int = 0
        self._total_output_tokens: int = 0
        self._total_cost_usd: float = 0.0
        # Running sum and count for accepted confidences only.
        self._confidence_sum: float = 0.0
        self._confidence_n: int = 0

    # ------------------------------------------------------------------
    # Accumulation helpers
    # ------------------------------------------------------------------

    def record_accepted(self, memory_type: str, *, confidence: float) -> None:
        """Record one accepted extraction of *memory_type* with *confidence*.

        Only extractions that passed the ≥0.7 gate (i.e. actually written to a
        specialised table) should be recorded here.
        """
        if memory_type not in _VALID_TYPES:
            raise ValueError(f"unknown memory type {memory_type!r}; expected one of {_VALID_TYPES}")
        self._counts[memory_type] += 1
        self._confidence_sum += confidence
        self._confidence_n += 1

    def record_dropped(self) -> None:
        """Record one extraction that was dropped for low confidence."""
        self._dropped += 1

    def record_error(self, message: str) -> None:
        """Record a classification or writer error.

        Samples up to _ERROR_SAMPLE_CAP messages to bound memory usage on
        large batches with many failures.
        """
        self._error_count += 1
        if len(self._error_samples) < _ERROR_SAMPLE_CAP:
            self._error_samples.append(message)

    def record_llm_usage(
        self,
        *,
        input_tokens: int,
        output_tokens: int,
        cost_usd: float | None,
    ) -> None:
        """Add per-call LLM token counts and cost to the running totals."""
        self._total_input_tokens += input_tokens
        self._total_output_tokens += output_tokens
        if cost_usd is not None:
            self._total_cost_usd += cost_usd

    # ------------------------------------------------------------------
    # Serialisation
    # ------------------------------------------------------------------

    def to_dict(self) -> dict:  # type: ignore[type-arg]
        """Return a plain dict suitable for JSONB storage or structured logging."""
        avg_confidence = (
            self._confidence_sum / self._confidence_n if self._confidence_n > 0 else 0.0
        )
        return {
            "counts_by_type": dict(self._counts),
            "dropped_low_confidence": self._dropped,
            "average_confidence": avg_confidence,
            "error_count": self._error_count,
            "error_samples": list(self._error_samples),
            "total_input_tokens": self._total_input_tokens,
            "total_output_tokens": self._total_output_tokens,
            "total_cost_usd": self._total_cost_usd,
        }
