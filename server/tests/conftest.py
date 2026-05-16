import os

# Settings are constructed at import time, so seed dummy values before any
# `grove.*` module is imported. Real values come from .env in normal runs.
os.environ.setdefault("BEARER_TOKEN", "test-token")
os.environ.setdefault(
    "DATABASE_URL",
    "postgresql+asyncpg://test:test@localhost:5432/test",
)
# Embedding and synthesis tests mock the HTTP boundary; these keys are never
# sent to the actual providers.
os.environ.setdefault("OPENAI_API_KEY", "test-stub-key")
os.environ.setdefault("OPENROUTER_API_KEY", "test-stub-key")
