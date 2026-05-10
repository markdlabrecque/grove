from __future__ import annotations

import re

from oracle.embeddings.tokenizer import count_tokens

# Sentence boundary: end with . ! ? followed by optional close-quote/paren and whitespace.
_SENTENCE_END_RE = re.compile(r"(?<=[.!?])[\"')]*\s+")


def _split_sentences(text: str) -> list[str]:
    """Split *text* into sentences using a simple regex heuristic."""
    parts = _SENTENCE_END_RE.split(text.strip())
    return [p.strip() for p in parts if p.strip()]


def chunk(
    content: str,
    target_tokens: int = 400,
    overlap_tokens: int = 50,
) -> list[str]:
    """Split *content* into overlapping token-bounded chunks.

    Behaviour for short text:
        If *content* is <= target_tokens tokens it is returned as-is in a
        single-element list: ``[content]``.  Callers (e.g. the capture path)
        can compare ``len(chunk(content)) == 1`` to decide whether to embed
        whole or chunked — they do NOT need to re-check the token count.

    Paragraph-awareness:
        Paragraphs (blank-line separated) are never split if they fit within
        *target_tokens*.  Paragraphs that exceed *target_tokens* are split at
        sentence boundaries.  Overlap is applied at the sentence level so that
        each chunk begins with the last few sentences of the previous chunk
        whose combined token count does not exceed *overlap_tokens*.

    Guarantees:
        No chunk exceeds ``target_tokens + overlap_tokens`` tokens (barring a
        single sentence that is itself longer than that limit, in which case it
        is emitted as its own chunk).
    """
    if not content or not content.strip():
        return []

    # Short-circuit: entire content fits in one chunk.
    if count_tokens(content) <= target_tokens:
        return [content]

    paragraphs = [p.strip() for p in re.split(r"\n{2,}", content) if p.strip()]

    # Collect individual sentences, annotated with which paragraph they came from.
    # We flatten into a sentence list so overlap can span paragraph boundaries.
    sentences: list[str] = []
    for para in paragraphs:
        if count_tokens(para) <= target_tokens:
            # Keep the whole paragraph as a single logical sentence so we never
            # split a small paragraph across chunks.
            sentences.append(para)
        else:
            sentences.extend(_split_sentences(para))

    chunks: list[str] = []
    i = 0
    n = len(sentences)

    while i < n:
        # Build a chunk starting at sentence i, growing until we'd exceed target.
        window: list[str] = []
        window_tokens = 0

        j = i
        while j < n:
            s_tokens = count_tokens(sentences[j])
            if window_tokens + s_tokens > target_tokens and window:
                # Adding this sentence would exceed the target; stop here.
                break
            window.append(sentences[j])
            window_tokens += s_tokens
            j += 1

        # If no sentence was added (single sentence exceeds target), take it anyway
        # to avoid an infinite loop.
        if not window:
            window.append(sentences[i])
            j = i + 1

        chunks.append(" ".join(window))

        # Determine the overlap prefix for the next chunk: walk backwards from
        # the end of this window collecting sentences until we hit overlap_tokens.
        overlap: list[str] = []
        overlap_tok = 0
        for s in reversed(window):
            s_tok = count_tokens(s)
            if overlap_tok + s_tok > overlap_tokens and overlap:
                break
            overlap.insert(0, s)
            overlap_tok += s_tok

        # Next chunk starts at the first sentence NOT covered by the overlap.
        # That is: j - len(overlap), but at least i+1 to guarantee progress.
        next_start = max(i + 1, j - len(overlap))
        i = next_start

    return chunks
