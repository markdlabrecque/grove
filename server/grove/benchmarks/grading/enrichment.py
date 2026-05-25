"""Programmatic grader for the enrichment (classification) workflow.

Public API:
    grade_enrichment(case, classification_output) -> EnrichmentGradeResult

Grading logic:
- memory_type: case expects one of "decisions", "people_interactions", "appointments"
  — model output is considered the right type when the corresponding list is non-empty.
- Field matching: case provides expected_fields dict; each field value is normalized
  (lowercase + whitespace collapse) before string comparison.
- Missing fields: expected fields absent from model output.
- Extra fields: non-None, non-confidence model output fields not in expected.
- Confidence range: case provides expected_confidence_min/max; model's first extraction
  confidence is checked against the range.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class EnrichmentGradeResult:
    """Result of grading one enrichment case against one model output."""

    correct: bool
    field_matches: dict[str, bool]
    extra_fields: list[str]
    missing_fields: list[str]
    confidence_in_range: bool


_TYPE_TO_KEY = {
    "decisions": "decisions",
    "people_interactions": "people_interactions",
    "appointments": "appointments",
}

# Fields that are structural (not content) — excluded from extra_fields reporting.
_META_FIELDS = frozenset({"confidence"})


def _normalize(value: object) -> str:
    """Lowercase + collapse internal whitespace for string comparison."""
    if value is None:
        return ""
    return " ".join(str(value).lower().split())


def grade_enrichment(
    case: dict,
    classification_output: dict,
) -> EnrichmentGradeResult:
    """Grade a classification output against the expected case schema.

    Args:
        case: Dict with keys:
            case_id, content, expected_memory_type, expected_fields,
            expected_confidence_min (float), expected_confidence_max (float).
        classification_output: Dict with keys:
            decisions (list), people_interactions (list), appointments (list).
            Each extraction dict may include a confidence float.

    Returns:
        EnrichmentGradeResult.
    """
    expected_type: str = case["expected_memory_type"]
    expected_fields: dict = case.get("expected_fields", {})
    conf_min: float = case.get("expected_confidence_min", 0.0)
    conf_max: float = case.get("expected_confidence_max", 1.0)

    key = _TYPE_TO_KEY.get(expected_type)
    extractions: list[dict] = classification_output.get(key or "", []) if key else []

    # Type correct when at least one extraction of the expected type exists.
    type_correct = len(extractions) > 0

    if not type_correct:
        # Nothing to field-match; all expected fields are missing.
        return EnrichmentGradeResult(
            correct=False,
            field_matches={},
            extra_fields=[],
            missing_fields=list(expected_fields.keys()),
            confidence_in_range=False,
        )

    # Use the first extraction for field matching and confidence.
    extraction = extractions[0]

    field_matches: dict[str, bool] = {}
    missing_fields: list[str] = []

    for exp_field, exp_value in expected_fields.items():
        actual_value = extraction.get(exp_field)
        if actual_value is None:
            missing_fields.append(exp_field)
            field_matches[exp_field] = False
        else:
            field_matches[exp_field] = _normalize(actual_value) == _normalize(exp_value)

    # Extra fields: non-None extraction fields not in expected, excluding meta fields.
    extra_fields: list[str] = [
        f
        for f, v in extraction.items()
        if f not in expected_fields and f not in _META_FIELDS and v is not None
    ]

    # Confidence check.
    confidence: float | None = extraction.get("confidence")
    if confidence is not None:
        confidence_in_range = conf_min <= confidence <= conf_max
    else:
        confidence_in_range = True  # No confidence field — treat as unconstrained.

    # Overall correctness: type right + all expected fields matched.
    all_fields_match = all(field_matches.values()) if field_matches else True
    correct = type_correct and all_fields_match

    return EnrichmentGradeResult(
        correct=correct,
        field_matches=field_matches,
        extra_fields=extra_fields,
        missing_fields=missing_fields,
        confidence_in_range=confidence_in_range,
    )
