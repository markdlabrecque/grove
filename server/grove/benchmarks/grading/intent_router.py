"""Programmatic grader for the intent-router workflow.

Public API:
    grade_intent_router(case, router_output) -> IntentRouterGradeResult

Grading logic:
- Table selection: set-equality between expected_tables and predicted intents.
- Intent label: expected_intent must appear in the predicted intents list.
- Overall correct: both table selection and intent label are correct.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class IntentRouterGradeResult:
    """Result of grading one intent-router case against one model output."""

    correct: bool
    tables_correct: bool
    intent_correct: bool
    predicted_tables: list[str]
    expected_tables: list[str]


def grade_intent_router(
    case: dict,
    router_output: dict,
) -> IntentRouterGradeResult:
    """Grade an intent-router output against the expected case schema.

    Args:
        case: Dict with keys:
            case_id, query, expected_tables (list[str]), expected_intent (str).
        router_output: Dict with key:
            intents (list[str]) — the model's predicted intent list.

    Returns:
        IntentRouterGradeResult.
    """
    expected_tables: list[str] = case.get("expected_tables", [])
    expected_intent: str = case.get("expected_intent", "general")
    predicted: list[str] = router_output.get("intents", [])

    tables_correct = set(predicted) == set(expected_tables)
    intent_correct = expected_intent in predicted

    return IntentRouterGradeResult(
        correct=tables_correct and intent_correct,
        tables_correct=tables_correct,
        intent_correct=intent_correct,
        predicted_tables=predicted,
        expected_tables=expected_tables,
    )
