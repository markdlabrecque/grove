import os

# Settings are constructed at import time, so seed dummy values before any
# `oracle.*` module is imported. Real values come from .env in normal runs.
os.environ.setdefault("BEARER_TOKEN", "test-token")
os.environ.setdefault(
    "DATABASE_URL",
    "postgresql+asyncpg://test:test@localhost:5432/test",
)
