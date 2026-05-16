"""Unit tests for oracle.llm.prompts typed prompt loaders.

Coverage:
  - load_synthesis_prompts: valid YAML → SynthesisBundle with expected fields.
  - load_synthesis_prompts: missing file → ValueError with clear message.
  - load_synthesis_prompts: schema violation → pydantic.ValidationError.
  - load_intent_prompts: valid YAML → IntentBundle with expected fields.
  - load_intent_prompts: missing file → ValueError with clear message.
  - Cache: repeated calls return the same object (lru_cache).
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from pydantic import ValidationError

from oracle.llm.prompts import (
    IntentBundle,
    SynthesisBundle,
    load_intent_prompts,
    load_synthesis_prompts,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_yaml(path: Path, data: dict) -> None:
    path.write_text(yaml.dump(data))


# ---------------------------------------------------------------------------
# load_synthesis_prompts — valid YAML
# ---------------------------------------------------------------------------


class TestLoadSynthesisPromptsValid:
    def test_returns_synthesis_bundle(self) -> None:
        result = load_synthesis_prompts(1)
        assert isinstance(result, SynthesisBundle)

    def test_version_field(self) -> None:
        result = load_synthesis_prompts(1)
        assert result.version == 1

    def test_system_prompt_is_non_empty_string(self) -> None:
        result = load_synthesis_prompts(1)
        assert isinstance(result.system_prompt, str)
        assert len(result.system_prompt) > 0

    def test_user_prompt_template_contains_placeholders(self) -> None:
        """The v1 template has {query} and {memories_block} placeholders."""
        result = load_synthesis_prompts(1)
        assert "{query}" in result.user_prompt_template
        assert "{memories_block}" in result.user_prompt_template

    def test_caches_result(self) -> None:
        """Repeated calls return the same object (lru_cache, not just equal)."""
        a = load_synthesis_prompts(1)
        b = load_synthesis_prompts(1)
        assert a is b


# ---------------------------------------------------------------------------
# load_synthesis_prompts — missing file
# ---------------------------------------------------------------------------


class TestLoadSynthesisPromptsMissing:
    def test_unknown_version_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="unknown version"):
            load_synthesis_prompts(9999)

    def test_error_message_contains_version(self) -> None:
        with pytest.raises(ValueError, match="9999"):
            load_synthesis_prompts(9999)


# ---------------------------------------------------------------------------
# load_synthesis_prompts — schema violation
# ---------------------------------------------------------------------------


class TestLoadSynthesisPromptsSchemaViolation:
    def test_schema_violation_raises_validation_error(self, tmp_path: Path, monkeypatch) -> None:
        """YAML missing required fields raises pydantic.ValidationError."""
        import oracle.llm.prompts as prompts_module

        # Write a YAML that omits the required 'system_prompt' field.
        bad_yaml = tmp_path / "synthesize.v42.yaml"
        _write_yaml(bad_yaml, {"version": 42, "user_prompt_template": "hello"})

        # Redirect _PROMPTS_DIR so the loader finds our temp file.
        monkeypatch.setattr(prompts_module, "_PROMPTS_DIR", tmp_path)
        # Clear the cache so the monkeypatched dir is used.
        load_synthesis_prompts.cache_clear()

        try:
            with pytest.raises(ValidationError):
                load_synthesis_prompts(42)
        finally:
            load_synthesis_prompts.cache_clear()


# ---------------------------------------------------------------------------
# load_intent_prompts — valid YAML
# ---------------------------------------------------------------------------


class TestLoadIntentPromptsValid:
    def test_returns_intent_bundle(self) -> None:
        result = load_intent_prompts(1)
        assert isinstance(result, IntentBundle)

    def test_version_field(self) -> None:
        result = load_intent_prompts(1)
        assert result.version == 1

    def test_system_prompt_is_non_empty_string(self) -> None:
        result = load_intent_prompts(1)
        assert isinstance(result.system_prompt, str)
        assert len(result.system_prompt) > 0

    def test_user_prompt_template_contains_query_placeholder(self) -> None:
        """The v1 intent template has a {query} placeholder."""
        result = load_intent_prompts(1)
        assert "{query}" in result.user_prompt_template

    def test_caches_result(self) -> None:
        """Repeated calls return the same object (lru_cache, not just equal)."""
        a = load_intent_prompts(1)
        b = load_intent_prompts(1)
        assert a is b


# ---------------------------------------------------------------------------
# load_intent_prompts — missing file
# ---------------------------------------------------------------------------


class TestLoadIntentPromptsMissing:
    def test_unknown_version_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="unknown version"):
            load_intent_prompts(9999)

    def test_error_message_contains_version(self) -> None:
        with pytest.raises(ValueError, match="9999"):
            load_intent_prompts(9999)


# ---------------------------------------------------------------------------
# load_intent_prompts — schema violation
# ---------------------------------------------------------------------------


class TestLoadIntentPromptsSchemaViolation:
    def test_schema_violation_raises_validation_error(self, tmp_path: Path, monkeypatch) -> None:
        """YAML missing required fields raises pydantic.ValidationError."""
        import oracle.llm.prompts as prompts_module

        bad_yaml = tmp_path / "intent.v42.yaml"
        _write_yaml(bad_yaml, {"version": 42, "user_prompt_template": "hello"})

        monkeypatch.setattr(prompts_module, "_PROMPTS_DIR", tmp_path)
        load_intent_prompts.cache_clear()

        try:
            with pytest.raises(ValidationError):
                load_intent_prompts(42)
        finally:
            load_intent_prompts.cache_clear()
