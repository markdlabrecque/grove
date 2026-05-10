from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    bearer_token: str
    database_url: str
    openai_api_key: SecretStr | None = None
    openrouter_api_key: SecretStr | None = None
    log_level: str = "INFO"


settings = Settings()  # type: ignore[call-arg]
