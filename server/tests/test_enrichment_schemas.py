"""Unit tests for oracle.enrichment.schemas and the classify.v1.yaml loader.

TDD red commit — these tests fail until the implementation is in place.

Coverage:
- Each Pydantic model validates a representative few-shot payload.
- Classification top-level model accepts mixed-type lists and empty lists.
- load_classification_prompts returns a PromptBundle for version 1.
- load_classification_prompts raises ValueError for an unknown version.
- Field shapes on the Pydantic models match the SQLAlchemy model columns
  (cross-checked by introspecting both).
"""

from __future__ import annotations

import datetime

import pytest

from oracle.enrichment.schemas import (
    Appointment,
    Classification,
    Decision,
    PeopleInteraction,
    PromptBundle,
    Task,
    load_classification_prompts,
)

# ---------------------------------------------------------------------------
# Decision
# ---------------------------------------------------------------------------


def test_decision_valid_full():
    d = Decision(
        decision_maker="Mark",
        context="Choosing a cloud provider for the API.",
        options=["AWS", "Hetzner", "Fly.io"],
        chosen_option="Hetzner",
        rationale="Better price-performance for a personal project.",
        outcome=None,
        outcome_date=None,
        confidence=0.91,
    )
    assert d.chosen_option == "Hetzner"
    assert d.options == ["AWS", "Hetzner", "Fly.io"]
    assert d.confidence == pytest.approx(0.91)


def test_decision_minimal():
    """All nullable fields absent; only confidence required."""
    d = Decision(confidence=0.5)
    assert d.decision_maker is None
    assert d.options is None
    assert d.outcome_date is None


def test_decision_rejects_confidence_out_of_range():
    with pytest.raises(ValueError):
        Decision(confidence=1.5)

    with pytest.raises(ValueError):
        Decision(confidence=-0.1)


# ---------------------------------------------------------------------------
# PeopleInteraction
# ---------------------------------------------------------------------------


def test_people_interaction_valid():
    pi = PeopleInteraction(
        person_name="Alice",
        interaction_medium="in-person",
        topics=["Q3 roadmap", "hiring plan"],
        next_steps=["Send RFC draft"],
        confidence=0.88,
    )
    assert pi.person_name == "Alice"
    assert pi.topics == ["Q3 roadmap", "hiring plan"]


def test_people_interaction_requires_person_name():
    with pytest.raises(ValueError):
        PeopleInteraction(confidence=0.7)


def test_people_interaction_nullable_fields():
    pi = PeopleInteraction(person_name="Bob", confidence=0.6)
    assert pi.interaction_medium is None
    assert pi.topics is None
    assert pi.next_steps is None


# ---------------------------------------------------------------------------
# Task
# ---------------------------------------------------------------------------


def test_task_valid():
    t = Task(
        description="Send Alice the OAuth2 RFC draft",
        due_date=datetime.date(2026, 6, 15),
        status="open",
        related_people=["Alice"],
        confidence=0.95,
    )
    assert t.description == "Send Alice the OAuth2 RFC draft"
    assert t.due_date == datetime.date(2026, 6, 15)


def test_task_requires_description():
    with pytest.raises(ValueError):
        Task(confidence=0.8)


def test_task_nullable_fields():
    t = Task(description="Follow up with vendor", confidence=0.7)
    assert t.due_date is None
    assert t.status is None
    assert t.related_people is None


# ---------------------------------------------------------------------------
# Appointment
# ---------------------------------------------------------------------------


def test_appointment_valid():
    a = Appointment(
        title="Quarterly review",
        starts_at=datetime.datetime(2026, 7, 1, 10, 0, tzinfo=datetime.UTC),
        ends_at=datetime.datetime(2026, 7, 1, 11, 0, tzinfo=datetime.UTC),
        location="Conference room B",
        participants=["Alice", "Mark"],
        confidence=0.82,
    )
    assert a.title == "Quarterly review"
    assert a.participants == ["Alice", "Mark"]


def test_appointment_all_nullable():
    a = Appointment(confidence=0.6)
    assert a.title is None
    assert a.starts_at is None
    assert a.ends_at is None
    assert a.location is None
    assert a.participants is None


# ---------------------------------------------------------------------------
# Classification top-level model
# ---------------------------------------------------------------------------


def test_classification_empty():
    c = Classification()
    assert c.decisions == []
    assert c.people_interactions == []
    assert c.tasks == []
    assert c.appointments == []


def test_classification_mixed():
    c = Classification(
        decisions=[Decision(confidence=0.9)],
        tasks=[Task(description="Review RFC", confidence=0.8)],
    )
    assert len(c.decisions) == 1
    assert len(c.tasks) == 1
    assert c.people_interactions == []
    assert c.appointments == []


# ---------------------------------------------------------------------------
# Loader
# ---------------------------------------------------------------------------


def test_load_classification_prompts_v1():
    bundle = load_classification_prompts(version=1)
    assert isinstance(bundle, PromptBundle)
    assert bundle.enrichment_version == 1
    assert bundle.system_prompt
    # Each type should have a non-empty definition in the bundle
    for type_name in ("decisions", "people_interactions", "tasks", "appointments"):
        assert type_name in bundle.type_definitions
        defn = bundle.type_definitions[type_name]
        assert defn.definition
        assert len(defn.examples) >= 2


def test_load_classification_prompts_unknown_version():
    with pytest.raises(ValueError, match="unknown version"):
        load_classification_prompts(version=99)


# ---------------------------------------------------------------------------
# Schema/column shape parity
# ---------------------------------------------------------------------------


def test_decision_pydantic_fields_match_sqlalchemy():
    """Pydantic Decision has every nullable column from the decisions table
    (excluding DB-managed fields: id, memory_id, enrichment_version, created_at).
    """
    from oracle.models.decision import Decision as SADecision

    sa_cols = {c.key for c in SADecision.__table__.columns}
    # Strip the DB-managed / FK columns from what we expect Pydantic to cover.
    db_managed = {"id", "memory_id", "enrichment_version", "created_at"}
    expected = sa_cols - db_managed

    pydantic_fields = set(Decision.model_fields.keys())
    # confidence is present in both
    assert expected == pydantic_fields, (
        f"Mismatch — SA columns not in Pydantic: {expected - pydantic_fields}; "
        f"Pydantic fields not in SA: {pydantic_fields - expected}"
    )


def test_people_interaction_pydantic_fields_match_sqlalchemy():
    from oracle.models.people_interaction import PeopleInteraction as SAPeopleInteraction

    sa_cols = {c.key for c in SAPeopleInteraction.__table__.columns}
    db_managed = {"id", "memory_id", "enrichment_version", "created_at"}
    expected = sa_cols - db_managed

    pydantic_fields = set(PeopleInteraction.model_fields.keys())
    assert expected == pydantic_fields, (
        f"Mismatch — SA columns not in Pydantic: {expected - pydantic_fields}; "
        f"Pydantic fields not in SA: {pydantic_fields - expected}"
    )


def test_task_pydantic_fields_match_sqlalchemy():
    from oracle.models.task import Task as SATask

    sa_cols = {c.key for c in SATask.__table__.columns}
    db_managed = {"id", "memory_id", "enrichment_version", "created_at"}
    expected = sa_cols - db_managed

    pydantic_fields = set(Task.model_fields.keys())
    assert expected == pydantic_fields, (
        f"Mismatch — SA columns not in Pydantic: {expected - pydantic_fields}; "
        f"Pydantic fields not in SA: {pydantic_fields - expected}"
    )


def test_appointment_pydantic_fields_match_sqlalchemy():
    from oracle.models.appointment import Appointment as SAAppointment

    sa_cols = {c.key for c in SAAppointment.__table__.columns}
    db_managed = {"id", "memory_id", "enrichment_version", "created_at"}
    expected = sa_cols - db_managed

    pydantic_fields = set(Appointment.model_fields.keys())
    assert expected == pydantic_fields, (
        f"Mismatch — SA columns not in Pydantic: {expected - pydantic_fields}; "
        f"Pydantic fields not in SA: {pydantic_fields - expected}"
    )
