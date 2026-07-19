"""Benchmark corpus loader.

Public API:
    load_enrichment_cases() -> list[dict]
    load_synthesis_cases() -> list[dict]
    load_intent_router_cases() -> list[dict]
    load_retrieval_corpus() -> list[dict]
    load_retrieval_cases() -> list[dict]

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


def load_retrieval_corpus() -> list[dict]:
    """Load the retrieval benchmark's searchable memory pool.

    Returns:
        List of dicts with keys: memory_id, content. This is the document
        pool that queries are ranked against — distinct from the labelled
        cases returned by load_retrieval_cases().

    Raises:
        ValueError: The corpus contains a repeated memory_id. The corpus is
                    hand-curated, so a duplicate is a data-integrity bug, not
                    something to silently collapse — evaluate_embedder builds
                    its doc-vector map via dict(zip(...)), which would drop
                    one document's embedding without warning and produce a
                    wrong-but-confident eval score. Fail fast at load time
                    instead.
    """
    corpus = _load_jsonl_glob("retrieval_corpus*.jsonl")
    seen: set[str] = set()
    duplicates: set[str] = set()
    for doc in corpus:
        memory_id = doc["memory_id"]
        if memory_id in seen:
            duplicates.add(memory_id)
        seen.add(memory_id)
    if duplicates:
        raise ValueError(f"retrieval_corpus contains duplicate memory_id(s): {sorted(duplicates)}")
    return corpus


def load_retrieval_cases(*, case_glob: str | None = None) -> list[dict]:
    """Load retrieval benchmark cases (labelled query -> relevant memory ids).

    Args:
        case_glob: Optional glob pattern for case_id filtering.

    Returns:
        List of dicts with keys: case_id, query, relevant_memory_ids (list[str]
        of memory_id values that must be present in load_retrieval_corpus()).
    """
    cases = _load_jsonl_glob("retrieval_cases*.jsonl")
    if case_glob:
        import fnmatch

        cases = [c for c in cases if fnmatch.fnmatch(c.get("case_id", ""), case_glob)]
    return cases
