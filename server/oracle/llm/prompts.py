"""Typed prompt loaders for LLM call-sites that live outside the enrichment pipeline.

Currently covers:
    SynthesisBundle / load_synthesis_prompts(version)  — RAG answer composition
    IntentBundle    / load_intent_prompts(version)      — query intent classification

Classification prompts (classify.v<N>.yaml) are loaded by
oracle.enrichment.schemas.load_classification_prompts, which owns the
enrichment_version / type_definitions schema.  Synthesis and intent prompts
have a different, simpler schema (system_prompt + user_prompt_template) that
doesn't belong in the enrichment namespace.

Each loader is decorated with @cache — YAML files do not
change at runtime so process-level caching is correct.  The cache is keyed on
the version integer; a fresh process picks up new YAML files automatically.
"""

from __future__ import annotations

from functools import cache
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel

_PROMPTS_DIR = Path(__file__).parent.parent.parent / "prompts"


# ---------------------------------------------------------------------------
# Synthesis prompts
# ---------------------------------------------------------------------------


class SynthesisBundle(BaseModel):
    """Validated bundle loaded from synthesize.v<N>.yaml."""

    version: int
    system_prompt: str
    user_prompt_template: str


@cache
def load_synthesis_prompts(version: int) -> SynthesisBundle:
    """Load and validate synthesize.v<version>.yaml.

    Returns a SynthesisBundle on success.

    Raises:
        ValueError:              File not found (unknown version).
        pydantic.ValidationError: YAML structure does not match SynthesisBundle.
    """
    path = _PROMPTS_DIR / f"synthesize.v{version}.yaml"
    if not path.exists():
        raise ValueError(f"unknown version {version}: {path} not found")

    raw: dict[str, Any] = yaml.safe_load(path.read_text())
    return SynthesisBundle.model_validate(raw)


# ---------------------------------------------------------------------------
# Intent prompts
# ---------------------------------------------------------------------------


class IntentBundle(BaseModel):
    """Validated bundle loaded from intent.v<N>.yaml."""

    version: int
    system_prompt: str
    user_prompt_template: str


@cache
def load_intent_prompts(version: int) -> IntentBundle:
    """Load and validate intent.v<version>.yaml.

    Returns an IntentBundle on success.

    Raises:
        ValueError:              File not found (unknown version).
        pydantic.ValidationError: YAML structure does not match IntentBundle.
    """
    path = _PROMPTS_DIR / f"intent.v{version}.yaml"
    if not path.exists():
        raise ValueError(f"unknown version {version}: {path} not found")

    raw: dict[str, Any] = yaml.safe_load(path.read_text())
    return IntentBundle.model_validate(raw)
