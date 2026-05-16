from pydantic import BaseModel, SecretStr
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
