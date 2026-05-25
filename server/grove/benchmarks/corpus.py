"""Benchmark corpus loader.

Public API:
    load_enrichment_cases() -> list[dict]
    load_synthesis_cases() -> list[dict]
    load_intent_router_cases() -> list[dict]

Each loader globs all matching JSONL files from the corpus directory so
additional case files (e.g. enrichment_cases_real.jsonl) are picked up
without code changes.
"""

from __future__ import annotations

import json
from pathlib import Path

_CORPUS_DIR = Path(__file__).parent / "corpus"


def _load_jsonl_glob(pattern: str) -> list[dict]:
    """Load all JSONL files matching pattern and return a flat list of dicts."""
    cases: list[dict] = []
    for path in sorted(_CORPUS_DIR.glob(pattern)):
        with path.open() as fh:
            for line in fh:
                line = line.strip()
                if line:
                    cases.append(json.loads(line))
    return cases


def load_enrichment_cases(*, case_glob: str | None = None) -> list[dict]:
    """Load enrichment benchmark cases.

    Args:
        case_glob: Optional glob pattern for case_id filtering (matched via fnmatch
                   against each case's case_id field). None = load all.

    Returns:
        List of enrichment case dicts.
    """
    cases = _load_jsonl_glob("enrichment_cases*.jsonl")
    if case_glob:
        import fnmatch

        cases = [c for c in cases if fnmatch.fnmatch(c.get("case_id", ""), case_glob)]
    return cases


def load_synthesis_cases(*, case_glob: str | None = None) -> list[dict]:
    """Load synthesis benchmark cases.

    Args:
        case_glob: Optional glob pattern for case_id filtering.

    Returns:
        List of synthesis case dicts.
    """
    cases = _load_jsonl_glob("synthesis_cases*.jsonl")
    if case_glob:
        import fnmatch

        cases = [c for c in cases if fnmatch.fnmatch(c.get("case_id", ""), case_glob)]
    return cases


def load_intent_router_cases(*, case_glob: str | None = None) -> list[dict]:
    """Load intent-router benchmark cases.

    Args:
        case_glob: Optional glob pattern for case_id filtering.

    Returns:
        List of intent-router case dicts.
    """
    cases = _load_jsonl_glob("intent_router_cases*.jsonl")
    if case_glob:
        import fnmatch

        cases = [c for c in cases if fnmatch.fnmatch(c.get("case_id", ""), case_glob)]
    return cases
