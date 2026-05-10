from __future__ import annotations

import functools

import tiktoken


@functools.lru_cache(maxsize=1)
def _get_encoding() -> tiktoken.Encoding:
    return tiktoken.get_encoding("cl100k_base")


def count_tokens(text: str) -> int:
    """Return the number of cl100k_base tokens in *text*.

    Uses a module-level LRU-cached encoding so the encoder is only loaded once
    per process, but not at import time.
    """
    if not text:
        return 0
    return len(_get_encoding().encode(text))
