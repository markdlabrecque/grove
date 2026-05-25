"""Tests for the programmatic intent-router grader — ticket #502.

TDD red commit: these tests are written before the implementation exists.

Coverage:
- Set-equality on table selection
- Exact match on intent label
- Partial matches
- Empty intents
"""

from __future__ import annotations

import pytest

from grove.benchmarks.grading.intent_router import grade_intent_router


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_case(
    *,
    expected_tables: list[str],
    expected_intent: str,
    query: str = "test query",
) -> dict:
    return {
        "case_id": "intent-test-001",
        "query": query,
        "expected_tables": expected_tables,
        "expected_intent": expected_intent,
    }


def _make_router_output(
    *,
    intents: list[str],
) -> dict:
    return {"intents": intents}


# ---------------------------------------------------------------------------
# Table selection (set equality)
# ---------------------------------------------------------------------------


def test_exact_table_match():
    """Exact set match on tables is correct."""
    case = _make_case(expected_tables=["decisions"], expected_intent="decisions")
    output = _make_router_output(intents=["decisions"])
    result = grade_intent_router(case, output)
    assert result.tables_correct is True


def test_table_mismatch():
    """Different table is not correct."""
    case = _make_case(expected_tables=["decisions"], expected_intent="decisions")
    output = _make_router_output(intents=["people_interactions"])
    result = grade_intent_router(case, output)
    assert result.tables_correct is False


def test_multi_table_exact_match():
    """Multiple-table set equality works."""
    case = _make_case(
        expected_tables=["decisions", "people_interactions"],
        expected_intent="decisions",
    )
    output = _make_router_output(intents=["people_interactions", "decisions"])
    result = grade_intent_router(case, output)
    assert result.tables_correct is True


def test_multi_table_partial_match_is_wrong():
    """Partial table match (missing one table) is incorrect."""
    case = _make_case(
        expected_tables=["decisions", "people_interactions"],
        expected_intent="decisions",
    )
    output = _make_router_output(intents=["decisions"])
    result = grade_intent_router(case, output)
    assert result.tables_correct is False


def test_extra_table_is_wrong():
    """Extra table beyond expected is incorrect."""
    case = _make_case(expected_tables=["decisions"], expected_intent="decisions")
    output = _make_router_output(intents=["decisions", "appointments"])
    result = grade_intent_router(case, output)
    assert result.tables_correct is False


def test_general_intent_exact():
    """General intent (no specialized tables) is correctly matched."""
    case = _make_case(expected_tables=["general"], expected_intent="general")
    output = _make_router_output(intents=["general"])
    result = grade_intent_router(case, output)
    assert result.tables_correct is True


def test_empty_output_wrong():
    """Empty intents list is wrong when decisions expected."""
    case = _make_case(expected_tables=["decisions"], expected_intent="decisions")
    output = _make_router_output(intents=[])
    result = grade_intent_router(case, output)
    assert result.tables_correct is False


# ---------------------------------------------------------------------------
# Intent label (primary)
# ---------------------------------------------------------------------------


def test_intent_label_matches():
    """Intent label exact match sets intent_correct=True."""
    case = _make_case(expected_tables=["decisions"], expected_intent="decisions")
    output = _make_router_output(intents=["decisions"])
    result = grade_intent_router(case, output)
    assert result.intent_correct is True


def test_intent_label_mismatch():
    """Wrong primary intent sets intent_correct=False."""
    case = _make_case(expected_tables=["decisions"], expected_intent="decisions")
    output = _make_router_output(intents=["appointments"])
    result = grade_intent_router(case, output)
    assert result.intent_correct is False


# ---------------------------------------------------------------------------
# Combined correctness
# ---------------------------------------------------------------------------


def test_correct_only_when_both_match():
    """Overall correct requires both tables_correct and intent_correct."""
    case = _make_case(expected_tables=["decisions"], expected_intent="decisions")
    output = _make_router_output(intents=["decisions"])
    result = grade_intent_router(case, output)
    assert result.correct is True


def test_incorrect_when_tables_wrong():
    """correct is False even when intent label matches but tables don't."""
    case = _make_case(
        expected_tables=["decisions", "people_interactions"],
        expected_intent="decisions",
    )
    # Tables wrong (missing people_interactions), intent label right
    output = _make_router_output(intents=["decisions"])
    result = grade_intent_router(case, output)
    assert result.correct is False


# ---------------------------------------------------------------------------
# Return type shape
# ---------------------------------------------------------------------------


def test_grade_result_has_required_keys():
    """GradeResult exposes required fields."""
    case = _make_case(expected_tables=["decisions"], expected_intent="decisions")
    output = _make_router_output(intents=["decisions"])
    result = grade_intent_router(case, output)
    assert hasattr(result, "correct")
    assert hasattr(result, "tables_correct")
    assert hasattr(result, "intent_correct")
    assert hasattr(result, "predicted_tables")
    assert hasattr(result, "expected_tables")
