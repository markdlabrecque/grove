"""Tests for the embedding/retrieval benchmark — ticket #520.

Coverage:
- cosine_similarity / rank_by_similarity pure-function behavior.
- recall_at_k / reciprocal_rank IR metric edge cases.
- evaluate_embedder() end-to-end against a deterministic FakeEmbeddingProvider
  (no network, no real model — this is the CI-runnability seam described in
  the ticket's design outline).
- load_retrieval_corpus() / load_retrieval_cases() against the seed corpus.
"""

from __future__ import annotations

import pytest

from grove.benchmarks.corpus import load_retrieval_cases, load_retrieval_corpus
from grove.benchmarks.retrieval import (
    cosine_similarity,
    evaluate_embedder,
    rank_by_similarity,
    recall_at_k,
    reciprocal_rank,
)

# ---------------------------------------------------------------------------
# cosine_similarity
# ---------------------------------------------------------------------------


def test_cosine_similarity_identical_vectors() -> None:
    assert cosine_similarity([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) == pytest.approx(1.0)


def test_cosine_similarity_orthogonal_vectors() -> None:
    assert cosine_similarity([1.0, 0.0], [0.0, 1.0]) == pytest.approx(0.0)


def test_cosine_similarity_opposite_vectors() -> None:
    assert cosine_similarity([1.0, 0.0], [-1.0, 0.0]) == pytest.approx(-1.0)


def test_cosine_similarity_zero_vector_returns_zero() -> None:
    """Zero-magnitude vectors have undefined cosine — treated as no similarity."""
    assert cosine_similarity([0.0, 0.0], [1.0, 0.0]) == 0.0
    assert cosine_similarity([1.0, 0.0], [0.0, 0.0]) == 0.0


# ---------------------------------------------------------------------------
# rank_by_similarity
# ---------------------------------------------------------------------------


def test_rank_by_similarity_orders_descending() -> None:
    doc_vectors = {
        "mem-a": [1.0, 0.0, 0.0],
        "mem-b": [0.0, 1.0, 0.0],
        "mem-c": [0.0, 0.0, 1.0],
    }
    # Query closest to mem-c, then mem-b, then orthogonal to mem-a.
    ranked = rank_by_similarity([0.0, 0.2, 1.0], doc_vectors)
    assert ranked == ["mem-c", "mem-b", "mem-a"]


def test_rank_by_similarity_ties_preserve_corpus_order() -> None:
    doc_vectors = {
        "mem-a": [1.0, 0.0],
        "mem-b": [0.0, 1.0],
        "mem-c": [0.0, 1.0],
    }
    # Query identical to mem-a; mem-b and mem-c tie at similarity 0 and keep
    # their original (stable-sort) order.
    ranked = rank_by_similarity([1.0, 0.0], doc_vectors)
    assert ranked == ["mem-a", "mem-b", "mem-c"]


# ---------------------------------------------------------------------------
# recall_at_k
# ---------------------------------------------------------------------------


def test_recall_at_k_all_relevant_in_top_k() -> None:
    ranked = ["mem-1", "mem-2", "mem-3"]
    assert recall_at_k(ranked, {"mem-1"}, k=1) == 1.0


def test_recall_at_k_partial_hit() -> None:
    ranked = ["mem-2", "mem-1", "mem-3"]
    # 1 of 2 relevant ids present in top-2 (mem-1, not mem-3).
    assert recall_at_k(ranked, {"mem-1", "mem-3"}, k=2) == pytest.approx(0.5)


def test_recall_at_k_miss() -> None:
    ranked = ["mem-2", "mem-3", "mem-1"]
    assert recall_at_k(ranked, {"mem-1"}, k=1) == 0.0
    assert recall_at_k(ranked, {"mem-1"}, k=3) == 1.0


def test_recall_at_k_empty_relevant_set_is_zero() -> None:
    assert recall_at_k(["mem-1"], set(), k=1) == 0.0


# ---------------------------------------------------------------------------
# reciprocal_rank
# ---------------------------------------------------------------------------


def test_reciprocal_rank_first_hit() -> None:
    assert reciprocal_rank(["mem-1", "mem-2"], {"mem-1"}) == 1.0


def test_reciprocal_rank_later_hit() -> None:
    assert reciprocal_rank(["mem-2", "mem-1", "mem-3"], {"mem-1"}) == pytest.approx(0.5)


def test_reciprocal_rank_no_hit_is_zero() -> None:
    assert reciprocal_rank(["mem-2", "mem-3"], {"mem-1"}) == 0.0


# ---------------------------------------------------------------------------
# evaluate_embedder — deterministic fake provider, zero network.
# ---------------------------------------------------------------------------


class FakeEmbeddingProvider:
    """Deterministic EmbeddingProvider stub for tests.

    Maps each input text to a pre-registered vector via exact string lookup —
    no model, no network, no randomness. Satisfies the EmbeddingProvider
    Protocol (name property + async embed_batch).
    """

    def __init__(self, name: str, vectors: dict[str, list[float]]) -> None:
        self._name = name
        self._vectors = vectors

    @property
    def name(self) -> str:
        return self._name

    async def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [self._vectors[text] for text in texts]


_FAKE_CORPUS = [
    {"memory_id": "mem-1", "content": "alpha"},
    {"memory_id": "mem-2", "content": "beta"},
    {"memory_id": "mem-3", "content": "gamma"},
]

# Orthonormal corpus vectors so ranking is unambiguous by construction.
_FAKE_VECTORS: dict[str, list[float]] = {
    "alpha": [1.0, 0.0, 0.0],
    "beta": [0.0, 1.0, 0.0],
    "gamma": [0.0, 0.0, 1.0],
    # case1: query == alpha exactly -> ranked [mem-1, mem-2, mem-3] (ties by
    # corpus order); relevant = mem-1 -> hit at rank 1.
    "query-case1": [1.0, 0.0, 0.0],
    # case2: query mostly gamma with a little beta -> ranked [mem-3, mem-2, mem-1];
    # relevant = mem-2 (beta) -> hit at rank 2.
    "query-case2": [0.0, 0.2, 1.0],
    # case3: query mostly gamma with a little of both alpha and beta ->
    # ranked [mem-3, mem-2, mem-1]; relevant = {mem-1, mem-3} -> gamma hits at
    # rank 1, alpha only recovered by k=3.
    "query-case3": [0.1, 0.2, 1.0],
}

_FAKE_CASES = [
    {"case_id": "retr-t001", "query": "query-case1", "relevant_memory_ids": ["mem-1"]},
    {"case_id": "retr-t002", "query": "query-case2", "relevant_memory_ids": ["mem-2"]},
    {
        "case_id": "retr-t003",
        "query": "query-case3",
        "relevant_memory_ids": ["mem-1", "mem-3"],
    },
]


@pytest.mark.asyncio
async def test_evaluate_embedder_per_case_results() -> None:
    provider = FakeEmbeddingProvider("fake-embedder", _FAKE_VECTORS)

    result = await evaluate_embedder(provider, _FAKE_CORPUS, _FAKE_CASES, k_values=(1, 2, 3))

    assert result.embedder_name == "fake-embedder"
    assert result.n_cases == 3

    by_id = {cr.case_id: cr for cr in result.case_results}

    case1 = by_id["retr-t001"]
    assert case1.ranked_ids == ["mem-1", "mem-2", "mem-3"]
    assert case1.recall_at_k == {1: 1.0, 2: 1.0, 3: 1.0}
    assert case1.reciprocal_rank == 1.0

    case2 = by_id["retr-t002"]
    assert case2.ranked_ids == ["mem-3", "mem-2", "mem-1"]
    assert case2.recall_at_k == {1: 0.0, 2: 1.0, 3: 1.0}
    assert case2.reciprocal_rank == pytest.approx(0.5)

    case3 = by_id["retr-t003"]
    assert case3.ranked_ids == ["mem-3", "mem-2", "mem-1"]
    # relevant = {mem-1, mem-3}: top-1 = {mem-3} -> 1/2; top-2 = {mem-3,mem-2} -> 1/2;
    # top-3 = all three -> 2/2.
    assert case3.recall_at_k == {1: pytest.approx(0.5), 2: pytest.approx(0.5), 3: 1.0}
    assert case3.reciprocal_rank == 1.0


@pytest.mark.asyncio
async def test_evaluate_embedder_aggregate_means() -> None:
    provider = FakeEmbeddingProvider("fake-embedder", _FAKE_VECTORS)

    result = await evaluate_embedder(provider, _FAKE_CORPUS, _FAKE_CASES, k_values=(1, 2, 3))

    # Per-case recall@1: 1.0, 0.0, 0.5 -> mean 0.5
    assert result.mean_recall_at_k[1] == pytest.approx(0.5)
    # Per-case recall@2: 1.0, 1.0, 0.5 -> mean 0.8333...
    assert result.mean_recall_at_k[2] == pytest.approx(5 / 6)
    # Per-case recall@3: 1.0, 1.0, 1.0 -> mean 1.0
    assert result.mean_recall_at_k[3] == pytest.approx(1.0)
    # Per-case MRR: 1.0, 0.5, 1.0 -> mean 0.8333...
    assert result.mean_reciprocal_rank == pytest.approx(5 / 6)


@pytest.mark.asyncio
async def test_evaluate_embedder_rejects_unknown_relevant_id() -> None:
    provider = FakeEmbeddingProvider("fake-embedder", _FAKE_VECTORS)
    bad_cases = [
        {"case_id": "retr-bad", "query": "query-case1", "relevant_memory_ids": ["mem-999"]}
    ]

    with pytest.raises(ValueError, match="mem-999"):
        await evaluate_embedder(provider, _FAKE_CORPUS, bad_cases)


@pytest.mark.asyncio
async def test_evaluate_embedder_empty_cases_returns_zeroed_aggregate() -> None:
    provider = FakeEmbeddingProvider("fake-embedder", _FAKE_VECTORS)

    result = await evaluate_embedder(provider, _FAKE_CORPUS, [], k_values=(1, 3))

    assert result.n_cases == 0
    assert result.case_results == []
    assert result.mean_recall_at_k == {1: 0.0, 3: 0.0}
    assert result.mean_reciprocal_rank == 0.0


# ---------------------------------------------------------------------------
# corpus loaders
# ---------------------------------------------------------------------------


def test_load_retrieval_corpus_seed_shape() -> None:
    corpus = load_retrieval_corpus()
    assert len(corpus) > 0
    for doc in corpus:
        assert isinstance(doc["memory_id"], str) and doc["memory_id"]
        assert isinstance(doc["content"], str) and doc["content"]


def test_load_retrieval_cases_seed_shape() -> None:
    cases = load_retrieval_cases()
    assert len(cases) > 0
    for case in cases:
        assert isinstance(case["case_id"], str) and case["case_id"]
        assert isinstance(case["query"], str) and case["query"]
        assert isinstance(case["relevant_memory_ids"], list) and case["relevant_memory_ids"]


def test_load_retrieval_cases_reference_valid_corpus_ids() -> None:
    """Every seed case's relevant_memory_ids must resolve into the seed corpus.

    This is exactly the invariant evaluate_embedder() enforces at runtime —
    asserting it here catches corpus/case drift without needing an embedder.
    """
    corpus_ids = {doc["memory_id"] for doc in load_retrieval_corpus()}
    for case in load_retrieval_cases():
        missing = set(case["relevant_memory_ids"]) - corpus_ids
        assert not missing, f"{case['case_id']} references unknown ids: {missing}"


def test_load_retrieval_cases_case_glob_filters() -> None:
    all_cases = load_retrieval_cases()
    filtered = load_retrieval_cases(case_glob="retr-001")
    assert len(filtered) == 1
    assert filtered[0]["case_id"] == "retr-001"
    assert len(filtered) < len(all_cases)
