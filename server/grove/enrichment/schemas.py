"""Pydantic schemas for the enrichment classification pipeline.

These models mirror the SQLAlchemy specialized-table columns, excluding the
DB-managed fields (id, memory_id, enrichment_version, created_at) which the
writer step supplies from context. confidence is included because it is part
of the LLM's output contract.

The loader returns a PromptBundle assembled from the classify.v<N>.yaml file.
Bumping enrichment_version is the only way to trigger selective re-enrichment
(impl plan §4.3).
"""

from __future__ import annotations

import datetime
from pathlib import Path
from typing import Annotated, Any

import yaml
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Extraction schemas — one per specialized table
# ---------------------------------------------------------------------------

_Confidence = Annotated[float, Field(ge=0.0, le=1.0)]


class Decision(BaseModel):
    decision_maker: str | None = None
    context: str | None = None
    options: list[str] | None = None
    chosen_option: str | None = None
    rationale: str | None = None
    outcome: str | None = None
    outcome_date: datetime.date | None = None
    confidence: _Confidence


class PeopleInteraction(BaseModel):
    person_name: str
    interaction_medium: str | None = None
    topics: list[str] | None = None
    next_steps: list[str] | None = None
    confidence: _Confidence


class Task(BaseModel):
    description: str
    due_date: datetime.date | None = None
    status: str | None = None
    related_people: list[str] | None = None
    confidence: _Confidence


class Appointment(BaseModel):
    title: str | None = None
    starts_at: datetime.datetime | None = None
    ends_at: datetime.datetime | None = None
    location: str | None = None
    participants: list[str] | None = None
    confidence: _Confidence


# ---------------------------------------------------------------------------
# Top-level classification envelope
# ---------------------------------------------------------------------------


class Classification(BaseModel):
    """Container for all extractions from a single memory.

    A memory may produce 0..n extractions of each type; the classifier returns
    empty lists when nothing of that type is found.
    """

    decisions: list[Decision] = Field(default_factory=list)
    people_interactions: list[PeopleInteraction] = Field(default_factory=list)
    tasks: list[Task] = Field(default_factory=list)
    appointments: list[Appointment] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Prompt loader types
# ---------------------------------------------------------------------------


class TypeDefinition(BaseModel):
    definition: str
    examples: list[dict[str, Any]]
    fields: dict[str, Any]


class PromptBundle(BaseModel):
    enrichment_version: int
    system_prompt: str
    type_definitions: dict[str, TypeDefinition]


# ---------------------------------------------------------------------------
# Loader
# ---------------------------------------------------------------------------

_PROMPTS_DIR = Path(__file__).parent.parent.parent / "prompts"


def load_classification_prompts(version: int) -> PromptBundle:
    """Load the classify.v<version>.yaml file and return a PromptBundle.

    Raises ValueError for unknown versions (file not found).
    """
    path = _PROMPTS_DIR / f"classify.v{version}.yaml"
    if not path.exists():
        raise ValueError(f"unknown version {version}: {path} not found")

    with path.open() as fh:
        raw: dict[str, Any] = yaml.safe_load(fh)

    enrichment_version: int = raw["enrichment_version"]
    system_prompt: str = raw["system_prompt"]
    type_definitions: dict[str, TypeDefinition] = {
        name: TypeDefinition(**block) for name, block in raw["types"].items()
    }

    return PromptBundle(
        enrichment_version=enrichment_version,
        system_prompt=system_prompt,
        type_definitions=type_definitions,
    )
