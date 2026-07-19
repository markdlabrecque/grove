"""Tests for grove.core.config.Settings field validators.

Pure unit tests — no DB, no HTTP client. Settings is constructed directly
with the required fields (bearer_token, database_url) plus whatever field
is under test.
"""

from __future__ import annotations

from grove.core.config import Settings


class TestBlankEmbeddingBaseUrl:
    def test_blank_embedding_base_url_normalises_to_none(self) -> None:
        """docker-compose's ${VAR:-} substitution sets an unset host var to
        an empty string rather than omitting it; the validator must treat
        that the same as unset (None), or every embedding request breaks.
        """
        settings = Settings(bearer_token="x", database_url="y", embedding_base_url="")
        assert settings.embedding_base_url is None

    def test_set_embedding_base_url_preserved(self) -> None:
        """A real base URL value must pass through unchanged."""
        settings = Settings(
            bearer_token="x",
            database_url="y",
            embedding_base_url="http://host.docker.internal:11434/v1",
        )
        assert settings.embedding_base_url == "http://host.docker.internal:11434/v1"
