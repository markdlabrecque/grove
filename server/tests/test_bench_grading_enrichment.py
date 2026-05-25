"""Tests for the programmatic enrichment grader — ticket #502.

TDD red commit: these tests are written before the implementation exists.

Coverage:
- Exact match on memory_type
- Per-field match on specialized-table fields (string normalization)
- Missing fields detected
- Extra fields detected
- Multiple extractions per memory type
- Confidence range validation
"""

from __future__ import annotations

from grove.benchmarks.grading.enrichment import grade_enrichment

# ---------------------------------------------------------------------------
# Fixtures — minimal case/result shapes
# ---------------------------------------------------------------------------


def _make_case(
    *,
    memory_type: str,
    expected_fields: dict,
    expected_confidence_min: float = 0.0,
    expected_confidence_max: float = 1.0,
) -> dict:
    return {
        "case_id": "test-001",
        "content": "some memory content",
        "expected_memory_type": memory_type,
        "expected_fields": expected_fields,
        "expected_confidence_min": expected_confidence_min,
        "expected_confidence_max": expected_confidence_max,
    }


def _make_classification_output(
    *,
    decisions: list[dict] | None = None,
    people_interactions: list[dict] | None = None,
    appointments: list[dict] | None = None,
) -> dict:
    return {
        "decisions": decisions or [],
        "people_interactions": people_interactions or [],
        "appointments": appointments or [],
    }


# ---------------------------------------------------------------------------
# memory_type detection
# ---------------------------------------------------------------------------


def test_correct_memory_type_decision():
    """Grade is correct=True when model outputs a decision and case expects decisions."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "Alice", "chosen_option": "PostgreSQL"},
    )
    output = _make_classification_output(
        decisions=[{"decision_maker": "Alice", "chosen_option": "PostgreSQL", "confidence": 0.9}]
    )
    result = grade_enrichment(case, output)
    assert result.correct is True


def test_wrong_memory_type():
    """Grade is correct=False when model outputs wrong type.

    Pins the early-return contract: all expected fields appear in missing_fields
    and field_matches is empty (no field comparison attempted).
    """
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "Alice"},
    )
    # Model produced a people_interaction instead of a decision
    output = _make_classification_output(
        people_interactions=[{"person_name": "Alice", "confidence": 0.8}]
    )
    result = grade_enrichment(case, output)
    assert result.correct is False
    # Early-return contract: no field comparison is attempted on a type mismatch.
    assert result.field_matches == {}
    # Every expected field is reported missing.
    assert set(result.missing_fields) == {"decision_maker"}


def test_empty_output_wrong():
    """Grade is correct=False when model produces no extractions."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "Alice"},
    )
    output = _make_classification_output()
    result = grade_enrichment(case, output)
    assert result.correct is False


# ---------------------------------------------------------------------------
# Field matching — string normalization
# ---------------------------------------------------------------------------


def test_field_match_case_insensitive():
    """Field matching should normalize case."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "alice smith"},
    )
    output = _make_classification_output(
        decisions=[{"decision_maker": "Alice Smith", "confidence": 0.9}]
    )
    result = grade_enrichment(case, output)
    assert "decision_maker" in result.field_matches
    assert result.field_matches["decision_maker"] is True


def test_field_match_whitespace_normalization():
    """Field matching should normalize extra whitespace."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"chosen_option": "use postgres"},
    )
    output = _make_classification_output(
        decisions=[{"chosen_option": "  Use  Postgres  ", "confidence": 0.9}]
    )
    result = grade_enrichment(case, output)
    assert result.field_matches["chosen_option"] is True


def test_field_mismatch_detected():
    """Field mismatch is captured in field_matches."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"chosen_option": "PostgreSQL"},
    )
    output = _make_classification_output(decisions=[{"chosen_option": "MySQL", "confidence": 0.9}])
    result = grade_enrichment(case, output)
    assert result.field_matches["chosen_option"] is False
    assert result.correct is False


# ---------------------------------------------------------------------------
# Missing / extra fields
# ---------------------------------------------------------------------------


def test_missing_fields_reported():
    """Fields in expected_fields that aren't in model output are reported."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "Alice", "chosen_option": "Postgres"},
    )
    # Model only returns decision_maker
    output = _make_classification_output(decisions=[{"decision_maker": "Alice", "confidence": 0.9}])
    result = grade_enrichment(case, output)
    assert "chosen_option" in result.missing_fields


def test_extra_fields_reported():
    """Fields in model output that aren't expected are reported as extra."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "Alice"},
    )
    output = _make_classification_output(
        decisions=[
            {
                "decision_maker": "Alice",
                "chosen_option": "Postgres",
                "rationale": "It scales",
                "confidence": 0.9,
            }
        ]
    )
    result = grade_enrichment(case, output)
    # chosen_option and rationale are extra (not in expected)
    assert "chosen_option" in result.extra_fields or "rationale" in result.extra_fields


# ---------------------------------------------------------------------------
# Confidence range
# ---------------------------------------------------------------------------


def test_confidence_in_range_passes():
    """Confidence within expected range is not flagged."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "Alice"},
        expected_confidence_min=0.7,
        expected_confidence_max=1.0,
    )
    output = _make_classification_output(
        decisions=[{"decision_maker": "Alice", "confidence": 0.85}]
    )
    result = grade_enrichment(case, output)
    assert result.confidence_in_range is True


def test_confidence_out_of_range_flagged():
    """Confidence below expected min is flagged."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "Alice"},
        expected_confidence_min=0.8,
        expected_confidence_max=1.0,
    )
    output = _make_classification_output(decisions=[{"decision_maker": "Alice", "confidence": 0.4}])
    result = grade_enrichment(case, output)
    assert result.confidence_in_range is False


# ---------------------------------------------------------------------------
# People interactions
# ---------------------------------------------------------------------------


def test_people_interaction_graded():
    """People-interaction type is graded correctly."""
    case = _make_case(
        memory_type="people_interactions",
        expected_fields={"person_name": "Bob"},
    )
    output = _make_classification_output(
        people_interactions=[{"person_name": "Bob", "confidence": 0.9}]
    )
    result = grade_enrichment(case, output)
    assert result.correct is True
    assert result.field_matches["person_name"] is True


# ---------------------------------------------------------------------------
# Return type shape
# ---------------------------------------------------------------------------


def test_grade_result_has_required_keys():
    """GradeResult dataclass exposes required fields."""
    case = _make_case(
        memory_type="decisions",
        expected_fields={"decision_maker": "Alice"},
    )
    output = _make_classification_output(decisions=[{"decision_maker": "Alice", "confidence": 0.9}])
    result = grade_enrichment(case, output)
    assert hasattr(result, "correct")
    assert hasattr(result, "field_matches")
    assert hasattr(result, "extra_fields")
    assert hasattr(result, "missing_fields")
    assert hasattr(result, "confidence_in_range")
