"""Unit tests for benchmark runner argparse defaults.

These tests assert that DEFAULT_MODELS is exported and that the CLI produces
the correct default model list when --models is omitted.  They are pure unit
tests — no database, no network, no container required.
"""

from __future__ import annotations

EXPECTED_MODELS = [
    "openai/gpt-4o-mini",
    "anthropic/claude-haiku-4-5",
    "anthropic/claude-sonnet-4-6",
    "google/gemini-2.5-flash",
    "meta-llama/llama-3.3-70b-instruct",
]


def test_default_models_constant_exported() -> None:
    """DEFAULT_MODELS is a non-empty list of strings exported from the module."""
    from grove.benchmarks.runner import DEFAULT_MODELS

    assert isinstance(DEFAULT_MODELS, list)
    assert len(DEFAULT_MODELS) > 0
    for model in DEFAULT_MODELS:
        assert isinstance(model, str)
        assert "/" in model, f"Model ID {model!r} should be in provider/name format"


def test_default_models_constant_matches_expected() -> None:
    """DEFAULT_MODELS matches the canonical five-model sweep."""
    from grove.benchmarks.runner import DEFAULT_MODELS

    assert DEFAULT_MODELS == EXPECTED_MODELS


def test_argparse_models_default_when_omitted() -> None:
    """Parsing [] (no --models flag) produces the full DEFAULT_MODELS list."""
    from grove.benchmarks.runner import _build_arg_parser

    args = _build_arg_parser().parse_args([])
    parsed_models = [m.strip() for m in args.models.split(",") if m.strip()]
    assert parsed_models == EXPECTED_MODELS


def test_argparse_models_override() -> None:
    """Passing --models overrides the default."""
    from grove.benchmarks.runner import _build_arg_parser

    args = _build_arg_parser().parse_args(["--models", "openai/gpt-4o-mini,openai/gpt-4o"])
    parsed_models = [m.strip() for m in args.models.split(",") if m.strip()]
    assert parsed_models == ["openai/gpt-4o-mini", "openai/gpt-4o"]
