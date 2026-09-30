from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", extra="ignore")

    # --- General ---
    environment: str = "local"
    aws_region: str = "us-east-1"
    log_level: str = "INFO"

    # --- Auth ---
    auth_enabled: bool = False  # off for local docker-compose; on in real deployments
    cognito_user_pool_id: str = ""
    cognito_app_client_id: str = ""
    cognito_region: str = "us-east-1"

    # --- Downstream services ---
    agent_orchestrator_url: str = "http://agent-orchestrator:8001"

    # --- AWS resources this service talks to directly ---
    bronze_bucket_name: str = "atlas-dev-bronze"
    document_metadata_table_name: str = "atlas-dev-document-metadata"

    # --- LocalStack support (only set in local-dev/.env) ---
    aws_endpoint_url: str | None = None


@lru_cache
def get_settings() -> Settings:
    return Settings()
