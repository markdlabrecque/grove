from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


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


settings = Settings()  # type: ignore[call-arg]
