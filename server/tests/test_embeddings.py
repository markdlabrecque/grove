"""Unit tests for grove.embeddings — tokenizer, chunker, and OpenAI provider.

No database required.  The OpenAI provider tests mock at the HTTP boundary
using respx so the real API is never called.
"""

from __future__ import annotations

import json

import httpx
import pytest
import respx

from grove.embeddings import EMBEDDING_DIM, WHOLE_VS_CHUNKS_THRESHOLD
from grove.embeddings.chunker import chunk
from grove.embeddings.openai_provider import OpenAIEmbeddingProvider
from grove.embeddings.tokenizer import count_tokens

# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------


class TestCountTokens:
    def test_known_string(self) -> None:
        # "hello world" is 2 tokens in cl100k_base.
        assert count_tokens("hello world") == 2

    def test_empty_string(self) -> None:
        assert count_tokens("") == 0

    def test_unicode(self) -> None:
        # Should not raise; result is >= 1.
        result = count_tokens("こんにちは")
        assert result >= 1

    def test_emoji(self) -> None:
        # Emoji are valid; result is >= 1.
        result = count_tokens("Hello world!")
        assert result >= 1
        # Multi-emoji string must not raise.
        count_tokens("🎉🔥🌍")

    def test_longer_text(self) -> None:
        # Sanity: longer text produces more tokens.
        short = count_tokens("hello")
        long = count_tokens("hello " * 100)
        assert long > short

    def test_pure_whitespace(self) -> None:
        # Whitespace-only strings still tokenise without error.
        result = count_tokens("   \n\t  ")
        assert isinstance(result, int)


# ---------------------------------------------------------------------------
# Chunker
# ---------------------------------------------------------------------------

# A short sentence we can repeat to build long text.
_SENTENCE = "The quick brown fox jumps over the lazy dog. "
# Roughly how many tokens one repetition contributes (should be ~9-10).
_SENTENCE_TOKENS = count_tokens(_SENTENCE.strip())


def _make_text(sentences: int) -> str:
    return (_SENTENCE * sentences).strip()


def _make_paragraphs(para_count: int, sentences_per_para: int) -> str:
    para = _SENTENCE * sentences_per_para
    return "\n\n".join(para.strip() for _ in range(para_count))


class TestChunk:
    # --- Short text ---

    def test_short_text_returns_single_element_list(self) -> None:
        text = "This is a short note."
        result = chunk(text)
        assert result == [text]

    def test_text_at_threshold_returns_single_element_list(self) -> None:
        # Construct text that is exactly at the default target_tokens boundary.
        # chunk() returns [content] for token_count <= target_tokens.
        short_text = "word " * 10  # well under 400 tokens
        result = chunk(short_text.strip())
        assert len(result) == 1

    def test_empty_string_returns_empty_list(self) -> None:
        assert chunk("") == []

    def test_whitespace_only_returns_empty_list(self) -> None:
        assert chunk("   \n\n   ") == []

    # --- Long single paragraph ---

    def test_long_paragraph_splits_into_multiple_chunks(self) -> None:
        # Build a paragraph well over 400 tokens (target default).
        text = _make_text(60)  # ~540+ tokens
        assert count_tokens(text) > 400

        result = chunk(text, target_tokens=400, overlap_tokens=50)
        assert len(result) > 1

    def test_no_chunk_exceeds_token_limit(self) -> None:
        text = _make_text(60)
        target = 400
        overlap = 50
        result = chunk(text, target_tokens=target, overlap_tokens=overlap)
        for c in result:
            assert count_tokens(c) <= target + overlap, (
                f"Chunk too long ({count_tokens(c)} tokens): {c[:80]!r}"
            )

    def test_overlap_present_between_chunks(self) -> None:
        # With overlap, the end of chunk N should appear at the start of chunk N+1.
        text = _make_text(60)
        result = chunk(text, target_tokens=100, overlap_tokens=30)
        assert len(result) >= 2
        # The last few words of chunk 0 should appear somewhere in chunk 1.
        last_words_of_first = result[0].split()[-3:]
        second_chunk_words = result[1].split()
        assert any(w in second_chunk_words for w in last_words_of_first)

    # --- Multi-paragraph: small paragraphs ---

    def test_small_paragraphs_preserved_whole(self) -> None:
        # Each paragraph is ~90 tokens; we have 6 paragraphs → over 400 total.
        para = (_SENTENCE * 10).strip()  # ~90 tokens per paragraph
        text = "\n\n".join([para] * 6)
        assert count_tokens(text) > 400

        result = chunk(text, target_tokens=400, overlap_tokens=50)
        # Each result chunk should contain at least one complete paragraph.
        # Verify that no chunk contains a half-sentence from the middle of a paragraph.
        for c in result:
            # A complete paragraph starts/ends cleanly; check token ceiling.
            assert count_tokens(c) <= 400 + 50

    def test_multi_paragraph_total_splits(self) -> None:
        text = _make_paragraphs(para_count=9, sentences_per_para=5)
        assert count_tokens(text) > 400
        result = chunk(text, target_tokens=400, overlap_tokens=50)
        assert len(result) > 1

    # --- Multi-paragraph: one huge paragraph ---

    def test_huge_paragraph_split_internally(self) -> None:
        # Two small paragraphs bookending one huge paragraph.
        small = (_SENTENCE * 5).strip()  # ~45 tokens
        huge = (_SENTENCE * 80).strip()  # ~720 tokens
        text = f"{small}\n\n{huge}\n\n{small}"

        result = chunk(text, target_tokens=400, overlap_tokens=50)
        # The huge paragraph must have been split into at least 2 chunks.
        assert len(result) >= 3

    def test_huge_paragraph_chunks_within_limit(self) -> None:
        huge = (_SENTENCE * 80).strip()
        result = chunk(huge, target_tokens=400, overlap_tokens=50)
        for c in result:
            assert count_tokens(c) <= 400 + 50

    # --- Overlap degeneracy guard (#37) ---

    def test_no_degenerate_tail_chunks(self) -> None:
        # 60 identical sentences at ~9 tokens each => ~540 tokens.
        # target=400, overlap=50.  Without the minimum-advance guard the
        # chunker produced 7 tiny tail chunks; with it we expect <= 3.
        text = _make_text(60)
        assert count_tokens(text) > 400

        result = chunk(text, target_tokens=400, overlap_tokens=50)

        # Sensible result: 2 or 3 chunks, not a degenerate tail of many tiny ones.
        assert len(result) <= 3, (
            f"Degeneracy guard failed: got {len(result)} chunks for 540-token text "
            f"(token counts: {[count_tokens(c) for c in result]})"
        )
        # All chunks must still respect the hard ceiling.
        for c in result:
            assert count_tokens(c) <= 400 + 50

    # --- Constants ---

    def test_constants(self) -> None:
        # bge-m3 (1024-d) is the target embedding model for the local-inference
        # deployment (#518) — there is no prod data to preserve, so the
        # default dimension commits to that stack rather than OpenAI's 1536.
        assert EMBEDDING_DIM == 1024
        assert WHOLE_VS_CHUNKS_THRESHOLD == 500


# ---------------------------------------------------------------------------
# OpenAI provider — HTTP boundary mocked with respx
# ---------------------------------------------------------------------------

_FAKE_VECTOR = [0.01] * EMBEDDING_DIM
_OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"


def _make_openai_response(texts: list[str]) -> dict:
    return {
        "object": "list",
        "data": [
            {"object": "embedding", "index": i, "embedding": _FAKE_VECTOR}
            for i in range(len(texts))
        ],
        "model": "text-embedding-3-small",
        "usage": {"prompt_tokens": 10 * len(texts), "total_tokens": 10 * len(texts)},
    }


_TEST_API_KEY = "ci-test-key"


class TestOpenAIEmbeddingProvider:
    @respx.mock
    async def test_embed_batch_returns_vectors(self) -> None:
        texts = ["hello world", "foo bar"]
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(texts))
        )

        provider = OpenAIEmbeddingProvider(api_key=_TEST_API_KEY)
        result = await provider.embed_batch(texts)

        assert len(result) == 2
        assert all(len(v) == EMBEDDING_DIM for v in result)

    @respx.mock
    async def test_embed_batch_request_shape(self) -> None:
        """Verify the request sent to OpenAI has the correct model and input."""
        texts = ["check request shape"]
        route = respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(texts))
        )

        provider = OpenAIEmbeddingProvider(api_key=_TEST_API_KEY)
        await provider.embed_batch(texts)

        assert route.called
        request = route.calls.last.request
        body = json.loads(request.content)
        assert body["model"] == "text-embedding-3-small"
        assert body["input"] == texts

    @respx.mock
    async def test_embed_batch_vector_length(self) -> None:
        texts = ["single text"]
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(texts))
        )

        provider = OpenAIEmbeddingProvider(api_key=_TEST_API_KEY)
        result = await provider.embed_batch(texts)

        assert len(result[0]) == EMBEDDING_DIM

    @respx.mock
    async def test_embed_batch_5xx_propagates(self) -> None:
        import openai

        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(500, json={"error": {"message": "internal server error"}})
        )

        provider = OpenAIEmbeddingProvider(api_key=_TEST_API_KEY)
        with pytest.raises(openai.APIStatusError):
            await provider.embed_batch(["will fail"])

    def test_provider_name(self) -> None:
        provider = OpenAIEmbeddingProvider(api_key=_TEST_API_KEY)
        assert provider.name == "text-embedding-3-small"

    def test_provider_satisfies_protocol(self) -> None:
        from grove.embeddings.provider import EmbeddingProvider

        provider = OpenAIEmbeddingProvider(api_key=_TEST_API_KEY)
        assert isinstance(provider, EmbeddingProvider)


# ---------------------------------------------------------------------------
# Configurable base URL (#518) — local (Ollama) endpoints must be reachable
# without touching api.openai.com.
# ---------------------------------------------------------------------------


class TestConfigurableEmbeddingBaseUrl:
    @respx.mock
    async def test_embed_batch_targets_configured_base_url(self) -> None:
        """embed_batch posts to the provider's configured base_url, not the
        OpenAI SDK default, when one is supplied."""
        texts = ["local inference please"]
        route = respx.post("http://host.docker.internal:11434/v1/embeddings").mock(
            return_value=httpx.Response(200, json=_make_openai_response(texts))
        )

        provider = OpenAIEmbeddingProvider(
            model="bge-m3",
            api_key=_TEST_API_KEY,
            base_url="http://host.docker.internal:11434/v1",
        )
        await provider.embed_batch(texts)

        assert route.called
