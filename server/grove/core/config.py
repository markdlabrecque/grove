from pydantic import BaseModel, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class RefinementConfig(BaseModel):
    """Thresholds for query-refinement detection (§3.8).

    Both values are kept here so they can be tuned via settings without
    touching query-handling code.
    """

    window_minutes: int = 5
    similarity_threshold: float = 0.85


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    bearer_token: str
    database_url: str
    openai_api_key: SecretStr | None = None
    openrouter_api_key: SecretStr | None = None
    log_level: str = "INFO"
    # Chat-completion provider base URL. Defaults to OpenRouter; point at a
    # local OpenAI-compatible endpoint (e.g. Ollama's
    # http://host.docker.internal:11434/v1) for fully local inference.
    chat_base_url: str = "https://openrouter.ai/api/v1"

    @field_validator("chat_base_url", mode="after")
    @classmethod
    def _strip_trailing_slash_from_chat_base_url(cls, value: str) -> str:
        # An operator-supplied CHAT_BASE_URL with a trailing slash (e.g.
        # "http://host.docker.internal:11434/v1/") would otherwise produce
        # a double slash when openrouter.py concatenates "/chat/completions".
        return value.rstrip("/")

    # Embedding provider base URL. None means the OpenAI SDK default
    # (api.openai.com). Set to a local OpenAI-compatible endpoint for
    # self-hosted embedding models.
    embedding_base_url: str | None = None
    # Embedding model name. Defaults to bge-m3 (1024-d) — the target model
    # for Grove's local-inference deployment. Must match EMBEDDING_DIM in
    # grove.embeddings, which is the vector column width.
    embedding_model: str = "bge-m3"

    @field_validator("embedding_base_url", mode="before")
    @classmethod
    def _blank_embedding_base_url_is_none(cls, value: str | None) -> str | None:
        # docker-compose's ${VAR:-} substitution sets an unset host var to an
        # empty string rather than omitting it, which would otherwise turn
        # into base_url="" and break every embedding request. Treat blank
        # the same as unset.
        return value or None

    # Separate enrichment_model from any intent-router model so each can be
    # tuned independently without coupling the two call-sites.
    enrichment_model: str = "openai/gpt-4o-mini"
    # synthesis_model is the cheap chat model used for RAG answer composition.
    # Kept separate from enrichment_model so each can be swapped independently.
    synthesis_model: str = "openai/gpt-4o-mini"
    # intent_router_model classifies query intent before specialised-table retrieval.
    # Defaults to the same cheap model class as synthesis; configurable independently.
    intent_router_model: str = "openai/gpt-4o-mini"
    # Score boost applied to specialised-table hits before merging with vector results.
    intent_match_score_boost: float = 0.05
    # Refinement-detection thresholds — tunable without code changes.
    refinement: RefinementConfig = RefinementConfig()

    # Per-token rate limits (token bucket, in-process memory).
    # Burst capacity = rate × burst_multiplier tokens (bucket starts full).
    # See grove.core.rate_limit for the multi-process caveat.
    rate_limit_capture_per_min: int = 30
    rate_limit_query_per_min: int = 20
    rate_limit_default_per_min: int = 60
    rate_limit_burst_multiplier: int = 2

    # Monthly OpenRouter spend cap in USD.
    # At 80% of cap: log a warning on every LLM call.
    # At 100% of cap: raise SpendCapExceededError — retrieval degrades to
    # ranked-snippets-only; enrichment no-ops for the rest of the month.
    openrouter_monthly_cap_usd: float = 20.0


settings = Settings()  # type: ignore[call-arg]
